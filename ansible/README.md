# Homelab Ansible

A collection of Ansible resources for configuring hosts.

## Setup

```sh
brew install hudochenkov/sshpass/sshpass

ansible-galaxy collection install community.docker
```

## Playbooks

### HP DL380 Gen8

This 2U server already runs Proxmox. The playbooks here will configure a few extra services.

```sh
ansible-playbook playbooks/hp/provision.yml -e "@secrets.yml"
```

### Beelink

This mini-PC hosts Home Assistant and Pi-hole, which is used for external-dns for the K8s cluster. The provisioning playbook expects to be run from a fresh install of Ubuntu 22.04 with a root user with a password. This user should have a public key added to /root/.ssh/authorized_keys before running Ansible.

```sh
ansible-playbook playbooks/beelink/provision.yml -e "@secrets.yml"
ansible-playbook playbooks/beelink/provision.yml -e "@secrets.yml" --tags os
ansible-playbook playbooks/beelink/provision.yml -e "@secrets.yml" --tags pihole
```

### Proxmox cluster (Ceph + ZFS hosts)

Fill in real IPs/hostnames under `[proxmox]` in `inventory.ini` first. This
installs Docker and the Scrutiny S.M.A.R.T. collector, which watches every
physical disk on the host (Ceph OSD disks, the ZFS array, and the boot RAID)
and reports to the Scrutiny web app running in K8s (`apps/scrutiny/`). See
`roles/scrutiny-collector/README.md` for why this runs outside K8s.

```sh
ansible-playbook playbooks/proxmox/provision-scrutiny.yml
ansible-playbook playbooks/proxmox/provision-scrutiny.yml --tags scrutiny
```

This also installs a local mirror of the Outline wiki (`docs.emc2.build`),
exported to markdown and served over plain HTTP directly from each host's
boot disk — readable even when Ceph OSDs are down and K8s (where Outline
runs) can't schedule pods. Set `outline_api_token` in `secrets.yml` first
(Outline > Settings > API Tokens). See
`roles/outline-docs-mirror/README.md`.

```sh
ansible-playbook playbooks/proxmox/provision-outline-mirror.yml -e "@secrets.yml"
```

Also installs a self-healing service on pve2/pve3 (the two Ceph OSD hosts)
that waits for OSD disks to enumerate before Ceph starts, and auto-heals any
OSD that goes down after a power event — the same failure this repo's
`infra/ceph-osd-autoheal.md` was written to fix, after it recurred a third
time. Deploys in dry-run mode by default; see
`roles/ceph-osd-autoheal/README.md` for the rollout steps before trusting it
to act for real.

```sh
ansible-playbook playbooks/proxmox/provision-ceph-autoheal.yml
```

### UDM Pro

Installs the `/data/on_boot.d/` scripts that re-provision the cloudflared
tunnel and `/root/.ssh/authorized_keys` on every boot, so they survive
UniFi OS firmware updates instead of needing to be manually reinstalled. See
`roles/udmp-persist/README.md` and
https://docs.emc2.build/doc/udm-pro-persisting-config-across-firmware-updates-1cdqqdD4wQ
for the full story.

```sh
ansible-playbook playbooks/udmp/provision.yml -e "@secrets.yml"
```
