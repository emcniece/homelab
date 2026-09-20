# Role: outline-docs-mirror

Deploys a docker-compose app in `~/apps/outline-docs-mirror/` on the target
host that periodically exports every Outline collection to markdown and
serves it over plain HTTP, entirely independent of Ceph and K8s.

Two containers:

- `outline-docs-sync` — an Alpine container running a sleep-loop shell
  script (`files/sync-outline.sh`) that calls Outline's export API, unzips
  the result into `~/apps/outline-docs-mirror/data/docs/`, and commits it
  to a local git repo there (so you get a diffable history of doc changes
  for free).
- `outline-docs-server` — nginx serving that same directory with directory
  listing on, no JS/rendering dependency.

Requires `docker` (see the `docker` role).

## Why this runs outside K8s

Outline itself runs in K8s, backed by Ceph-RBD storage. If Ceph OSDs are
down, K8s pods (including Outline) may not schedule — which is exactly the
scenario where you need a runbook/incident doc the most. This mirror has to
live on the Proxmox host's own boot disk (not Ceph, not a K8s PVC) to
survive that. See the 2026-09-19 Ceph OSD outage for the incident that
prompted this.

## Variables

| Variable | Default | Description |
|---|---|---|
| `outline_api_token` | *(required)* | Outline API token (Settings > API Tokens). Define in `secrets.yml`, not in the playbook. |
| `outline_url` | `https://docs.emc2.build` | Base URL of the Outline instance |
| `runtime_user` | *(required)* | Non-root user the compose app runs under (from the `docker` role) |
| `outline_mirror_sync_interval` | `6h` | How often to re-export (`Xh`/`Xm`/`Xs` — a plain sleep loop, not cron) |
| `outline_mirror_http_port` | `8091` | Host port nginx listens on |

## Accessing the mirror during an outage

`http://<proxmox-host-ip>:8091/` — plain directory listing of markdown
files, one subfolder per Outline collection. Works via `curl` too.

## Notes

- The Outline export API (`collections.export_all` / `fileOperations.*`) is
  used as documented at the time this role was written — if a sync starts
  failing after an Outline upgrade, check `docker logs outline-docs-sync`
  first; the response shape may have changed.
- The sync container installs its own packages (`curl jq unzip rsync git`)
  on start rather than using a custom-built image — acceptable for a
  background job that only wakes up every few hours.
- Deploy this to all three Proxmox hosts (not just one) for redundancy —
  the `[proxmox]` inventory group already targets all three.
