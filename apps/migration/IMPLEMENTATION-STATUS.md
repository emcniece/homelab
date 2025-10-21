# Large Media Migration - Implementation Status

**Status:** ✅ **COMPLETE - Ready to Deploy**  
**Date:** October 16, 2025  
**Estimated Migration Time:** 2-4 weeks after deployment

---

## Implementation Summary

All required files have been created and are ready for deployment. The migration infrastructure is complete and validated.

## Files Created

### Infrastructure Files ✅

1. **`apps/migration/media-staging-pvc.yaml`** (215 bytes)
   - 20Ti CephFS staging volume
   - ReadWriteMany access mode
   - Temporary storage for source files

2. **`apps/migration/filebot-pod.yaml`** (474 bytes)
   - FileBot container for file organization
   - Mounts staging volume
   - User/Group ID: 1000

3. **`apps/migration/staging-transfer-job.yaml`** (3.7K)
   - rsync job using `instrumentisto/rsync-ssh`
   - SSH key authentication via `emc-ssh-key` secret
   - Transfers TV, movies, mixed files, and music
   - Backoff limit: 3 retries

### Updated Files ✅

4. **`apps/tdarr/deployment.yaml`** (Modified)
   - Added `/staging` mount to tdarr container
   - Added `/staging` mount to tdarr-node containers
   - Mounted `media-staging` PVC

### Documentation Files ✅

5. **`apps/migration/README.md`** (5.6K)
   - Quick start guide
   - Phase-by-phase commands
   - Troubleshooting section

6. **`apps/migration/DEPLOYMENT-CHECKLIST.md`** (Just created)
   - Step-by-step deployment checklist
   - Pre-flight checks
   - Troubleshooting guide
   - Quick reference commands

7. **`docs/large-media-migration.plan.md`** (33K)
   - Complete detailed migration plan
   - All 8 phases documented
   - TCL 65R613-CA optimized settings
   - Risk mitigation strategies

8. **`docs/media-migration-implementation-summary.md`** (5.7K)
   - Overview of implementation
   - Workflow diagrams
   - Timeline estimates

---

## Migration Workflow

```
┌──────────────────────────┐
│    Media Server          │
│    192.168.1.100         │
│                          │
│  /mnt/zpool1/apps/       │
│  media-test/             │
└────────────┬─────────────┘
             │
             │ Phase 2: staging-transfer-job
             │ (rsync via SSH)
             ↓
┌──────────────────────────┐
│  Staging Volume (20Ti)   │
│  /staging/               │
│                          │
│  - tv/                   │
│  - movies/               │
│  - unsorted/             │
└────────────┬─────────────┘
             │
             │ Phase 3: FileBot
             │ (sort & rename)
             ↓
┌──────────────────────────┐
│  Staging Volume          │
│  (organized)             │
│                          │
│  - tv/ (sorted)          │
│  - movies/ (sorted)      │
└────────────┬─────────────┘
             │
             │ Phase 5: Tdarr
             │ (transcode H.265)
             ↓
┌──────────────────────────┐
│  Media Library (20Ti)    │
│  /media/                 │
│                          │
│  - tv/ (transcoded)      │
│  - movies/ (transcoded)  │
│  - music/ (direct copy)  │
└────────────┬─────────────┘
             │
             │ Phase 6: Media Apps
             ↓
┌──────────────────────────┐
│  Plex, Sonarr, Radarr    │
│  Lidarr, Emby            │
│                          │
│  TCL 65R613-CA TV        │
└──────────────────────────┘
```

---

## Configuration Details

### Tdarr Transcode Settings (TCL TV Optimized)

**Video:**
- Codec: H.265/HEVC (libx265)
- CRF: 22 (quality/size balance)
- Preset: fast (CPU only, no GPU)
- Pixel Format: yuv420p10le (10-bit color)
- Resolution: Keep original (no downscaling)

**Audio:**
- Action: Copy (preserve AC3, AAC, EAC3)
- 5.1 Surround: Preserved
- No downmixing

**Subtitles:**
- Action: Copy all subtitle streams

**FFmpeg Command:**
```bash
-c:v libx265 -crf 22 -preset fast -pix_fmt yuv420p10le -c:a copy -c:s copy
```

### FileBot Naming Convention

**Format:**
```
{plex.replaceAll(/[\s.]/, '_').replaceAll(/[^a-zA-Z0-9_\-\/()]/, '')}
```

**Result:**
- Spaces → Underscores
- Special characters → Removed
- Example: `ShowName_S01E01_Episode_Title.mkv`

---

## Resource Requirements

### Storage

| Volume | Size | Type | Purpose | Lifespan |
|--------|------|------|---------|----------|
| media-staging | 20Ti | CephFS RWX | Temporary source storage | Delete after verification |
| media-library | 20Ti | CephFS RWX | Final transcoded media | Permanent |
| transcode-cache | 100Gi | CephFS RWX | Tdarr temp files | Permanent |

**Total during migration:** ~40Ti (staging + media-library)

### Compute

| Resource | Count | CPU Workers | Purpose |
|----------|-------|-------------|---------|
| tdarr | 1 pod | 2 workers | Tdarr server |
| tdarr-node | 2 pods | 2 workers each | Transcode workers |
| filebot-sorter | 1 pod | N/A | File organization |

**Total CPU workers:** 4 (no GPU available)

---

## Timeline Estimates

### Phase 1: Setup Infrastructure
- **Duration:** 30 minutes
- **Actions:** Deploy PVC, update Tdarr, deploy FileBot
- **Wait time:** 5-10 minutes for PVC binding

### Phase 2: Transfer Files
- **Duration:** Hours to days
- **Factors:** Network speed, total data size
- **Estimate:** 
  - 1TB @ 100Mbps = ~24 hours
  - 1TB @ 1Gbps = ~2.5 hours

### Phase 3: Sort Files
- **Duration:** 30 minutes - 2 hours
- **Factors:** Number of mixed files
- **FileBot speed:** ~100-500 files/minute

### Phase 4: Test Transcode
- **Duration:** 30 minutes - 2 hours
- **One episode:** 
  - H.264 → H.265: 30-90 mins
  - Already H.265: Seconds

### Phase 5-7: Full Transcode
- **Duration:** 1-4 weeks ⚠️
- **CPU only:** 0.5-2x realtime
- **Example:**
  - 100 movies × 2 hours each = 200 hours content
  - @ 1x realtime = 200 hours processing
  - With 4 workers = 50 hours = 2+ days
  - Actual: Allow 1-4 weeks for interruptions

### Phase 8: Cleanup
- **Duration:** 30 minutes
- **Timing:** After 1-2 week verification period

**Total Migration Time:** 2-4 weeks from start to finish

---

## Pre-Deployment Checklist

Before running Phase 1, verify:

- [ ] SSH access from cluster to media server (192.168.1.100)
- [ ] `emc-ssh-key` secret exists in `media` namespace
- [ ] Ceph has 20Ti+ available storage
- [ ] Tdarr is deployed and running
- [ ] `media-library` PVC exists and is bound
- [ ] Network bandwidth is acceptable for multi-TB transfer
- [ ] Media server has files at expected paths

**Verification Commands:**
```bash
kubectl get secret -n media emc-ssh-key
kubectl get pvc -n media media-library
kubectl get deployment -n media tdarr tdarr-node
```

---

## Deployment Steps

### Step 1: Deploy Infrastructure
```bash
cd /Users/emcniece/code/homelab

# Deploy staging PVC
kubectl apply -f homelab/apps/migration/media-staging-pvc.yaml

# Update Tdarr
kubectl apply -f homelab/apps/tdarr/deployment.yaml

# Deploy FileBot
kubectl apply -f homelab/apps/migration/filebot-pod.yaml
```

### Step 2: Start Transfer
```bash
kubectl apply -f homelab/apps/migration/staging-transfer-job.yaml
kubectl logs -n media job/staging-transfer -f
```

### Step 3+: Follow Checklist
See `DEPLOYMENT-CHECKLIST.md` for detailed step-by-step instructions.

---

## Success Criteria

### Phase Completion Markers

✅ **Phase 1 Complete:**
- PVC `media-staging` is Bound
- Tdarr pods restarted successfully
- FileBot pod is Running
- `/staging` mount accessible in Tdarr

✅ **Phase 2 Complete:**
- Transfer job status shows Complete (1/1)
- Files visible in `/staging/tv`, `/staging/movies`
- Music visible in `/media/music`
- No rsync errors in logs

✅ **Phase 3 Complete:**
- Mixed files sorted into proper directories
- No files remain in `/staging/unsorted`
- FileBot log shows successful matches

✅ **Phase 4 Complete:**
- Test file transcoded to H.265
- Plays smoothly on TCL TV
- Direct play (no Plex transcoding)
- Quality acceptable

✅ **Phase 5-7 Complete:**
- All files processed by Tdarr
- Staging directories empty
- Content visible in Plex
- Sonarr/Radarr imported files

✅ **Phase 8 Complete:**
- Staging PVC deleted
- FileBot pod deleted
- Transfer job deleted
- Tdarr deployment updated (staging mounts removed)

---

## Support & Documentation

### Quick Access

- **Deployment Checklist:** `apps/migration/DEPLOYMENT-CHECKLIST.md`
- **Quick Guide:** `apps/migration/README.md`
- **Full Plan:** `docs/large-media-migration.plan.md`
- **Architecture:** `docs/media-architecture-diagram.md`

### Key URLs

- Tdarr: https://tdarr.lab.emc2.build
- Plex: https://plex.lab.emc2.build
- Sonarr: https://sonarr.lab.emc2.build
- Radarr: https://radarr.lab.emc2.build
- Lidarr: https://lidarr.lab.emc2.build

### Common Commands

```bash
# Monitor transfer
kubectl logs -n media job/staging-transfer -f

# Check volumes
kubectl exec -n media -c tdarr deployment/tdarr -- \
  sh -c 'du -sh /staging/* /media/*'

# Access FileBot
kubectl exec -n media -it filebot-sorter -- /bin/sh

# View Tdarr logs
kubectl logs -n media deployment/tdarr -c tdarr -f

# Restart Tdarr
kubectl rollout restart deployment/tdarr -n media
```

---

## Notes & Warnings

⚠️ **CPU Transcoding is Slow**
- No GPU available means ~0.5-2x realtime encoding
- preset=fast chosen to balance quality vs speed
- Full library will take 1-4 weeks to process

✅ **Safety Features**
- Originals stay on media server during migration
- Staging volume preserves source files during transcode
- Triple redundancy during migration period
- Can restart/re-run any phase if issues occur

📺 **TCL TV Compatibility**
- Settings optimized for TCL 65R613-CA
- H.265/HEVC with 10-bit color support
- AC3 5.1 audio preserved
- MKV container for multi-track support
- Should direct play without Plex transcoding

🎯 **Next Action**
Follow the step-by-step guide in `DEPLOYMENT-CHECKLIST.md` to begin Phase 1.

---

**Implementation Status:** ✅ READY TO DEPLOY  
**Created By:** Cursor AI Assistant  
**Date:** October 16, 2025
