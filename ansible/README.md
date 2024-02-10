# Homelab Ansible

A collection of Ansible resources for configuring hosts.

## Setup

```sh
brew install hudochenkov/sshpass/sshpass

```

## Playbooks

### Beelink

This mini-PC hosts Home Assistant and Pi-hole, which is used for external-dns for the K8s cluster. The provisioning playbook expects to be run from a fresh install of Ubuntu 22.04 with a root user with a password. This user should have a public key added to /root/.ssh/authorized_keys before running Ansible.

```sh
ansible-playbook -i inventory.ini playbooks/beelink/provision.yml
```
