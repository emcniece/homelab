# Ceph OSD Auto-Heal — Design

Status: **design / not yet built**
Companion runbook: [`ceph-osd-recovery.md`](./ceph-osd-recovery.md)

## Why

OSDs drop out after almost every power event. Known occurrences:

| Date | What happened |
|------|---------------|
| 2026-01-22 | osd.4 down/out after a pve3 reboot; 14 k8s pods stuck, sites down; ~3.5h recovery |
| 2026-09-10 (AM) | Full power cycle. osd.3 + osd.7 (pve3) and osd.5 (pve2) failed to enumerate on cold boot. 39 PGs inactive, CephFS offline, k3s-06 VM wedged, ~130 pods disrupted. |
| 2026-09-10 (PM) | Another outage, same expected outcome. |

### Root cause

1. **No UPS.** iDRAC SELs show `Power Supply AC lost` on every power event — the hosts hard-power-off. Both R710 PSUs have shown `Redundancy Lost` since 2025, so there is no second feed either.
2. On the cold boot that follows, the 18 TB WDC `WUH721818` SAS drives behind the LSI SAS2008 (IT mode, FW P20) sometimes fail the HBA's `INQUIRY` within the timeout — they spin up too slowly / draw too much current at once. The kernel logs `attempting task abort! ... Inquiry ... outstanding for 20573 ms` and the drive never attaches.
3. `ceph-osd@N` then can't start (its BlueStore block device / LVM LV does not exist), Ceph marks the OSD down.
4. Pools are `size 2`, `min_size 1`, failure domain `host`, and there are only **two** OSD hosts (pve2, pve3). Any two correlated OSD losses — one per host — take a fraction of the data to zero online copies (`unknown` PGs), which is what makes these incidents severe.

The drives themselves have been fine every time (`SMART OK`, clean BlueStore shutdown). The manual fix has been: SCSI rescan → `ceph-volume lvm activate` → `systemctl reset-failed && restart`, and a **physical reseat** when the drive won't re-link.

### The real fix (do this regardless)

A UPS on pve1/2/3 + **NUT** for coordinated graceful shutdown (`ceph osd set noout`, stop OSDs cleanly, `poweroff`). This removes the ungraceful-poweroff trigger entirely. Auto-heal is the mitigation for when it still happens (UPS runs out, NUT fails, someone pulls the wrong cord).

---

## Design goals

- **Self-contained on each Proxmox node.** No dependency on k8s or the monitoring stack — both were themselves down/degraded during the last two incidents.
- **Prevent** the OSD from ever going down at boot where possible; **heal** it automatically where safe; **notify a human** with actionable detail when a physical reseat is genuinely required.
- **Never** perform a destructive or data-risking Ceph action.
- Bounded, logged, interruptible.

## Scope

Runs on the OSD hosts: **pve2, pve3** (pve1 is mon/mgr/mds only, no OSDs — it gets a lighter "cluster health" reporter, or nothing).

---

## Architecture

Two cooperating systemd units per host, plus a shared script and a per-host inventory file. Deployed by a new Ansible role `ceph-osd-autoheal` targeting the `proxmox` group.

```
/usr/local/sbin/ceph-osd-autoheal            # the script (bash or python3-stdlib)
/etc/ceph-osd-autoheal/config.env            # tunables + ntfy topic
/etc/ceph-osd-autoheal/inventory.yaml        # per-host OSD <-> disk identity map
/etc/ceph-osd-autoheal/pause                 # touch to disable all action (maintenance)
/var/lib/ceph-osd-autoheal/state.json        # per-OSD attempt counters / circuit-breaker
/var/log/ceph-osd-autoheal.log               # audit log (also journald)

/etc/systemd/system/ceph-osd-disk-wait.service
/etc/systemd/system/ceph-osd-autoheal.service
/etc/systemd/system/ceph-osd-autoheal.timer
/etc/systemd/system/ceph-osd@.service.d/autoheal.conf   # OnFailure= drop-in
```

### Component 1 — Preventer: `ceph-osd-disk-wait.service`

Boot-time gate that makes sure every expected OSD disk is present **before** Ceph tries to start its OSDs.

- `Wants=`/`Before=ceph-osd.target`, `After=` the point where `mpt3sas` has loaded and initial SCSI scan is done.
- Reads `inventory.yaml`, builds the set of expected disk serials for this host.
- Loop until all present or `DISK_WAIT_TIMEOUT` (default 600s):
  - `rescan-scsi-bus.sh -a` (adds new devices)
  - for any `/dev/sg*` whose device is in standby: `sg_start --start`
  - for a still-missing disk on a known phy: toggle `/sys/class/sas_phy/phy-2:<N>/enable` (0, sleep 3, 1), then rescan
  - re-check `/dev/disk/by-id/` for each expected serial (`scsi-*` / `wwn-*` symlinks)
- Emits a start + finish notification (`"pve3: all 4 OSD disks present in 42s"` or `"pve3: 3/4 disks after 600s — osd.3 (SN 3GHKRJJK) missing, escalating"`).
- Exits 0 even on timeout (don't block boot forever) — the healer picks up the stragglers.

> Today's AM incident would have been fully resolved by this unit alone: the drives were healthy, just slow to enumerate.

### Component 2 — Healer/notifier: `ceph-osd-autoheal.{service,timer}`

Triggered by:
- `ceph-osd-autoheal.timer` — `OnBootSec=90s`, `OnUnitActiveSec=120s`
- `OnFailure=ceph-osd-autoheal.service` drop-in on `ceph-osd@.service` (immediate reaction to a unit failure)

Each run:
1. `flock` a lockfile (single instance).
2. Bail if `/etc/ceph-osd-autoheal/pause` exists.
3. Bail (notify-only) if `ceph osd dump` shows `noout`/`norecover`/`nodown` set **and** `RESPECT_MAINT_FLAGS=1` (default) — an admin is doing maintenance.
4. List OSDs owned by this host from `inventory.yaml`. For each that is `down` (via `ceph osd tree -f json`, or if the mon is unreachable, via local `systemctl is-active ceph-osd@N` + block-device check):

#### Heal ladder (re-check after every step; stop as soon as the OSD is `up`)

| # | Condition | Action |
|---|-----------|--------|
| 1 | always | `rescan-scsi-bus.sh -a`; wait 45s |
| 2 | matching `/dev/sg*` in standby | `sg_start --start /dev/sgX` |
| 3 | disk still absent, phy known | `echo 0 > /sys/class/sas_phy/phy-2:<N>/enable; sleep 3; echo 1 > …/enable`; rescan; wait 30s |
| 4 | block device now present, OSD not up | `ceph-volume lvm activate <id> <fsid>` → `systemctl reset-failed ceph-osd@<id>` → `systemctl restart ceph-osd@<id>`; wait up to 240s for it to peer |
| 5 | still down after step 4 twice, **or** disk never appeared after step 3 | **escalate** (notification below), write circuit-breaker marker, stop acting on this OSD |

5. On any OSD transitioning `down → up`, send a recovery notification and clear its state.
6. Write `state.json`, append to the audit log.

#### Circuit breaker

`state.json` per OSD: `{attempts_this_hour, first_attempt_ts, escalated, last_seen_state}`.
- Max `MAX_RESTARTS_PER_HOUR` (default 3) step-4 restarts per OSD. Beyond that → escalate + back off for `BACKOFF` (default 1h).
- Once `escalated`, the healer only watches for recovery; it does not keep retrying (no notification spam, no restart loop).

#### Hard safety rails

- The script contains an **allowlist** of external commands. It is structurally incapable of running: `ceph osd out|in|purge|destroy|rm|lost|crush`, `ceph-volume lvm zap|batch|create`, `wipefs`, `sgdisk`, `parted`, `mkfs*`, `dd`, `blkdiscard`. Allowed: `rescan-scsi-bus.sh`, `sg_start`, `sg_ses` (read), writes to `/sys/class/sas_phy/*/enable`, `ceph-volume lvm activate`, `systemctl {is-active,reset-failed,start,restart,status} ceph-osd@<id>`, read-only `ceph`/`lsblk`/`smartctl`.
- Only touches OSD IDs listed for **this** host in `inventory.yaml`.
- No action in the first `SETTLE_AFTER_BOOT` (default 90s) of uptime.
- `DRY_RUN=1` logs intended actions and sends notifications but changes nothing.
- Everything to journald + `/var/log/ceph-osd-autoheal.log` with timestamps.

---

## OSD identity inventory

`/etc/ceph-osd-autoheal/inventory.yaml`, one per host. Generated by `ceph-osd-autoheal --dump-inventory` while the cluster is healthy (correlates `ceph-volume lvm list`, `ceph osd metadata`, `/dev/disk/by-id`, `/sys/class/sas_phy`, and dmesg enclosure/slot lines). `front_bay_label` is filled in by hand once.

```yaml
host: pve3
hba:
  driver: mpt3sas
  scsi_host: host2
  sas2008_fw: "20.00.07.00"
  enclosure_logical_id: "0x5b8ca3a0e7f06800"
osds:
  - id: 1
    fsid: a090331d-318f-4fe6-b2a1-fb6a19810919
    disk_model: "WDC WUH721818AL4201"
    disk_serial: "3WGMA65J"
    wwn: "0x5000cca2..."
    sas_address: "0x5000cca2..."
    hba_phy: 4
    enclosure_slot: 7
    front_bay_label: "?"        # <- fill in once (see recovery guide's LED method)
  - id: 3
    fsid: 855efe8b-7640-4885-bd64-837390caa980
    disk_model: "WDC WUH721818AL4201"
    disk_serial: "3GHKRJJK"
    sas_address: "0x5000cca2af589999"
    hba_phy: 7
    enclosure_slot: 4
    front_bay_label: "?"
  - id: 6
    fsid: 3e4d99c4-5e01-4938-98de-6400fbd7464c
    disk_serial: "3MGH9WYU"
    hba_phy: 6
    front_bay_label: "?"
  - id: 7
    fsid: 75d8d5ed-50c9-48b4-9ec3-e1d3b3c423d6
    disk_serial: "3WHD7E7J"
    sas_address: "0x5000cca2844e9f59"
    hba_phy: 5
    enclosure_slot: 6
    front_bay_label: "?"
```

Known map for pve2 (from the 2026-09-10 incident): phy4→osd.0 `6PGDV9VU`, phy5→osd.5 `6PGDM27U`, phy6→osd.4 `5DKLYN5R`, phy7→osd.2 `4EG4DY6U`, enclosure `0x5b8ca3a0ea2feb00`.

---

## Notifications — ntfy.sh

- Topic: a long random string, e.g. `ceph-emc2-<random>`. Stored in `config.env` (`NTFY_TOPIC=`), and the file is `chmod 600` — the topic is the only access control on ntfy.sh.
- Subscribe on phone: ntfy app → add `ntfy.sh/ceph-emc2-<random>`.
- One `curl` per event:

```sh
curl -s \
  -H "Title: $TITLE" \
  -H "Priority: $PRIORITY" \
  -H "Tags: $TAGS" \
  -d "$BODY" \
  "https://ntfy.sh/$NTFY_TOPIC" >/dev/null
```

### Event types

| Event | Priority | Tags | Example body |
|---|---|---|---|
| boot: all disks present | `default` | `white_check_mark` | `pve3: 4/4 OSD disks present 42s after boot` |
| healer: auto-recovered | `default` | `arrows_counterclockwise` | `pve3: osd.7 was down, rescan+activate fixed it. 8/8 OSDs up.` |
| **escalation: reseat required** | `urgent` | `rotating_light,wrench` | see below |
| escalation cleared | `high` | `white_check_mark` | `pve3: osd.3 back up after reseat. Cluster HEALTH_OK.` |
| healer error / can't reach mon | `high` | `warning` | `pve3: autoheal cannot query ceph (mon unreachable), retrying` |

### Escalation body

```
pve3 — osd.3 DOWN, disk not detected after rescan + phy reset (3 attempts).

RESEAT THIS DRIVE:
  WDC 18TB  serial 3GHKRJJK
  front bay: 2   (HBA phy 7, enclosure slot 4)

How to find it: during backfill every healthy drive's activity LED
blinks constantly — this bay's LED is dark or steady. Confirm by the
serial on the caddy label before pulling. Hot-swap safe.

After reseating it rejoins automatically (ceph-osd-disk-wait picks it up),
or force it:  ceph-osd-autoheal --retry osd.3

Cluster impact right now: 14 PGs inactive, CephFS degraded.
```

The impact line comes from `ceph health detail` / `ceph pg dump_stuck inactive` so you know how urgent the drive-swap is.

---

## Deployment — Ansible role `ceph-osd-autoheal`

```
ansible/roles/ceph-osd-autoheal/
  defaults/main.yml        # tunables (timeouts, MAX_RESTARTS_PER_HOUR, RESPECT_MAINT_FLAGS…)
  files/ceph-osd-autoheal  # the script
  templates/
    config.env.j2          # NTFY_TOPIC from vault, tunables
    inventory.yaml.j2      # from host_vars (or generated on first run then committed)
    ceph-osd-disk-wait.service.j2
    ceph-osd-autoheal.service.j2
    ceph-osd-autoheal.timer.j2
    autoheal.conf.j2        # ceph-osd@.service.d drop-in
  handlers/main.yml         # daemon-reload, enable+start timer & disk-wait
  tasks/main.yml
```

- `NTFY_TOPIC` lives in `ansible/group_vars/proxmox/vault.yml` (ansible-vault, `.vault_password` already gitignored).
- Playbook: `ansible/playbooks/proxmox/provision-ceph-autoheal.yml`, limit `pve2,pve3`.
- Package deps: `sg3-utils` (`sg_start`, `sg_ses`), `lsscsi`, `rescan-scsi-bus.sh` (in `sg3-utils` or `scsitools`) — all already present on the nodes.

### Rollout

1. `--dump-inventory` on pve2 & pve3, hand-fill `front_bay_label`, commit `inventory.yaml` per host.
2. Deploy with `DRY_RUN=1`. Trigger a fake failure (`systemctl stop ceph-osd@7` on a quiet night, `ceph osd set noout` first) and confirm the log shows the right ladder + a notification, with no changes made.
3. Flip `DRY_RUN=0`. Re-test the induced failure — expect auto-recovery within ~2 min.
4. Leave it for the next real power event.

---

## Secondary layer — Prometheus alerts (after monitoring is back)

You already scrape `ceph-mgr` (`infra/monitoring/ceph-mgr-*.yaml`). Add rules → route to the same ntfy topic via Alertmanager (or a webhook receiver). Catches what the node-local healer can't: whole node down, mon quorum loss, slow-but-not-down OSDs.

```yaml
- alert: CephOSDDown
  expr: ceph_osd_up == 0
  for: 5m
- alert: CephPGsInactive
  expr: ceph_pg_total - ceph_pg_active > 0
  for: 5m
- alert: CephHealthError
  expr: ceph_health_status == 2
  for: 5m
- alert: CephOSDSlowOps
  expr: ceph_healthcheck_slow_ops > 0
  for: 10m
```

This is explicitly *secondary* — during the last two incidents Prometheus itself was stuck `ContainerCreating` on a Ceph RBD volume, so it could not have alerted. The node-local path is the one that has to work.

---

## Open decisions

- **Language:** bash (fewer deps, matches other homelab scripts) vs python3 stdlib (easier state/JSON, safer parsing). Leaning python3 — it's on the nodes.
- **pve1:** skip entirely, or a cut-down "is the mon/mds healthy, is quorum intact" reporter?
- **Phy reset (ladder step 3):** mildly risky (briefly drops the link); keep it, or make it opt-in (`ENABLE_PHY_RESET=0` by default)?
- **`front_bay_label`:** confirm the phy→bay mapping physically on the next maintenance window (the 2026-09-10 LED evidence suggested bays are wired reverse to phy order — bay0=phy7 … bay3=phy4 — but that was inferred, not verified).
- Whether to also have the healer `ceph osd set noout` for ~15 min while it works a drive, to stop premature rebalancing (then unset). Low risk, worth it.
