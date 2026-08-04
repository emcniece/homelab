# Role: scrutiny-collector

Deploys the [Scrutiny](https://github.com/Starosdev/scrutiny) S.M.A.R.T.
collector as a docker-compose app in `~/apps/scrutiny-collector/` on the
target host, and points it at a central Scrutiny web app (see
`apps/scrutiny/` in the K8s manifests).

Requires `docker` (see the `docker` role) and `gather_facts: yes`, since disk
detection reads `ansible_devices`.

Physical disks (`sd*`, `vd*`, `nvme*`, `hd*`) are auto-detected — no need to
list them per host. This intentionally includes disks already in use by
Ceph OSDs, ZFS, or mdadm: Scrutiny only reads SMART attributes, it doesn't
touch the filesystem/RAID layer. Re-run the playbook after adding or
removing drives on a host.

## Why this runs outside K8s

The collector needs raw `/dev/sdX` access (`--cap-add SYS_RAWIO`, `--device`).
Our K8s nodes are VMs on Proxmox, so a pod never sees the hypervisor's
physical disks. The collector has to run directly on the Proxmox host; only
the web UI + InfluxDB run in K8s.

## Variables

| Variable | Default | Description |
|---|---|---|
| `scrutiny_api_endpoint` | *(required)* | URL of the central Scrutiny web app, e.g. `https://scrutiny.lab.emc2.build` |
| `runtime_user` | *(required)* | Non-root user the compose app runs under (from the `docker` role) |
| `scrutiny_collector_cron_schedule` | `0 */6 * * *` | Cron expression controlling how often the collector scans disks |
