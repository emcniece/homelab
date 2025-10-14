# K8s Proxmox CSI

https://blog.stonegarden.dev/articles/2024/06/k8s-proxmox-csi/

Label each K8s VM: ctrl-00, ctrl-01 etc. work-00, work-01 etc.

Configure CSI user:

```sh
ssh pve1
pveum role add CSI -privs "VM.Audit VM.Config.Disk Datastore.Allocate Datastore.AllocateSpace Datastore.Audit"
pveum user add kubernetes-csi@pve
pveum aclmod / -user kubernetes-csi@pve -role CSI
pveum user token add kubernetes-csi@pve csi -privsep 0
┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
╞══════════════╪══════════════════════════════════════╡
│ full-tokenid │ kubernetes-csi@pve!csi               │
├──────────────┼──────────────────────────────────────┤
│ info         │ {"privsep":"0"}                      │
├──────────────┼──────────────────────────────────────┤
│ value        │ xxxxx (see pw storage)               │
└──────────────┴──────────────────────────────────────┘
```

Add K8s node labels:

```sh
# From laptop:
kubectl label nodes k3s-01 k3s-02 k3s-03 k3s-04 k3s-05 k3s-06 topology.kubernetes.io/region=homelab
kubectl label node k3s-01 k3s-04 topology.kubernetes.io/zone=pve1
kubectl label node k3s-02 k3s-05 topology.kubernetes.io/zone=pve2
kubectl label node k3s-03 k3s-06 topology.kubernetes.io/zone=pve3
```

Install the local Kustomize files:

```sh
# Insert TOKEN into proxmox-csi-config.yaml, then:
k apply -k .
```

## Notes

### April 5 2025

- Installed k8s-proxmox-csi
    - PVs seem to get deleted when pods move
    - Todo: load balance 192.168.10.3:8006/api2/json ?
