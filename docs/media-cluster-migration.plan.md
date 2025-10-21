<!-- f6e77762-f810-41f8-ab3c-63771907dbe6 4b987c0c-6fea-4327-bc69-d20b14025cee -->
# Media Cluster to Homelab Migration Plan

## Overview

Migrate all WordPress sites from `./emc2-wp1-websites/` and media applications from `./media-srv-apps/media/` to the homelab cluster with Ceph-CSI persistent storage. The WordPress sites currently use `local-path` storage on the media server at `/home/emcniece/wp-websites/`, and media apps use hostPath volumes at `/mnt/zpool1/apps/media-test/`.

## Storage Strategy

**WordPress Sites**: Use CephFS (`csi-cephfs-sc`) for both MySQL and WordPress content

- Reason: Allows for RollingUpdate deployment strategy and better multi-node support
- Access Mode: ReadWriteMany for improved flexibility

**Media Apps**:

- **App configs**: CephFS (`csi-cephfs-sc`) for individual app configurations
- **Download storage**: 
  - Local-Path (`local-path`) for fast active downloads (incomplete files)
  - CephFS (`csi-cephfs-sc`) for completed downloads shared between downloaders and Tdarr
- **Shared media library**: CephFS (`csi-cephfs-sc`) with `ReadWriteMany` access mode for the multi-terabyte video library shared between media management apps and players

Both storage types persist after deployment deletion.

**Architecture**: See [./docs/media-architecture-diagram.md](./docs/media-architecture-diagram.md) for complete data flow and volume sharing diagrams.

## Directory Structure

All Kubernetes manifests will be organized in **app-specific directories** under `./homelab/apps/`:

**WordPress sites** (4 total):
- `./homelab/apps/createsleeprepeat/`
- `./homelab/apps/echoandflow/`
- `./homelab/apps/emc2.build/`
- `./homelab/apps/kamloopsdentalsociety/`

**Media applications** (9 total):
- `./homelab/apps/plex/`
- `./homelab/apps/sonarr/`
- `./homelab/apps/radarr/`
- `./homelab/apps/lidarr/`
- `./homelab/apps/deluge/`
- `./homelab/apps/sabnzbd/`
- `./homelab/apps/emby/`
- `./homelab/apps/plexpy/`
- `./homelab/apps/organizr-v2/`

**Shared resources**:
- `./homelab/apps/shared-pvcs.yaml` - shared PVCs (media-library, downloads-complete)
- `./homelab/apps/migration/` - temporary migration job manifests
- `./homelab/docs/` - architecture diagrams and documentation

## Migration Steps

### Phase 1: WordPress Sites Migration

Migrate 4 WordPress sites: `createsleeprepeat`, `echoandflow`, `emc2.build`, `kamloopsdentalsociety`

**For each site:**

1. **Create updated manifests in app-specific directories**

- Convert PV/PVC from `local-path` with hostPath to CephFS storage class
- Update `storageClassName: csi-cephfs-sc` in both mysql and wordpress PVCs
- Update `accessModes` to `ReadWriteMany` for better multi-node support
- Remove the PV definitions (Ceph CSI dynamically provisions)
- Keep existing secrets, services, and StatefulSets

2. **Transfer data from media server**

- Create temporary migration pod with Ceph PVC mounted
- Use `rsync` to copy from media server `/home/emcniece/wp-websites/{site}/wordpress/` and `/home/emcniece/wp-websites/{site}/mysql/` into the mounted PVCs
- Example: `rsync -avz --progress media-server:/home/emcniece/wp-websites/createsleeprepeat/ /mnt/transfer/`

3. **Deploy to homelab cluster**

- Apply namespace, secrets, PVCs, MySQL StatefulSet, WordPress Deployment
- Use RollingUpdate deployment strategy (enabled by CephFS ReadWriteMany)
- Verify pods are running and data is accessible

4. **Update ingress**

- Change ingress host from `createsleeprepeat.ca` to match existing domain
- Update Traefik ingress to use `websecure` entrypoint if needed
- Remove redirect rules in `./homelab/apps/whoami-media/lab-redirect.yaml` after verifying

### Phase 2: Media Apps Migration

Migrate 9 media apps: `plex`, `sonarr`, `radarr`, `lidarr`, `deluge`, `sabnzbd`, `emby`, `plexpy`, `organizr-v2`

**Directory structure on media server:**

- Configs: `/mnt/zpool1/apps/media-test/config/{app}/`
- Downloads: `/mnt/zpool1/apps/media-test/download/complete/`
- Media: `/mnt/zpool1/apps/media-test/data/{tv,movies,music,anime}/`

1. **Create shared storage manifests in `./homelab/apps/shared-pvcs.yaml`**

- Create one `media-library` PVC using CephFS (`csi-cephfs-sc`, `ReadWriteMany`, ~20Ti) for shared video content
- Create one `downloads-complete` PVC using CephFS (`csi-cephfs-sc`, `ReadWriteMany`, ~100Gi) for completed downloads
- Create individual app-config PVCs using CephFS (`csi-cephfs-sc`, `ReadWriteMany`, ~2-6Gi each)
- Create individual `[app]-downloads-incomplete` PVCs using Local-Path (`local-path`, `ReadWriteOnce`, ~100Gi) for fast local downloads (SABnzbd, Deluge only)

2. **Transfer multi-terabyte media library**

- Best option for several TB: Direct rsync from media server to a migration pod
- Create migration job pod with `media-library` and `downloads-complete` CephFS volumes mounted
- Run: `rsync -avz --info=progress2 media-server:/mnt/zpool1/apps/media-test/download/complete/ /downloads/`
- Run: `rsync -avz --info=progress2 media-server:/mnt/zpool1/apps/media-test/data/ /media/`
- This will take hours/days depending on network speed

3. **Transfer app configs**

- For each app, create temporary pod with app-specific config PVC
- Rsync app configs: `rsync -avz media-server:/mnt/zpool1/apps/media-test/config/{app}/ /config/`

4. **Update app manifests**

- Convert deployments from hostPath volumes to PVC references
- Update ingress hosts from `*.home.emc2.build` to `*.lab.emc2.build`
- Remove annotations like `io.rancher.container.pull_image` (legacy Rancher)
- Update `ADVERTISE_IP` for Plex to `https://plex.lab.emc2.build/`
- Adjust PUID/PGID if needed (currently 0 for media-srv, might want 1000 for homelab)

5. **Deploy to homelab cluster**

- Apply namespace `media`
- Apply all PVCs (wait for binding)
- Apply deployments, services, ingresses
- Verify all pods start and can access shared storage

### Phase 3: Cleanup & Deprecation

1. **Remove redirect rules**

- Delete/update `./homelab/apps/whoami-media/lab-redirect.yaml` ExternalName service pointing to `192.168.10.95`
- Remove any WordPress redirect ingresses from homelab cluster

2. **Verify functionality**

- Test all WordPress sites are accessible and functional
- Test Plex streaming, Sonarr/Radarr downloads work with shared storage
- Verify data persistence by deleting/recreating a test pod

3. **DNS updates** (manual, outside this plan)

- User will keep both clusters running temporarily
- WordPress sites continue using existing domains
- Media apps use new `*.lab.emc2.build` domains

4. **Media server shutdown** (deferred until user confirms)

- Stop all k8s workloads on media cluster
- Optionally keep media server hardware as backup/archive

## Key Files to Create

**WordPress (x4 sites):**

Each site directory contains:
- `namespace.yaml`
- `mysql-pvc.yaml` (CephFS, no PV definition)
- `wordpress-pvc.yaml` (CephFS, no PV definition)
- `mysql-secret.yaml` (copied from emc2-wp1-websites)
- `mysql-service.yaml`
- `mysql-statefulset.yaml`
- `wordpress-deployment.yaml` (includes service and ingress)
- `transfer-job.yaml` (for data migration from media server)

**Media apps:**

Shared resources:
- `./homelab/apps/shared-pvcs.yaml` (media-library and downloads-complete CephFS volumes)

Each app directory contains:
- `pvc.yaml` (individual CephFS config volume, plus local-path downloads-incomplete for SABnzbd/Deluge)
- `deployment.yaml` (updated volumes, ingress hosts to *.lab.emc2.build)
- `service.yaml`
- `ingress.yaml`

**Migration helpers:**

In `./homelab/apps/migration/`:
- `wordpress-transfer-job.yaml` (temporary, for data transfer)
- `media-transfer-job.yaml` (temporary, for data transfer)

## Migration Checklist

### Phase 1: WordPress Sites Migration ✅ **COMPLETED**

**WordPress Sites (4 total):**
- [x] **createsleeprepeat** (createsleeprepeat.ca)
  - [x] Deploy manifests to homelab cluster
  - [x] Transfer data from media server
  - [x] Verify site accessibility
  - [x] Test functionality
- [x] **echoandflow** (echoandflow.ca)
  - [x] Deploy manifests to homelab cluster
  - [x] Transfer data from media server
  - [x] Verify site accessibility
  - [x] Test functionality
- [x] **emc2.build** (emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Transfer data from media server
  - [x] Verify site accessibility
  - [x] Test functionality
  - [x] **Fixed memory limit issue** (increased from 128MB to 512MB)
- [x] **kamloopsdentalsociety** (kamloopsdentalsociety.ca)
  - [x] Deploy manifests to homelab cluster
  - [x] Transfer data from media server
  - [x] Verify site accessibility
  - [x] Test functionality

### Phase 2: Media Applications Migration

**Architecture & Documentation:**
- [x] **Create media architecture diagram** (./docs/media-architecture-diagram.md)
  - [x] Document data flow from user request to media playback
  - [x] Document volume sharing between applications
  - [x] Document storage strategy (Local-Path vs CephFS)
  - [x] Create visual Mermaid diagrams
- [x] **Audit and correct volume mounts**
  - [x] Fix Lidarr - remove downloads-complete mount (only needs media-library)
  - [x] Fix Radarr - remove downloads-complete mount (only needs media-library)
  - [x] Fix Sonarr - remove downloads-complete mount (only needs media-library)
  - [x] Verify SABnzbd - correct (has downloads-complete, not media-library)
  - [x] Verify Deluge - correct (has downloads-complete, not media-library)
  - [x] Verify Tdarr - correct (has both downloads-complete and media-library)
  - [x] Verify Plex - correct (has media-library only)
  - [x] Verify Emby - correct (has media-library only)

**Media Applications (9 total):**
- [x] **plex** (plex.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts verified (config, media-library)
  - [x] Transfer config from media server
  - [ ] Verify streaming functionality
  - [ ] Test media library access
- [x] **sonarr** (sonarr.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts corrected (config, media-library only)
  - [x] Transfer config from media server
  - [ ] Verify TV show management
  - [ ] Test download integration
- [x] **radarr** (radarr.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts corrected (config, media-library only)
  - [x] Transfer config from media server
  - [ ] Verify movie management
  - [ ] Test download integration
- [x] **lidarr** (lidarr.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts corrected (config, media-library only)
  - [x] Transfer config from media server
  - [ ] Verify music management
  - [ ] Test download integration
- [x] **deluge** (deluge.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts verified (config, downloads-incomplete, downloads-complete)
  - [x] Transfer config from media server
  - [ ] Verify torrent downloads
  - [ ] Test integration with *arr apps
- [x] **sabnzbd** (sabnzbd.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts verified (config, downloads-incomplete, downloads-complete)
  - [x] Transfer config from media server
  - [ ] Verify Usenet downloads
  - [ ] Test integration with *arr apps
- [x] **emby** (emby.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts verified (config, media-library)
  - [x] Transfer config from media server
  - [ ] Verify media streaming
  - [ ] Test media library access
- [x] **tdarr** (tdarr.lab.emc2.build)
  - [x] Deploy manifests to homelab cluster
  - [x] Volume mounts verified (config, downloads-complete, media-library, transcode-cache)
  - [ ] Verify transcoding functionality
  - [ ] Test media processing pipeline
- [ ] **organizr-v2** (organizr.lab.emc2.build)
  - [ ] Deploy manifests to homelab cluster
  - [ ] Transfer config from media server
  - [ ] Verify dashboard functionality
  - [ ] Test app integration

### Phase 3: Infrastructure & Cleanup

**Shared Resources:**
- [x] **Shared PVCs Created**
  - [x] Deploy shared CephFS PVCs (media-library, downloads-complete)
  - [x] Verify PVC binding and accessibility
- [ ] **Media Library Transfer**
  - [ ] Transfer multi-terabyte media library from media server
  - [ ] Verify all apps can access shared storage
  - [ ] Test file permissions and access
- [ ] **Downloads Transfer**
  - [ ] Transfer downloads folder from media server
  - [ ] Verify download client access
  - [ ] Test download completion handling

**Cleanup Tasks:**
- [ ] Remove lab-redirect.yaml ExternalName service
- [ ] Update DNS records (manual)
- [ ] Verify all services accessible via new domains
- [ ] Test data persistence (delete/recreate pods)
- [ ] Clean up migration jobs
- [ ] Shutdown media server (after verification)

### To-dos

- [x] Create WordPress manifests with CephFS storage for all 4 sites (createsleeprepeat, echoandflow, emc2.build, kamloopsdentalsociety)
- [x] Create migration job manifests to transfer WordPress data from media server to homelab cluster
- [x] Create shared CephFS PVCs for media library and downloads folder
- [x] Create updated media app manifests (plex, sonarr, radarr, lidarr, deluge, sabnzbd, emby, plexpy, organizr) with Ceph storage
- [x] Create migration job manifest to transfer multi-terabyte media library from media server
- [x] Remove or update lab-redirect.yaml and WordPress redirect rules after migration verification
- [x] Create deployment README with instructions for applying manifests and verifying migration
- [x] **Fixed WordPress memory limit issue** (emc2.build site - increased from 128MB to 512MB)
- [x] **Create media architecture diagram** (./docs/media-architecture-diagram.md)
  - Data flow diagram showing content journey from user to playback
  - Volume sharing diagram showing storage mount relationships
  - Documentation of storage strategy and volume types
- [x] **Audit and correct media app volume mounts**
  - Fixed Lidarr, Radarr, Sonarr to remove incorrect downloads-complete mounts
  - Verified downloaders (SABnzbd, Deluge) have correct mounts
  - Verified Tdarr bridges downloads-complete to media-library correctly
  - Verified players (Plex, Emby) only access media-library

