# Media Cluster Migration - Deployment Guide

This directory contains all the Kubernetes manifests for migrating WordPress sites and media applications from the media cluster to the homelab cluster using Ceph-CSI storage.

## Directory Structure

### WordPress Sites (4 total)
- `./createsleeprepeat/` - createsleeprepeat.ca
- `./echoandflow/` - echoandflow.ca  
- `./emc2.build/` - emc2.build
- `./kamloopsdentalsociety/` - kamloopsdentalsociety.ca

### Media Applications (9 total)
- `./plex/` - plex.lab.emc2.build
- `./sonarr/` - sonarr.lab.emc2.build
- `./radarr/` - radarr.lab.emc2.build
- `./lidarr/` - lidarr.lab.emc2.build
- `./deluge/` - deluge.lab.emc2.build
- `./sabnzbd/` - sabnzbd.lab.emc2.build
- `./emby/` - emby.lab.emc2.build
- `./plexpy/` - plexpy.lab.emc2.build
- `./organizr-v2/` - organizr.lab.emc2.build

### Shared Resources
- `./media/` - namespace and shared CephFS PVCs
- `./migration/` - temporary data transfer jobs

## Prerequisites

1. **Ceph-CSI Storage Classes Available**:
   - `csi-rbd-sc` for single-instance app configs
   - `csi-cephfs-sc` for shared media library

2. **Media Server Access**:
   - SSH access to media server (IP: 192.168.1.100)
   - WordPress data at `/home/emcniece/wp-websites/`
   - Media data at `/mnt/zpool1/apps/media-test/`

## Deployment Steps

### Phase 1: WordPress Sites Migration

1. **Deploy WordPress sites**:
   ```bash
   # Deploy each site
   kubectl apply -f ./createsleeprepeat/
   kubectl apply -f ./echoandflow/
   kubectl apply -f ./emc2.build/
   kubectl apply -f ./kamloopsdentalsociety/
   ```

2. **Transfer WordPress data**:
   ```bash
   # Media server IP is already configured (192.168.1.100)
   kubectl apply -f ./migration/wordpress-transfer-job.yaml
   
   # Monitor transfer progress
   kubectl logs -f job/wordpress-data-transfer
   ```

3. **Verify WordPress sites**:
   - Check pods are running: `kubectl get pods -n createsleeprepeat`
   - Test site accessibility via existing domains

### Phase 2: Media Applications Migration

1. **Deploy shared storage**:
   ```bash
   kubectl apply -f ./media/
   ```

2. **Transfer media library** (this will take hours/days):
   ```bash
   # Media server IP is already configured (192.168.1.100)
   kubectl apply -f ./migration/media-transfer-job.yaml
   
   # Monitor transfer progress
   kubectl logs -f job/media-library-transfer
   ```

3. **Deploy media applications**:
   ```bash
   # Deploy all media apps
   kubectl apply -f ./plex/
   kubectl apply -f ./sonarr/
   kubectl apply -f ./radarr/
   kubectl apply -f ./lidarr/
   kubectl apply -f ./deluge/
   kubectl apply -f ./sabnzbd/
   kubectl apply -f ./emby/
   kubectl apply -f ./plexpy/
   kubectl apply -f ./organizr-v2/
   ```

4. **Transfer app configs** (for each app):
   ```bash
   # Example for Plex
   kubectl run plex-config-transfer --image=alpine:latest --rm -it --restart=Never -- \
     sh -c "apk add rsync openssh-client && \
            rsync -avz root@192.168.1.100:/mnt/zpool1/apps/media-test/config/plex/ /config/"
   ```

### Phase 3: Cleanup

1. **Remove redirect rules**:
   ```bash
   # Update or remove lab-redirect.yaml
   kubectl apply -f ./whoami-media/lab-redirect.yaml
   ```

2. **Verify functionality**:
   - Test all WordPress sites
   - Test Plex streaming
   - Test Sonarr/Radarr downloads
   - Verify data persistence

3. **Clean up migration jobs**:
   ```bash
   kubectl delete job wordpress-data-transfer
   kubectl delete job media-library-transfer
   ```

## Storage Configuration

### WordPress Sites
- **MySQL**: Ceph RBD (`csi-rbd-sc`) - 1Gi each
- **WordPress**: Ceph RBD (`csi-rbd-sc`) - 1Gi each

### Media Applications
- **App Configs**: Ceph RBD (`csi-rbd-sc`) - 5-50Gi each
- **Media Library**: Ceph CephFS (`csi-cephfs-sc`) - 20Ti shared
- **Downloads**: Ceph CephFS (`csi-cephfs-sc`) - 5Ti shared

## Troubleshooting

### PVC Not Binding
```bash
kubectl describe pvc <pvc-name> -n <namespace>
kubectl get storageclass
```

### Pod Stuck in Pending
```bash
kubectl describe pod <pod-name> -n <namespace>
```

### Data Transfer Issues
```bash
# Check job status
kubectl get jobs -n media
kubectl logs job/media-library-transfer -n media
```

## Notes

- All WordPress sites maintain their existing domains
- Media apps use new `*.lab.emc2.build` domains
- Both clusters will run temporarily during migration
- Media server can be shut down after verification
