# K8s Ceph-CSI Installation

Source: https://medium.com/@extio/simplifying-storage-management-with-kubernetes-ceph-csi-f384fa635437

This doc appears to be outdated as of April 2025.

```sh
git clone https://github.com/ceph/ceph-csi.git
git clone https://github.com/ceph/ceph-csi-operator.git
```

Using this instead: https://github.com/ceph/ceph-csi-operator/blob/main/docs/quick-start.md

```sh
# Install:
k create -f ./ceph-csi-operator/deploy/all-in-one/install.yaml

# Verify:
kubectl get pods -n ceph-csi-operator-system

# Install specific RBD driver:
k apply -f ./ceph-osi-operator-resources.yaml

# Verify:
kubectl get pods -n ceph-csi-operator-system

# Removal:
k delete -f ./ceph-osi-operator-resources.yaml
```

**Note**: VM processor type should be "host" to avoid error:

    csi-rbdplugin Fatal glibc error: CPU does not support x86-64-v2


After getting clarification in https://github.com/ceph/ceph-csi-operator/issues/231 we will now try installing from https://github.com/ceph/ceph-csi/tree/devel/charts/ceph-csi-rbd


Created a CephFS in Proxmox, then found https://github.com/ceph/ceph-csi/discussions/4396

To create a CephFS user:

```sh
ssh pve1
sudo ceph auth get-or-create client.k8s-csi-rbd
sudo ceph auth caps client.k8s-csi-rbd mon 'allow *' osd 'allow *' mgr 'allow *' mds 'allow *'
```

Filled out ./ceph-rbd-values.yaml and ./ceph-cephfs-values.yaml.

Installing:

```sh
helm repo add ceph-csi https://ceph.github.io/csi-charts
kubectl create namespace "ceph-csi-rbd"

helm install --namespace "ceph-csi-rbd" "ceph-csi-rbd" ceph-csi/ceph-csi-rbd --values ./ceph-rbd-values.yaml

kubectl create namespace ceph-csi-cephfs

helm install --namespace "ceph-csi-cephfs" "ceph-csi-cephfs" ceph-csi/ceph-csi-cephfs --values ./ceph-cephfs-values.yaml

# Install test pods: (These are good for demos!)
k apply -f ./ceph-rbd-test-deployment.yaml
k apply -f ./ceph-cephfs-test-deployment.yaml
```

Encountered in `ceph-csi-rbd/ceph-csi-rbd-provisioner-6dcb6586c4-4j26t` while deploying cephfs test:
```
csi-snapshotter E0409 23:33:02.648294       1 reflector.go:158] "Unhandled Error" err="github.com/kubernetes-csi/external-snapshotter/client/v8/informers/externalversions/factory.go:142: Failed to watch *v1.VolumeSnapshotClass: failed to lis │
│ t *v1.VolumeSnapshotClass: the server could not find the requested resource (get volumesnapshotclasses.snapshot.storage.k8s.io)" logger="UnhandledError"
```

Messed around with /Users/emcniece/code/homelab/homelab/infra/ceph-csi/ceph-csi/scripts/install-snapshot.sh until the `sed` commands passed. Had to manually insert some content into /Users/emcniece/code/tmp/ceph/snapshot-controller.yaml. Suspect that `sed -i` has different handling on OSX BSD sed.

Then installed volumesnapshot resources:
```sh
pushd /Users/emcniece/code/homelab/homelab/infra/ceph-csi/ceph-csi/scripts
./install-snapshot.sh install # sed fixes were here
popd
k apply -f ceph-csi/examples/cephfs/snapshotclass.yaml
```

This fixed the `volumesnapshotclasses.snapshot.storage.k8s.io` error.

Next error:

```sh
# ceph-csi-cephfs/ceph-csi-cephfs-provisioner-7c7f646b77-dwl48
csi-provisioner I0410 00:36:31.352880       1 event.go:389] "Event occurred" object="ceph-fs-test/csi-cephfs-pvc" fieldPath="" kind="PersistentVolumeClaim" apiVersion="v1" type="Warning" reason="ProvisioningFailed" message="failed to provision volume with StorageClass \"csi-cephfs-sc\": rpc error: code = InvalidArgument desc = failed to get connection: connecting failed: rados: ret=-22, Invalid argument"
```

Apr 10 12:30am: Troubleshot over Slack, needed to set the admin* values in the `csi-cephfs-secret` to the same values as `user*`. This is a migration/deprecation issue.

Next error:

```
Warning  ProvisioningFailed    2s (x5 over 7s)  cephfs.csi.ceph.com_ceph-csi-cephfs-provisioner-7c7f646b77-dwl48_ff9ce75c-36ad-4882-9c35-df2e94e5ecf3  failed to provision volume with StorageClass "csi-cephfs-sc": rpc error: code = Internal │
│  desc = rados: ret=-2, No such file or directory: "subvolume group 'csi' does not exist"
```

Remedy: `ceph fs subvolumegroup create cephfs csi`. This is missing from the sub-docs, included at https://github.com/ceph/ceph-csi/blob/0f572b62d18123f18a3a52233a60189aac36e1f1/docs/static-pvc.md?plain=1#L219. Note to revisit docs 

Shared volumes now work!

---

## October 14, 2025: Ceph Manager Crash (Python 3.13 Incompatibility)

### Issue
After a routine server reboot, the Ceph cluster manager (`ceph-mgr`) failed to start on all nodes with a segmentation fault. This prevented CephFS PVC provisioning from working.

**Symptoms:**
- `ceph-mgr@pve*.service` crashed immediately with `SIGSEGV`
- Error: `*** Caught signal (Segmentation fault) ** in thread io_context_pool`
- Stack trace showed Python 3.13 library calls: `/lib/x86_64-linux-gnu/libpython3.13.so.1.0`
- Ceph status showed: `health: HEALTH_WARN - no active mgr`

### Root Cause
**Ceph 19.2.3-pve1 is incompatible with Python 3.13.** Proxmox upgraded to Python 3.13, but Ceph was built/tested with Python 3.11/3.12. Python 3.13 introduced breaking changes in the C API (`PyType_LookupRef()`, `PyObject_GetAttr()`), causing the RBD Python bindings to crash.

**Tracked bugs:**
- https://tracker.ceph.com/issues/68529 - "ceph-mgr crashes with Python 3.13"
- https://forum.proxmox.com/threads/ceph-manager-crash-after-upgrade-to-pve-8-3.157449/
- Fixed in Ceph 19.2.4+ and 18.2.5+

### Solution
Upgraded Ceph packages from `19.2.3-pve1` to `19.2.3-pve2`:

```bash
# On all Proxmox nodes (pve1, pve2, pve3)
apt update
apt upgrade -y

# Start the manager (should now work)
systemctl start ceph-mgr@pve2.service
systemctl status ceph-mgr@pve2.service

# Verify manager is running
pveceph status
# Should show: mgr: pve2(active, since XXs)

# Create the CephFS subvolume group (required for CSI)
ceph fs subvolumegroup create cephfs csi
ceph fs subvolumegroup ls cephfs

# Verify Ceph health
ceph status
```

**Result:** Manager started successfully on `19.2.3-pve2`, which included Python 3.13 compatibility patches. CephFS PVC provisioning now works correctly.

### Additional Notes
- The `-pve2` package revision included backported fixes for Python 3.13 compatibility
- If upgrading doesn't work, you can manually create CephFS structures by mounting the filesystem directly
- Consider pinning CSI operator images to specific versions (not `:latest`) to avoid unexpected API changes
