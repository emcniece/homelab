# Media Migration Deployment Checklist

## Pre-Flight Checks

- [ ] Verify SSH access to media server (192.168.1.100) from cluster
- [ ] Confirm `emc-ssh-key` secret exists in `media` namespace
- [ ] Verify Ceph storage cluster has 20Ti+ available
- [ ] Confirm Tdarr is deployed and running
- [ ] Check media-library PVC exists and is bound

```bash
# Verify SSH key secret
kubectl get secret -n media emc-ssh-key

# Check available Ceph storage
kubectl get pvc -n media

# Verify Tdarr is running
kubectl get deployment -n media tdarr tdarr-node
```

## Phase 1: Deploy Infrastructure (30 mins)

### Step 1.1: Deploy Staging PVC
```bash
kubectl apply -f homelab/apps/migration/media-staging-pvc.yaml
```

**Wait for binding:**
```bash
kubectl get pvc -n media media-staging -w
# Press Ctrl+C when STATUS shows "Bound"
```

### Step 1.2: Update Tdarr with Staging Mount
```bash
kubectl apply -f homelab/apps/tdarr/deployment.yaml
```

**Wait for rollout:**
```bash
kubectl rollout status deployment/tdarr -n media
kubectl rollout status deployment/tdarr-node -n media
```

**Verify staging mount:**
```bash
kubectl exec -n media deployment/tdarr -c tdarr -- ls -la /staging
# Should show empty directory
```

### Step 1.3: Deploy FileBot Pod
```bash
kubectl apply -f homelab/apps/migration/filebot-pod.yaml
```

**Wait for ready:**
```bash
kubectl get pod -n media filebot-sorter -w
# Press Ctrl+C when STATUS shows "Running"
```

**Verify FileBot:**
```bash
kubectl exec -n media filebot-sorter -- filebot --version
```

✅ **Phase 1 Complete**: Infrastructure ready

---

## Phase 2: Transfer Files (Hours to Days)

### Step 2.1: Start Transfer Job
```bash
kubectl apply -f homelab/apps/migration/staging-transfer-job.yaml
```

### Step 2.2: Monitor Progress
```bash
# Watch logs (real-time)
kubectl logs -n media job/staging-transfer -f

# Check job status
kubectl get job -n media staging-transfer

# Check volume usage (in another terminal)
kubectl exec -n media filebot-sorter -- du -sh /staging/* /media/music
```

**Completion Indicators:**
- Job STATUS shows "Complete" (1/1)
- Logs show "=== Transfer Complete ==="
- File sizes match expectations

✅ **Phase 2 Complete**: Files transferred to staging

---

## Phase 3: Sort Mixed Files (30 mins - 2 hours)

### Step 3.1: Check What Needs Sorting
```bash
kubectl exec -n media filebot-sorter -- ls -lh /staging/unsorted/
```

If empty, skip to Phase 4.

### Step 3.2: Run FileBot
```bash
kubectl exec -n media -it filebot-sorter -- /bin/sh
```

**Inside the pod:**
```bash
filebot -rename /staging/unsorted \
  --output /staging \
  --db TheMovieDB \
  --db TheTVDB \
  --format "{plex.replaceAll(/[\s.]/, '_').replaceAll(/[^a-zA-Z0-9_\-\/()]/, '')}" \
  --action move \
  -non-strict \
  --log-file /staging/filebot-sort.log

# Exit pod
exit
```

### Step 3.3: Merge FileBot Output
```bash
# Merge TV Shows
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/TV Shows" ]; then rsync -av "/staging/TV Shows/" /staging/tv/ && rm -rf "/staging/TV Shows"; fi'

# Merge Movies
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/Movies" ]; then rsync -av /staging/Movies/ /staging/movies/ && rm -rf /staging/Movies; fi'
```

### Step 3.4: Verify Structure
```bash
kubectl exec -n media filebot-sorter -- du -sh /staging/tv /staging/movies
kubectl exec -n media filebot-sorter -- ls /staging/
# Should only show: tv, movies (no unsorted, TV Shows, or Movies)
```

✅ **Phase 3 Complete**: Files organized

---

## Phase 4: Test Transcode (1-3 hours)

### Step 4.1: Create Test Setup
```bash
# Find a test file
kubectl exec -n media filebot-sorter -- \
  sh -c 'find /staging/tv -type f \( -name "*.mkv" -o -name "*.mp4" \) | head -1'

# Create test directories
kubectl exec -n media filebot-sorter -- mkdir -p /staging/test-input /media/test-output

# Copy test file (replace path with actual file from find command)
kubectl exec -n media filebot-sorter -- \
  cp "/staging/tv/ACTUAL_PATH_HERE.mkv" /staging/test-input/
```

### Step 4.2: Configure Tdarr Test Library

Open `https://tdarr.lab.emc2.build`

1. **Add Library:**
   - Name: `Test Transcode`
   - Source: `/staging/test-input`
   - Transcode cache: `/temp`
   - Output: `/media/test-output`
   - Folder watch: OFF
   - Schedule: OFF

2. **Configure Flow:**
   - Add plugin: "Migz-Check Video Codec"
     - Accept: H.265, HEVC
   - Add plugin: "Migz-Transcode Using CPU & FFMPEG"
     - FFmpeg args: `-c:v libx265 -crf 22 -preset fast -pix_fmt yuv420p10le -c:a copy -c:s copy`
   - Add plugin: "Classic-Replace Original File"

3. **Start Test:**
   - Click "Scan"
   - Verify 1 file found
   - Click "Start"

### Step 4.3: Monitor Test
```bash
kubectl logs -n media deployment/tdarr -c tdarr -f
```

Wait for completion (30 mins - 2 hours)

### Step 4.4: Verify Test Output
```bash
# Check output file exists
kubectl exec -n media filebot-sorter -- ls -lh /media/test-output/

# Check codec
kubectl exec -n media deployment/plex -- \
  ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name \
  -of default=noprint_wrappers=1 \
  /media/test-output/*.mkv
# Should output: codec_name=hevc
```

### Step 4.5: Test on TCL TV

1. Add test library in Plex (Settings → Libraries → Add)
   - Type: TV Shows
   - Folder: `/media/test-output`

2. Play on TCL TV and verify:
   - ✅ Direct play (not transcoding)
   - ✅ Smooth playback
   - ✅ Good quality
   - ✅ Proper audio

### Step 4.6: Cleanup Test
```bash
# If successful, move file to library
kubectl exec -n media filebot-sorter -- \
  mv /media/test-output/*.mkv /staging/tv/CORRECT_PATH/

# Remove test directories
kubectl exec -n media filebot-sorter -- rm -rf /staging/test-input /media/test-output

# Remove test library from Tdarr and Plex
```

✅ **Phase 4 Complete**: Transcode settings validated

---

## Phase 5: Full Library Transcode (1-4 Weeks)

### Step 5.1: Configure Tdarr Libraries

In Tdarr UI:

**TV Shows Library:**
- Name: `TV Shows`
- Source: `/staging/tv`
- Output: `/media/tv`
- Cache: `/temp`
- Folder watch: ON
- Schedule: ON
- Use same flow as test

**Movies Library:**
- Name: `Movies`
- Source: `/staging/movies`
- Output: `/media/movies`
- Cache: `/temp`
- Folder watch: ON
- Schedule: ON
- Use same flow as test

### Step 5.2: Start Processing
1. Click "Scan" on both libraries
2. Review file counts
3. Click "Start" on both libraries

### Step 5.3: Monitor
```bash
# Check progress
kubectl exec -n media -c tdarr deployment/tdarr -- \
  sh -c 'echo "=== Staging ==="; du -sh /staging/*; echo "=== Media ==="; du -sh /media/*'

# Watch logs
kubectl logs -n media deployment/tdarr -c tdarr -f
```

✅ **Phase 5 Started**: Transcoding in progress

---

## Phase 6: Configure Media Apps

### Step 6.1: Plex
Open `https://plex.lab.emc2.build`

1. Settings → Libraries → Add Library
   - TV Shows → `/media/tv`
   - Movies → `/media/movies`
   - Music → `/media/music`

2. Settings → Library
   - ✅ Scan library automatically
   - ✅ Run partial scan when changes detected

### Step 6.2: Sonarr
Open `https://sonarr.lab.emc2.build`

- Settings → Media Management → Root Folders → Add `/media/tv`
- Series → Library Import → Import Existing

### Step 6.3: Radarr
Open `https://radarr.lab.emc2.build`

- Settings → Media Management → Root Folders → Add `/media/movies`
- Movies → Library Import → Import Existing

### Step 6.4: Lidarr
Open `https://lidarr.lab.emc2.build`

- Settings → Media Management → Root Folders → Add `/media/music`
- Import Library

✅ **Phase 6 Complete**: Media apps configured

---

## Phase 7: Monitor & Wait (1-4 Weeks)

### Daily Checks
```bash
# Staging should decrease
kubectl exec -n media -c tdarr deployment/tdarr -- du -sh /staging/tv /staging/movies

# Media should increase
kubectl exec -n media -c tdarr deployment/tdarr -- du -sh /media/tv /media/movies
```

### In Tdarr Dashboard:
- Watch queue size decrease
- Monitor space saved
- Check for errors

### Test Playback:
- Browse new content in Plex as it appears
- Spot check quality
- Verify direct play on TCL TV

✅ **Phase 7 In Progress**: Watching transcoding

---

## Phase 8: Cleanup (After Full Verification)

⚠️ **WAIT 1-2 WEEKS AFTER TRANSCODING COMPLETES**

### Verification Checklist
- [ ] Tdarr shows 0 files in queue
- [ ] `/staging/tv` is empty
- [ ] `/staging/movies` is empty
- [ ] All content visible in Plex
- [ ] Spot checks pass quality test
- [ ] File counts match expectations
- [ ] No transcoding errors in Tdarr

### Step 8.1: Delete Resources
```bash
# Delete FileBot pod
kubectl delete pod -n media filebot-sorter

# Delete transfer job
kubectl delete job -n media staging-transfer

# Delete staging PVC (IRREVERSIBLE!)
kubectl delete pvc -n media media-staging
```

### Step 8.2: Update Tdarr Deployment
Remove staging mounts from `homelab/apps/tdarr/deployment.yaml`, then:
```bash
kubectl apply -f homelab/apps/tdarr/deployment.yaml
```

✅ **Phase 8 Complete**: Migration finished, cleanup done

---

## Troubleshooting

### Transfer Job Fails
```bash
# Check logs
kubectl logs -n media job/staging-transfer

# Check SSH connectivity
kubectl exec -n media -it filebot-sorter -- \
  ssh -o StrictHostKeyChecking=no emcniece@192.168.1.100 "echo 'Connection OK'"

# Restart job
kubectl delete job -n media staging-transfer
kubectl apply -f homelab/apps/migration/staging-transfer-job.yaml
```

### FileBot Issues
```bash
# Check FileBot logs
kubectl exec -n media filebot-sorter -- cat /staging/filebot-sort.log

# List unmatched files
kubectl exec -n media filebot-sorter -- ls /staging/unsorted/
```

### Tdarr Not Processing
```bash
# Check worker nodes
kubectl get pods -n media -l app=tdarr-node

# Restart Tdarr
kubectl rollout restart deployment/tdarr -n media
kubectl rollout restart deployment/tdarr-node -n media

# Check logs for errors
kubectl logs -n media deployment/tdarr -c tdarr --tail=100
```

### Out of Space
```bash
# Check PVC usage
kubectl exec -n media -c tdarr deployment/tdarr -- df -h /staging /media

# Expand PVC if needed (edit and apply)
kubectl edit pvc -n media media-staging
```

---

## Quick Reference Commands

```bash
# Check all migration resources
kubectl get pvc,pod,job -n media | grep -E "staging|filebot"

# Monitor volumes
watch -n 60 'kubectl exec -n media -c tdarr deployment/tdarr -- du -sh /staging/* /media/*'

# Access FileBot interactively
kubectl exec -n media -it filebot-sorter -- /bin/sh

# View Tdarr logs
kubectl logs -n media deployment/tdarr -c tdarr -f

# Check Tdarr processing stats (in UI)
# https://tdarr.lab.emc2.build
```

---

**Documentation:**
- Full Plan: `docs/large-media-migration.plan.md`
- Quick Guide: `apps/migration/README.md`
- Implementation Summary: `docs/media-migration-implementation-summary.md`

