# Ceph OSD Recovery Guide

## Incident Overview

**Date**: January 22, 2026  
**Issue**: OSD.4 failure causing Kubernetes pod failures and website outages  
**Root Cause**: Disk I/O errors on `/dev/sdi` (WDC 18TB drive) on pve2 after pve3 reboot  
**Impact**: 14 pods stuck terminating, WordPress websites down, MySQL database timeouts  
**Resolution Time**: ~3.5 hours (investigation + recovery)

---

## Symptoms Observed

### Kubernetes Cluster
- 14 pods stuck in `Terminating` state on k3s-06 node for days
- WordPress website (https://emc2.build) returning HTTP 524 errors
- MySQL pod experiencing 10+ hour query hangs
- CephFS volume mount failures

### Ceph Cluster
- OSD.4 down and out
- 3 OSDs experiencing slow operations in BlueStore
- 24 PGs inactive/degraded
- 4.6% objects degraded
- 1 daemon crashed (osd.4)
- 1 MDS reporting slow metadata I/O

---

## Investigation Steps

### 1. Check Kubernetes Cluster Status

```bash
# List all nodes
kubectl get nodes

# Check for stuck pods across all namespaces
kubectl get pods --all-namespaces | grep -E "(Terminating|Pending|Error)"

# Describe problematic node
kubectl describe node k3s-06

# Check recent events
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -50
```

### 2. Check Ceph Cluster Health

```bash
# SSH to Proxmox node
ssh pve3

# Check overall status
ceph status
ceph health detail

# Check OSD tree
ceph osd tree

# Check OSD performance
ceph osd perf

# View placement group states
ceph pg stat
ceph pg dump pgs | grep -E "inactive|degraded"

# Check for crashes
ceph crash ls
```

### 3. Identify Failed OSD

```bash
# List OSDs and their status
ceph osd tree

# Check specific OSD status (found OSD.4 was down)
ssh pve2 "systemctl status ceph-osd@4"

# Check OSD logs
ssh pve2 "journalctl -u ceph-osd@4 --no-pager -n 100"
```

### 4. Diagnose Disk Hardware

```bash
# Check physical disk backing OSD.4
ssh pve2 "ls -lah /var/lib/ceph/osd/ceph-4/"
ssh pve2 "readlink -f /var/lib/ceph/osd/ceph-4/block"

# Identify LVM backing device
ssh pve2 "lvs -o lv_name,vg_name,lv_path,devices | grep osd-block"

# Found: /dev/sdi backing OSD.4

# Check disk health
ssh pve2 "smartctl -H /dev/sdi"
ssh pve2 "smartctl -a /dev/sdi | grep -E '(Model|Serial|Health|Reallocated|Pending|Offline)'"

# Check for disk errors
ssh pve2 "dmesg | grep -i 'sdi\|error' | tail -50"

# Test disk read performance
ssh pve2 "dd if=/dev/sdi of=/dev/null bs=4M count=100 iflag=direct"
ssh pve2 "hdparm -t /dev/sdi"
```

**Finding**: Disk had I/O errors at specific block offsets, BlueStore metadata corrupted.

---

## Resolution Steps

### Phase 1: Immediate Stabilization (Kubernetes)

#### Force Delete Stuck Pods

```bash
# List all terminating pods
kubectl get pods --all-namespaces -o wide | grep Terminating

# Force delete stuck pods (done in batches)
kubectl delete pod traefik-7dd6b575bf-65jp9 -n traefik-system --force --grace-period=0
kubectl delete pod heimdall-f6484d7c9-r7qfs homepage-7c89fd4c99-xfpdl homer-745f8555fb-fjpq4 -n default --force --grace-period=0
kubectl delete pod immich-machine-learning-5d578b8489-kcm58 immich-valkey-56758f8fc8-sdq64 postgres-858c6c9d55-m7btm -n immich --force --grace-period=0
kubectl delete pod calibre-downloader-56895bbb74-sv9qd calibre-web-58ffb48775-d4jml organizr-v2-544f85d699-bm42p prowlarr-5f9468bdf4-kfkh2 sabnzbd-64b8f767b6-drspl -n media --force --grace-period=0
kubectl delete pod ceph-csi-cephfs-provisioner-6fc6ff968d-bw6vx -n ceph-csi-cephfs --force --grace-period=0
kubectl delete pod ceph-csi-rbd-provisioner-65fdfd564d-g5kr4 -n ceph-csi-rbd --force --grace-period=0

# Force delete MySQL pod (stuck due to CephFS issues)
kubectl delete pod mysql-0 -n emc2-build --force --grace-period=0
```

#### Cordon Problematic Node

```bash
# Prevent new pods from scheduling on k3s-06
kubectl cordon k3s-06

# Verify node status
kubectl get nodes
```

**Result**: New pods created on healthy nodes (k3s-04, k3s-05), websites came back online.

---

### Phase 2: Ceph Cluster Recovery

#### Archive Crash Reports

```bash
ssh pve3 "ceph crash archive-all"
```

#### Monitor Recovery with 7 OSDs

```bash
# Ceph automatically began rebalancing with 7 OSDs
ssh pve3 "ceph status"
ssh pve3 "watch -n 10 'ceph status'"
```

At this point, cluster was functional but degraded (4-5% objects degraded).

---

### Phase 3: Recover OSD.4 (Full Disk Wipe & Recreate)

#### Step 1: Remove Corrupted LVM Volumes

```bash
ssh pve2

# Remove logical volume
lvremove -f /dev/ceph-807421da-9530-4336-8dbd-8728cceb6587/osd-block-13a455a8-f7e2-4365-9b0f-365f531e1cb4

# Remove volume group
vgremove -f ceph-807421da-9530-4336-8dbd-8728cceb6587

# Remove physical volume
pvremove -f /dev/sdi
```

#### Step 2: Wipe Disk Completely

```bash
# Remove all filesystem signatures
wipefs -a /dev/sdi

# Zap GPT partition table
sgdisk --zap-all /dev/sdi

# Write zeros to beginning of disk (1GB)
dd if=/dev/zero of=/dev/sdi bs=1M count=1000 oflag=direct

# Reread partition table
blockdev --rereadpt /dev/sdi
partprobe /dev/sdi
```

#### Step 3: Test Disk Stability

```bash
# Test read performance
dd if=/dev/sdi of=/dev/null bs=4M count=100 iflag=direct

# Test write performance
dd if=/dev/zero of=/dev/sdi bs=4M count=100 oflag=direct

# Check for new errors
dmesg | grep -i 'sdi' | tail -20
```

**Result**: Disk stable at 250+ MB/s read/write, no new errors.

#### Step 4: Remove OSD from Ceph Cluster

```bash
ssh pve3

# Remove OSD from cluster
ceph osd rm 4

# Remove authentication
ceph auth del osd.4

# Remove from CRUSH map
ceph osd crush rm osd.4
```

#### Step 5: Recreate OSD (Two-Step Process)

**Important**: Use separate prepare and activate steps (combined `create` command failed).

```bash
ssh pve2

# Step 5a: Prepare OSD
ceph-volume lvm prepare --bluestore --data /dev/sdi

# Note the OSD ID and UUID from output (e.g., osd.4, uuid: 51bb82b9-d50c-4ce9-9f84-a724afa37545)

# Step 5b: Activate OSD
ceph-volume lvm activate 4 51bb82b9-d50c-4ce9-9f84-a724afa37545

# Verify service is running
systemctl status ceph-osd@4
```

#### Step 6: Verify OSD is Online

```bash
ssh pve3

# Check OSD tree
ceph osd tree

# Verify all 8 OSDs are up
ceph status

# Monitor recovery
watch -n 10 'ceph status'
```

---

## Verification & Monitoring

### Check Cluster Health

```bash
# Overall status
ssh pve3 "ceph status"

# Detailed health
ssh pve3 "ceph health detail"

# OSD status
ssh pve3 "ceph osd stat"
ssh pve3 "ceph osd df tree"

# Placement group status
ssh pve3 "ceph pg stat"
ssh pve3 "ceph pg dump pgs | grep -v active+clean | head -20"
```

### Monitor Recovery Progress

```bash
# Watch live updates
ssh pve3 "ceph -w"

# Check recovery rate
ssh pve3 "ceph status | grep recovery"

# Check for undersized PGs (temporary during recovery)
ssh pve3 "ceph pg dump pgs 2>/dev/null | grep undersized | wc -l"
```

### Kubernetes Cluster Health

```bash
# Check all pods are running
kubectl get pods --all-namespaces | grep -v Running

# Verify no stuck pods
kubectl get pods --all-namespaces | grep -E "(Terminating|Pending)"

# Test website access
curl -I -L https://emc2.build

# Check MySQL pod
kubectl logs -n emc2-build mysql-0 --tail=50
kubectl exec -n emc2-build mysql-0 -- mysql -uroot -pwordpress -e "SHOW PROCESSLIST;"
```

---

## Post-Recovery Actions

### Uncordon k3s-06 Node

```bash
# Once Ceph is healthy
kubectl uncordon k3s-06

# Verify
kubectl get nodes
```

### Monitor for 24-48 Hours

```bash
# Check Ceph daily
ssh pve3 "ceph status"

# Check for OSD errors
ssh pve2 "journalctl -u ceph-osd@4 --since '1 hour ago' | grep -i error"

# Check disk health
ssh pve2 "smartctl -a /dev/sdi | grep -E '(Health|Reallocated|Pending)'"
```

---

## Prevention & Monitoring

### Set Up Ceph Monitoring Alerts

```bash
# Check current alert configuration
ssh pve3 "ceph config dump | grep alert"

# Set up monitoring for:
# - OSD down/out
# - PG stuck states
# - Slow operations
# - Disk failures
```

### Regular Health Checks

Create a daily health check script:

```bash
#!/bin/bash
# /root/ceph-health-check.sh

echo "=== Ceph Status ==="
ceph status

echo -e "\n=== OSD Tree ==="
ceph osd tree | grep -E "(down|out)"

echo -e "\n=== Slow Ops ==="
ceph health detail | grep -i slow

echo -e "\n=== Disk Health ==="
for host in pve2 pve3; do
    echo "--- $host ---"
    ssh $host 'for disk in /dev/sd{b..i}; do 
        [ -e $disk ] && echo "$disk: $(smartctl -H $disk 2>/dev/null | grep "SMART Health Status")"
    done'
done
```

### Kubernetes Pod Disruption Budgets

Add PDBs for critical services:

```yaml
# pdb-wordpress.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: wordpress-pdb
  namespace: emc2-build
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: wordpress
```

### Monitor CephFS Performance

```bash
# Check MDS status
ssh pve3 "ceph mds stat"

# Check slow requests
ssh pve3 "ceph daemon mds.pve2 perf dump"

# Check client sessions
ssh pve3 "ceph tell mds.* client ls"
```

---

## Troubleshooting Reference

### Common Issues During OSD Recovery

#### Issue: OSD Won't Start

```bash
# Check logs
journalctl -u ceph-osd@4 -n 100

# Common causes:
# - Corrupted BlueStore metadata
# - LVM device mapper issues
# - Disk I/O errors

# Solution: Full wipe and recreate (see Phase 3 above)
```

#### Issue: "Unable to read OSD superblock"

```bash
# This means BlueStore metadata is corrupted
# Full disk wipe required:
wipefs -a /dev/sdX
sgdisk --zap-all /dev/sdX
dd if=/dev/zero of=/dev/sdX bs=1M count=1000 oflag=direct
```

#### Issue: Pods Stuck in Terminating

```bash
# Force delete with zero grace period
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# If still stuck, check for finalizers
kubectl patch pod <pod-name> -n <namespace> -p '{"metadata":{"finalizers":null}}'
```

#### Issue: CephFS Mount Timeouts

```bash
# Check MDS status
ceph mds stat

# Check for slow operations
ceph health detail | grep MDS

# Restart MDS if needed
systemctl restart ceph-mds@<hostname>
```

#### Issue: PGs Stuck Undersized for 24+ Hours

```bash
# Check what's blocking recovery
ceph pg dump pgs | grep undersized

# Check recovery priority
ceph osd pool get <pool-name> recovery_priority

# Increase recovery priority temporarily
ceph osd pool set <pool-name> recovery_priority 5

# Check backfill/recovery limits
ceph config get osd osd_max_backfills
ceph config get osd osd_recovery_max_active

# Temporarily increase (if cluster can handle it)
ceph tell 'osd.*' config set osd_max_backfills 3
ceph tell 'osd.*' config set osd_recovery_max_active 5
```

---

## Key Learnings

### What Worked Well
1. **Force deleting stuck pods** immediately restored service
2. **Separating prepare/activate** steps for OSD creation succeeded where combined `create` failed
3. **Full disk wipe** cleared corrupted metadata
4. **Cluster redundancy** (size=2) protected data during OSD failure

### What Could Be Improved
1. **Automated monitoring** for OSD failures
2. **Pod disruption budgets** to prevent all replicas terminating
3. **Earlier disk health checks** might have predicted failure
4. **Documented recovery procedures** (this document!)

### Commands That Failed (Avoid These)

```bash
# DON'T: Try to use corrupted OSD
ceph-volume lvm create --bluestore --data /dev/sdi --osd-id 4
# This creates and tries to activate in one step, fails on corrupted disks

# DON'T: Try to recreate without full wipe
ceph-volume lvm prepare --bluestore --data /dev/sdi --osd-id 4
# If disk has any remnants, this will fail

# DO: Full wipe then prepare/activate separately
wipefs -a /dev/sdi && sgdisk --zap-all /dev/sdi
dd if=/dev/zero of=/dev/sdi bs=1M count=1000 oflag=direct
ceph-volume lvm prepare --bluestore --data /dev/sdi
ceph-volume lvm activate <id> <uuid>
```

---

## Timeline Summary

| Time | Action | Result |
|------|--------|--------|
| 08:13 | OSD.4 crashed on pve2 | Ceph cluster degraded |
| ~10:00 | User reports websites down | Investigation begins |
| 10:30 | Identified 14 stuck pods | Force deleted terminating pods |
| 10:45 | MySQL restarted, moved to k3s-05 | Websites back online |
| 11:00 | Cordoned k3s-06 | Pods stable on healthy nodes |
| 11:15 | Investigated OSD.4 disk | Found I/O errors |
| 11:30 | Attempted OSD recovery | Initial attempts failed |
| 12:45 | Full disk wipe | Disk stable |
| 13:00 | Recreated OSD.4 | OSD came online |
| 13:15 | Verified cluster recovery | 8/8 OSDs operational |

**Total Downtime**: ~3.5 hours  
**Final Status**: All systems operational, recovery in progress

---

## smartd: Drive Swap Procedure (pve2)

pve2's `/etc/smartd.conf` uses **explicit stable by-id paths** instead of `DEVICESCAN`. This was changed on 2026-05-23 after `DEVICESCAN` repeatedly fired false SMART alerts when iDRAC's USB Virtual Floppy reconnected and stole `/dev/sdd` from the WDC Ceph OSD that previously held that node.

When a Ceph OSD drive is physically replaced on pve2, update smartd to track the new drive:

### 1. Find the new drive's stable path

After the new drive is installed and Ceph provisioning is complete:

```bash
ssh pve2 "ls -la /dev/disk/by-id/ | grep scsi-3 | grep -v dm-"
```

The new drive will have an unfamiliar WWN. Cross-reference with `lsblk` to confirm which `/dev/sdX` it maps to.

### 2. Update /etc/smartd.conf

Replace the old `scsi-3...` entry for the swapped drive with the new one. Each entry is commented with the drive's serial number for easy identification:

```bash
ssh pve2 "nano /etc/smartd.conf"
```

Entry format:
```
# /dev/sdX - WDC WUH721818AL4200 S/N <SERIAL> (Ceph OSD, SAS)
/dev/disk/by-id/scsi-3<WWN> -d scsi -a -m root -M exec /usr/share/smartmontools/smartd-runner
```

### 3. Restart smartd

```bash
ssh pve2 "systemctl restart smartmontools && systemctl status smartmontools --no-pager | head -10"
```

Confirm the log shows the correct number of devices being monitored (currently 5: 1 ATA + 4 SCSI).

### Why not DEVICESCAN?

The iDRAC USB virtual media interface (Virtual CD, Virtual Floppy, LCDRIVE) appears as SCSI block devices and gets assigned `/dev/sdd` or similar node letters on reconnect. `DEVICESCAN` picks these up, fails to read SMART values from the USB bridge, and sends false alerts tagged with whatever real drive last held that node. Stable by-id paths are immune to this.

---

## Related Documentation

- [Ceph CSI README](./ceph-csi/README.md)
- [K8s Proxmox CSI](./k8s-proxmox-csi/README.md)
- [Traefik Configuration](./traefik/)

## External References

- [Ceph OSD Management](https://docs.ceph.com/en/latest/rados/operations/add-or-rm-osds/)
- [Ceph Troubleshooting](https://docs.ceph.com/en/latest/rados/troubleshooting/)
- [ceph-volume Usage](https://docs.ceph.com/en/latest/ceph-volume/lvm/)
- [Kubernetes Force Delete Pods](https://kubernetes.io/docs/tasks/run-application/force-delete-stateful-set-pod/)
