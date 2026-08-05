# Role: hp-smart-array

Installs `ssacli` (HPE's Smart Storage Administrator CLI) from HPE's own
apt repo — used to inspect physical drives behind an HP Smart Array RAID
controller (e.g. `ssacli ctrl all show config detail`).

## Why this exists

`pve1`'s HP Smart Array P420i controller hides its physical drives behind
opaque logical volumes (`/dev/sda`, `/dev/sdb`) — `smartctl` can't read
SMART data from them without an explicit `-d cciss,N` per physical drive.
`ssacli` is how you enumerate which physical drive is behind which index,
by cross-referencing serial numbers against
`smartctl -i -d cciss,N /dev/sda` for each `N`. See
`ansible/host_vars/pve1.yml` for the derived mapping, which feeds into the
`scrutiny-collector` role's `scrutiny_raid_devices` override.

If a drive in this array is ever replaced, re-run
`ssacli ctrl all show config detail` and re-derive the mapping — bay
assignment could shift.
