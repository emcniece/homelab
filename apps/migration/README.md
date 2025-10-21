# Large Media Migration

This directory contains manifests for migrating multi-TB media library from the media server to the homelab cluster with Tdarr transcoding.

## Overview

**Workflow**: Media Server → Staging Volume → Tdarr Transcode → Media Library → Media Apps

**Files created:**
- `media-staging-pvc.yaml` - 20Ti temporary staging volume
- `filebot-pod.yaml` - Pod for sorting mixed files
- `staging-transfer-job.yaml` - rsync job to copy files to staging
- Updated `../tdarr/deployment.yaml` - Added staging volume mount

## Quick Start

### Phase 1: Deploy Infrastructure

```bash
# 1. Deploy staging PVC
kubectl apply -f media-staging-pvc.yaml

# 2. Wait for PVC to bind
kubectl get pvc -n media media-staging -w

# 3. Update Tdarr with staging mounts
kubectl apply -f ../tdarr/deployment.yaml
kubectl rollout status deployment/tdarr -n media
kubectl rollout status deployment/tdarr-node -n media

# 4. Deploy FileBot pod
kubectl apply -f filebot-pod.yaml
kubectl get pod -n media filebot-sorter -w
```

### Phase 2: Transfer Files

```bash
# 1. Start the transfer job
kubectl apply -f staging-transfer-job.yaml

# 2. Monitor progress (will take hours/days)
kubectl logs -n media job/staging-transfer -f

# 3. Check transfer status
kubectl get job -n media staging-transfer
```

### Phase 3: Sort Mixed Files

```bash
# 1. Exec into FileBot pod
kubectl exec -n media -it filebot-sorter -- /bin/sh

# 2. Run FileBot (inside pod)
filebot -rename /staging/unsorted \
  --output /staging \
  --db TheMovieDB \
  --db TheTVDB \
  --format "{plex.replaceAll(/[\s.]/, '_').replaceAll(/[^a-zA-Z0-9_\-\/()]/, '')}" \
  --action move \
  -non-strict \
  --log-file /staging/filebot-sort.log

# 3. Exit pod
exit

# 4. Merge FileBot output
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/TV Shows" ]; then rsync -av "/staging/TV Shows/" /staging/tv/ && rm -rf "/staging/TV Shows"; fi'

kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/Movies" ]; then rsync -av /staging/Movies/ /staging/movies/ && rm -rf /staging/Movies; fi'

# 5. Verify structure
kubectl exec -n media filebot-sorter -- du -sh /staging/tv /staging/movies
```

### Phase 4: Test Transcode (Single Episode)

```bash
# 1. Find a test file
kubectl exec -n media filebot-sorter -- \
  sh -c 'find /staging/tv -type f \( -name "*.mkv" -o -name "*.mp4" \) | head -1'

# 2. Create test directories
kubectl exec -n media filebot-sorter -- mkdir -p /staging/test-input /media/test-output

# 3. Copy one episode (replace with actual path)
kubectl exec -n media filebot-sorter -- \
  cp "/staging/tv/ShowName/Season_01/episode.mkv" /staging/test-input/
```

**Then in Tdarr UI** (`https://tdarr.lab.emc2.build`):
1. Create library: Test Transcode
   - Source: `/staging/test-input`
   - Output: `/media/test-output`
2. Configure flow with H.265 CPU transcode
3. Scan and start
4. Test playback in Plex on your TCL TV

### Phase 5: Full Library Transcode

**In Tdarr UI**:
1. Create TV Shows library: `/staging/tv` → `/media/tv`
2. Create Movies library: `/staging/movies` → `/media/movies`
3. Configure transcode flow (CPU, preset=fast, CRF=22)
4. Scan and start processing

### Phase 6: Configure Media Apps

**Plex** (`https://plex.lab.emc2.build`):
- Add libraries: `/media/tv`, `/media/movies`, `/media/music`

**Sonarr/Radarr/Lidarr**:
- Add root folders pointing to `/media/{tv,movies,music}`
- Import existing media

### Phase 7: Monitor Progress

```bash
# Watch staging decrease
kubectl exec -n media -c tdarr deployment/tdarr -- du -sh /staging/tv /staging/movies

# Watch media-library increase
kubectl exec -n media -c tdarr deployment/tdarr -- du -sh /media/tv /media/movies

# Monitor Tdarr logs
kubectl logs -n media deployment/tdarr -c tdarr -f
kubectl logs -n media deployment/tdarr-node -f
```

### Phase 8: Cleanup (After Verification)

**Wait 1-2 weeks, then verify:**
- [ ] All files transcoded
- [ ] Staging is empty
- [ ] Content plays in Plex
- [ ] Quality is good

```bash
# Delete resources
kubectl delete pod -n media filebot-sorter
kubectl delete job -n media staging-transfer
kubectl delete pvc -n media media-staging

# Remove staging from Tdarr deployment
# Edit ../tdarr/deployment.yaml to remove staging mounts
kubectl apply -f ../tdarr/deployment.yaml
```

## Key Commands

```bash
# Check staging transfer progress
kubectl logs -n media job/staging-transfer -f

# Access FileBot
kubectl exec -n media -it filebot-sorter -- /bin/sh

# Check volumes
kubectl exec -n media -c tdarr deployment/tdarr -- \
  sh -c 'echo "Staging:"; du -sh /staging/*; echo "Media:"; du -sh /media/*'

# Restart Tdarr
kubectl rollout restart deployment/tdarr -n media
kubectl rollout restart deployment/tdarr-node -n media
```

## Tdarr Configuration

**TCL 65R613-CA Optimized Settings:**

FFmpeg arguments:
```
-c:v libx265 -crf 22 -preset fast -pix_fmt yuv420p10le -c:a copy -c:s copy
```

**Flow:**
1. Check Video Codec (accept H.265)
2. Transcode to H.265 (CPU, preset=fast)
3. Check Audio Codec (accept AAC, AC3, EAC3)
4. Keep subtitles
5. Ensure MKV container
6. Move to output

## Timeline

- **Setup**: 30 mins
- **Transfer**: Hours to days (network speed dependent)
- **Sorting**: 30 mins - 2 hours
- **Test transcode**: 30 mins - 2 hours (one episode)
- **Full transcode**: 1-4 weeks (CPU transcoding is slow)
- **Cleanup**: After 1-2 week verification period

## Notes

- Music goes directly to `/media/music` (no transcoding)
- Originals stay on media server as backup
- Content available as Tdarr processes it
- CPU transcoding: ~0.5-2x realtime for H.264→H.265
- Preset `fast` recommended for reasonable CPU transcode times

For full details, see `../docs/large-media-migration.plan.md`

