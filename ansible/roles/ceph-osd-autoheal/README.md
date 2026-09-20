# Role: ceph-osd-autoheal

Implements `infra/ceph-osd-autoheal.md`'s design: a per-node service on the
Ceph OSD hosts (pve2, pve3 — **not** pve1, which has no OSDs) that waits for
OSD disks to enumerate before Ceph starts, and auto-heals any OSD that still
goes down (`rescan-scsi-bus.sh` → `ceph-volume lvm activate` →
`systemctl restart`), escalating to a Pushbullet push notification only when a
genuine physical reseat is needed.

Prompted by three recurrences of the same failure (2026-01-22, 2026-09-10,
2026-09-19): a power event causes a cold boot, one or two 18TB SAS drives
behind the LSI SAS2008 HBA take too long to answer `INQUIRY`, and — because
pools are `size 2` across only two OSD hosts — that alone can take
placement groups to zero online replicas.

## Why this runs outside K8s

Same reasoning as `scrutiny-collector`: it needs raw disk/HBA access on the
Proxmox host itself, and — more importantly here — it has to work when K8s
and Ceph are *both* degraded, which is exactly the scenario it exists to fix.

## Safety model

The script (`files/ceph-osd-autoheal`) is deliberately conservative:

- **Command allowlist.** The only subprocess calls it can make are
  `rescan-scsi-bus.sh`, `sg_start`, a SAS phy enable/disable toggle,
  `ceph-volume lvm activate/list`, `systemctl {is-active,reset-failed,
  restart,status} ceph-osd@N`, read-only `ceph`/`lsblk`/`smartctl`, and
  `ceph osd set/unset noout`. It is structurally incapable of running
  `ceph osd out/in/purge/destroy/rm/lost/crush`, `wipefs`, `sgdisk`,
  `mkfs*`, `dd`, `blkdiscard`, or `ceph-volume lvm zap/batch/create`.
- **Circuit breaker.** Max `ceph_autoheal_max_restarts_per_hour` (default 3)
  restart attempts per OSD before it stops retrying and just watches for
  recovery — no restart-loop, no notification spam.
- **Respects maintenance.** Won't act if the cluster has
  `noout`/`norecover`/`nodown` set (an admin is presumably already working
  on it) — notifies instead.
- **`DRY_RUN=1` by default.** Logs and notifies exactly as it would for
  real, but the only commands actually executed are read-only ones. Flip
  `ceph_autoheal_dry_run: false` only after a manual induced-failure test
  (see below) confirms the ladder behaves correctly.
- **`pause` file.** Touch `/etc/ceph-osd-autoheal/pause` on a host to
  disable all action during planned maintenance.

## Variables

| Variable | Default | Description |
|---|---|---|
| `ceph_autoheal_osds` | *(required)* | Per-host list of this host's OSDs — id, fsid, disk_serial, hba_phy, front_bay_label. Define in `host_vars/<host>.yml`. |
| `pushbullet_token` | *(required)* | Pushbullet access token for push notifications. Define in `group_vars/proxmox/vault.yml` (ansible-vault) as `vault_pushbullet_token`, referenced via `group_vars/proxmox/main.yml`. |
| `ceph_autoheal_dry_run` | `true` | See Safety model above. |
| `ceph_autoheal_enable_phy_reset` | `false` | Heal-ladder step 3 (briefly drops a working SAS link) — opt-in. |
| `ceph_autoheal_respect_maint_flags` | `true` | Skip action if noout/norecover/nodown is set cluster-wide. |
| `ceph_autoheal_settle_after_boot` | `90` | Seconds of uptime before the healer will act. |
| `ceph_autoheal_disk_wait_timeout` | `600` | Boot-time disk-wait gate timeout (still exits 0 after this — never blocks boot). |
| `ceph_autoheal_max_restarts_per_hour` | `3` | Circuit breaker threshold per OSD. |
| `ceph_autoheal_backoff_seconds` | `3600` | Circuit breaker cooldown. |
| `ceph_autoheal_use_noout_during_heal` | `true` | Set `noout` while working a down OSD, to avoid premature rebalancing. |
| `ceph_autoheal_noout_duration` | `900` | Informational upper bound — the script always unsets `noout` itself when done or on error. |

## Populating `ceph_autoheal_osds`

Run `ceph-osd-autoheal --dump-inventory` on the host (after this role is
deployed once with a placeholder, or manually with the script copied over)
to get a starting point correlating `ceph osd metadata` against this host's
OSDs. `hba_phy`, `enclosure_slot`, and `front_bay_label` need hand-filling —
see `infra/ceph-osd-recovery.md`'s LED-based bay identification method.
Commit the result into `host_vars/<host>.yml`, then re-run the playbook.

## Rollout

1. Deploy with `ceph_autoheal_dry_run: true` (the default).
2. Install the Pushbullet app/browser extension and confirm you have an access token (pushbullet.com → Settings → Account → Create Access Token).
3. On a quiet night: `ceph osd set noout`, then `systemctl stop
   ceph-osd@<id>` on a real OSD to induce a failure. Confirm
   `journalctl -u ceph-osd-autoheal.service` shows the correct ladder and a
   notification arrives — with nothing actually changed (still `DRY_RUN`).
   `ceph osd unset noout` after.
4. Set `ceph_autoheal_dry_run: false`, re-run the playbook, and re-test the
   same way — this time it should actually recover the OSD.
