# Large Media Migration - Implementation Summary

## What Was Created

The following files have been created to implement the large media migration plan:

### 1. Infrastructure Files

**`apps/migration/media-staging-pvc.yaml`**
- 20Ti CephFS staging volume
- Temporary storage for source files during transcoding
- Will be deleted after verification

**`apps/migration/filebot-pod.yaml`**
- Pod running FileBot for file organization
- Sorts mixed TV/movie files
- Sanitizes filenames (removes spaces, special chars)

**`apps/migration/staging-transfer-job.yaml`**
- Kubernetes Job to rsync files from media server
- Uses `instrumentisto/rsync-ssh` image with SSH key authentication
- Transfers organized TV, movies, mixed files, and music
- Estimated runtime: hours to days depending on data size

### 2. Updated Files

**`apps/tdarr/deployment.yaml`**
- Added `/staging` volume mount to both tdarr and tdarr-node containers
- Mounted `media-staging` PVC for access to source files

### 3. Documentation

**`apps/migration/README.md`**
- Quick start guide
- Step-by-step commands for each phase
- Common troubleshooting commands

**`docs/large-media-migration.plan.md`** (from plan tool)
- Complete detailed migration plan
- Phase-by-phase instructions
- TCL 65R613-CA optimized Tdarr settings
- Risk mitigation and timeline estimates

## Migration Workflow

```
┌─────────────────┐
│  Media Server   │
│ 192.168.1.100   │
└────────┬────────┘
         │ rsync (staging-transfer-job)
         ↓
┌─────────────────┐
│ Staging Volume  │
│   /staging/     │
│  - tv/          │
│  - movies/      │
│  - unsorted/    │
└────────┬────────┘
         │ FileBot sorts
         ↓
┌─────────────────┐
│ Staging Volume  │
│  (organized)    │
└────────┬────────┘
         │ Tdarr transcodes (CPU, H.265)
         ↓
┌─────────────────┐
│ Media Library   │
│   /media/       │
│  - tv/          │
│  - movies/      │
│  - music/       │
└────────┬────────┘
         │ Media apps access
         ↓
┌─────────────────┐
│ Plex/Emby/etc   │
│ TCL 65R613-CA   │
└─────────────────┘
```

## Key Features

### Tdarr Configuration (TCL TV Optimized)
- **Video**: H.265/HEVC, CRF 22, preset=fast (CPU)
- **Audio**: Copy AC3/AAC/EAC3 (5.1 surround supported)
- **Subtitles**: Keep SRT/ASS
- **Container**: MKV (best for multi-track support)

### FileBot File Naming
- Replaces spaces and special characters
- Format: `ShowName_S01E01_Episode.mkv`
- Organized into proper TV/Movie directories

### Safety Features
1. Originals remain on media server during migration
2. Staging volume keeps source files during transcoding
3. Test transcode phase before full library processing
4. Gradual content availability (watch as files transcode)

## Next Steps

To begin the migration, follow the steps in `apps/migration/README.md`:

1. **Phase 1**: Deploy infrastructure (PVC, FileBot, updated Tdarr)
2. **Phase 2**: Run staging transfer job
3. **Phase 3**: Sort mixed files with FileBot
4. **Phase 4**: Test transcode single episode on TCL TV
5. **Phase 5**: Configure Tdarr for full library
6. **Phase 6**: Configure media apps (Plex, Sonarr, Radarr)
7. **Phase 7**: Monitor progress
8. **Phase 8**: Cleanup after verification

## Important Notes

### Timeline
- **Transfer**: Hours to days (network speed)
- **FileBot**: 30 mins - 2 hours
- **Test transcode**: 30 mins - 2 hours (one episode)
- **Full transcode**: **1-4 WEEKS** (CPU is slow, ~0.5-2x realtime)

### CPU Transcoding
With no GPU available, transcoding will be slow:
- H.264 → H.265: 1-4 hours per 2-hour movie
- Already H.265: Seconds (just moves to output)
- preset=fast recommended (2-3x faster than medium)

### Music
- Copied directly to `/media/music` (no transcoding)
- Available immediately after transfer completes

### Storage Requirements
- **Staging**: ~20Ti (same as source size)
- **Media-library**: Will decrease as H.265 compresses
- **Total temp**: 40Ti+ during migration

## Verification Checklist

Before deleting staging volume:
- [ ] All Tdarr transcode jobs completed
- [ ] Staging directories empty
- [ ] Content appears in Plex/Emby
- [ ] Test playback on TCL 65R613-CA works
- [ ] Direct play (not transcoding) confirmed
- [ ] File counts match source → staging → media-library
- [ ] Sample quality checks passed

## Commands Quick Reference

```bash
# Start migration
kubectl apply -f apps/migration/media-staging-pvc.yaml
kubectl apply -f apps/tdarr/deployment.yaml
kubectl apply -f apps/migration/filebot-pod.yaml
kubectl apply -f apps/migration/staging-transfer-job.yaml

# Monitor transfer
kubectl logs -n media job/staging-transfer -f

# FileBot sorting
kubectl exec -n media -it filebot-sorter -- /bin/sh

# Check progress
kubectl exec -n media -c tdarr deployment/tdarr -- \
  sh -c 'du -sh /staging/* /media/*'

# Cleanup (after verification)
kubectl delete pod -n media filebot-sorter
kubectl delete job -n media staging-transfer
kubectl delete pvc -n media media-staging
```

## Support Documents

- **Full Plan**: `docs/large-media-migration.plan.md`
- **Quick Guide**: `apps/migration/README.md`
- **Architecture**: `docs/media-architecture-diagram.md`
- **Main Migration Plan**: `docs/media-cluster-migration.plan.md`

---

**Status**: Implementation complete, ready to deploy
**Created**: October 16, 2025
**Estimated Completion**: 2-4 weeks after deployment

