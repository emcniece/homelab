# Large Volume Media Migration Plan

## Overview

Copy source media to staging volume, sort mixed files with FileBot, then Tdarr transcodes all files to media-library. Media apps (Plex, Emby, Sonarr, Radarr, Lidarr) only access transcoded files in media-library - content becomes available as transcoding progresses.

## Current Source Locations

**Media Server** (`192.168.1.100`):

- `/mnt/zpool1/apps/media-test/download/complete/` - mixed TV/movies (needs sorting with FileBot)
- `/mnt/zpool1/apps/media-test/download/complete/tv` - organized TV shows
- `/mnt/zpool1/apps/media-test/download/complete/movies` - organized movies
- `/mnt/zpool1/apps/media-test/data/music` - music (copy directly, no transcoding)

**Empty directories (skip):**

- `/mnt/zpool1/apps/media-test/data/{tv,movies,anime}`
- `/mnt/zpool1/apps/media-test/download/complete/anime`

## Target Locations

**Staging** (media-staging PVC, ~20Ti, temporary):

- `/staging/tv` - Source TV shows for Tdarr input
- `/staging/movies` - Source movies for Tdarr input
- `/staging/unsorted` - Mixed files to be sorted by FileBot

**Final** (media-library PVC, 20Ti):

- `/media/tv` - Transcoded TV shows (media apps access here)
- `/media/movies` - Transcoded movies (media apps access here)
- `/media/music` - Music copied directly (no transcoding)

## Migration Strategy

### Staging-Based Workflow

1. **Copy to staging**: Transfer all source files to staging volume
2. **Sort with FileBot**: Organize mixed files in staging
3. **Tdarr transcodes**: staging → media-library (in background)
4. **Media apps see results**: Content appears gradually as transcoding completes
5. **Delete staging**: After transcoding completes and verification

### Benefits

- **Clean separation**: Source files separate from transcoded files
- **Media apps only see quality content**: No access to untranscoded originals
- **Gradual availability**: Content appears as Tdarr processes it
- **Safe**: Originals on media server + staging until verified
- **No wasted bandwidth**: Copy once, transcode in cluster

### Why Not Direct to media-library?

- Media apps would see untranscoded files immediately (not desired)
- Tdarr would transcode in-place, causing temporary file duplication
- Harder to track which files are transcoded vs original
- Staging keeps clear separation: untranscoded (staging) vs transcoded (media-library)

## Phase 1: Setup Infrastructure

### 1.1 Create Staging Volume

Create `homelab/apps/migration/media-staging-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-staging
  namespace: media
spec:
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Ti
  storageClassName: csi-cephfs-sc
```

### 1.2 Update Tdarr Deployment

Add staging volume to `homelab/apps/tdarr/deployment.yaml`:

In both `tdarr` and `tdarr-node` containers, add:

```yaml
volumeMounts:
 - mountPath: /staging
    name: media-staging

volumes:
 - name: media-staging
    persistentVolumeClaim:
      claimName: media-staging
```

### 1.3 Create FileBot Pod

Create `homelab/apps/migration/filebot-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: filebot-sorter
  namespace: media
spec:
  containers:
 - name: filebot
    image: jlesage/filebot:latest
    env:
  - name: USER_ID
      value: "1000"
  - name: GROUP_ID
      value: "1000"
  - name: TZ
      value: "America/Vancouver"
    volumeMounts:
  - mountPath: /staging
      name: media-staging
  volumes:
 - name: media-staging
    persistentVolumeClaim:
      claimName: media-staging
  restartPolicy: Never
```

### 1.4 Deploy Infrastructure

```bash
# Deploy staging PVC
kubectl apply -f homelab/apps/migration/media-staging-pvc.yaml

# Wait for PVC to bind
kubectl get pvc -n media media-staging -w

# Update and redeploy Tdarr (if already deployed)
kubectl apply -f homelab/apps/tdarr/deployment.yaml
kubectl rollout status deployment/tdarr -n media
kubectl rollout status deployment/tdarr-node -n media

# Deploy FileBot pod
kubectl apply -f homelab/apps/migration/filebot-pod.yaml
```

## Phase 2: Transfer Files to Staging

### 2.1 Create Staging Transfer Job

Create `homelab/apps/migration/staging-transfer-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: staging-transfer
  namespace: media
spec:
  template:
    spec:
      containers:
   - name: rsync-transfer
        image: instrumentisto/rsync-ssh
        command: ["/bin/sh", "-c"]
        args:
    - |
          echo "=== Staging Transfer Started ==="
          
          # Set up SSH key
          echo "Setting up SSH key..."
          mkdir -p /root/.ssh
          cp /ssh-key/emc_sshkey.pem /root/.ssh/id_rsa
          chmod 600 /root/.ssh/id_rsa
          
          # Add media server to known hosts
          ssh-keyscan -H 192.168.1.100 >> /root/.ssh/known_hosts
          
          # Test SSH connection
          echo "Testing SSH connection..."
          ssh -o StrictHostKeyChecking=no emcniece@192.168.1.100 "echo 'SSH connection successful'"
          
          echo "Creating directory structure..."
          mkdir -p /staging/tv
          mkdir -p /staging/movies
          mkdir -p /staging/unsorted
          mkdir -p /media/music
          
          echo ""
          echo "=== Step 1: Transfer organized TV shows to staging ==="
          rsync -av --partial --timeout=300 \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60" \
            emcniece@192.168.1.100:/mnt/zpool1/apps/media-test/download/complete/tv/ \
            /staging/tv/
          
          echo ""
          echo "=== Step 2: Transfer organized movies to staging ==="
          rsync -av --partial --timeout=300 \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60" \
            emcniece@192.168.1.100:/mnt/zpool1/apps/media-test/download/complete/movies/ \
            /staging/movies/
          
          echo ""
          echo "=== Step 3: Transfer mixed files to staging/unsorted ==="
          # Copy only video files from root of complete directory
          rsync -av --partial --timeout=300 \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60" \
            --include='*.mkv' --include='*.mp4' --include='*.avi' \
            --include='*.m4v' --include='*.mov' --include='*.wmv' \
            --exclude='*' \
            emcniece@192.168.1.100:/mnt/zpool1/apps/media-test/download/complete/ \
            /staging/unsorted/
          
          echo ""
          echo "=== Step 4: Transfer music directly to media-library (no transcoding) ==="
          rsync -av --partial --timeout=300 \
            -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60" \
            emcniece@192.168.1.100:/mnt/zpool1/apps/media-test/data/music/ \
            /media/music/
          
          echo ""
          echo "=== Transfer Summary ==="
          echo "Staging TV shows:"
          du -sh /staging/tv
          echo "Staging Movies:"
          du -sh /staging/movies
          echo "Staging Unsorted (needs FileBot):"
          du -sh /staging/unsorted
          echo "Final Music (no transcoding):"
          du -sh /media/music
          echo ""
          echo "Total staging usage:"
          du -sh /staging
          
          echo ""
          echo "=== Transfer Complete ==="
          echo "Next steps:"
          echo "1. Run FileBot to sort /staging/unsorted"
          echo "2. Configure Tdarr to transcode staging → media-library"
        volumeMounts:
    - name: media-staging
          mountPath: /staging
    - name: media-library
          mountPath: /media
    - name: ssh-key
          mountPath: /ssh-key
          readOnly: true
      volumes:
   - name: media-staging
        persistentVolumeClaim:
          claimName: media-staging
   - name: media-library
        persistentVolumeClaim:
          claimName: media-library
   - name: ssh-key
        secret:
          secretName: emc-ssh-key
      restartPolicy: Never
  backoffLimit: 3
```

### 2.2 Run Transfer Job

```bash
# Deploy the transfer job
kubectl apply -f homelab/apps/migration/staging-transfer-job.yaml

# Monitor progress
kubectl logs -n media job/staging-transfer -f

# Check status
kubectl get job -n media staging-transfer
```

**Expected duration**: Hours to days depending on network speed and total data size.

## Phase 3: Sort Mixed Files with FileBot

### 3.1 Run FileBot Sorting

Once transfer completes, sort the mixed files:

```bash
# Exec into FileBot pod
kubectl exec -n media -it filebot-sorter -- /bin/sh

# Inside the pod, run FileBot with custom format (removes spaces, special chars)
filebot -rename /staging/unsorted \
  --output /staging \
  --db TheMovieDB \
  --db TheTVDB \
  --format "{plex.replaceAll(/[\s.]/, '_').replaceAll(/[^a-zA-Z0-9_\-\/()]/, '')}" \
  --action move \
  -non-strict \
  --log-file /staging/filebot-sort.log

# Alternative: Replace spaces with dots (common for torrents)
# --format "{plex.space('.')}"

# Alternative: Replace spaces with underscores
# --format "{plex.space('_')}"

# This will organize files with sanitized names like:
# /staging/TV_Shows/ShowName/Season_01/ShowName_S01E01_Episode.mkv
# /staging/Movies/MovieName_(2023)/MovieName_(2023).mkv
```

### 3.2 Review FileBot Output

```bash
# Check the log for errors or unmatched files
kubectl exec -n media filebot-sorter -- cat /staging/filebot-sort.log

# List any remaining unsorted files
kubectl exec -n media filebot-sorter -- ls -lh /staging/unsorted

# Check what FileBot created
kubectl exec -n media filebot-sorter -- ls -lh /staging/
```

### 3.3 Merge FileBot Output

FileBot creates `TV Shows` and `Movies` directories. Merge with existing:

```bash
# Merge FileBot's TV Shows into /staging/tv
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/TV Shows" ]; then rsync -av "/staging/TV Shows/" /staging/tv/ && rm -rf "/staging/TV Shows"; fi'

# Merge FileBot's Movies into /staging/movies
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/Movies" ]; then rsync -av /staging/Movies/ /staging/movies/ && rm -rf /staging/Movies; fi'

# Remove unsorted directory if empty
kubectl exec -n media filebot-sorter -- \
  sh -c 'if [ -d "/staging/unsorted" ] && [ -z "$(ls -A /staging/unsorted)" ]; then rmdir /staging/unsorted; fi'
```

### 3.4 Verify Staging Structure

```bash
# Final staging structure should be:
kubectl exec -n media filebot-sorter -- du -sh /staging/tv /staging/movies

# TV and movies should now contain all organized content
```

## Phase 4: Test Transcode (Single Episode)

### 4.1 Create Test Directory

Before transcoding the entire library, test with a single episode:

```bash
# Pick a single TV episode for testing
kubectl exec -n media filebot-sorter -- \
  sh -c 'find /staging/tv -type f -name "*.mkv" -o -name "*.mp4" | head -1'

# Create test directories
kubectl exec -n media filebot-sorter -- mkdir -p /staging/test-input
kubectl exec -n media filebot-sorter -- mkdir -p /media/test-output

# Copy one episode to test directory (replace with actual path from find command)
kubectl exec -n media filebot-sorter -- \
  cp "/staging/tv/ShowName/Season_01/ShowName_S01E01.mkv" /staging/test-input/
```

### 4.2 Access Tdarr and Create Test Library

Navigate to `https://tdarr.lab.emc2.build`

**Create Test Library:**
- Name: `Test Transcode`
- Source: `/staging/test-input`
- Transcode cache: `/temp`
- Output: `/media/test-output`
- Options:
  - ✓ Scan on start
  - ✓ Replace original

### 4.3 Configure Test Transcode Flow

Use the TCL 65R613-CA optimized settings:

**Flow plugins:**
1. Check Video Codec (accept H.265/HEVC)
2. Transcode to H.265 with FFmpeg arguments:
   ```
   -c:v libx265 -crf 22 -preset fast -pix_fmt yuv420p10le -c:a copy -c:s copy
   ```
3. Ensure MKV container

### 4.4 Run Test Transcode

1. Click **Scan** on the Test library
2. Verify it finds 1 file
3. Click **Start** to begin transcoding
4. Monitor progress (should take 30 mins - 2 hours for one episode)

**Monitor the test:**
```bash
# Watch Tdarr logs
kubectl logs -n media deployment/tdarr -c tdarr -f

# Check if file appears in output
kubectl exec -n media -c tdarr deployment/tdarr -- \
  ls -lh /media/test-output/
```

### 4.5 Verify Test Output

Once transcoding completes:

```bash
# Check the transcoded file codec
kubectl exec -n media deployment/plex -- \
  ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,bit_rate \
  -of default=noprint_wrappers=1 \
  /media/test-output/*.mkv

# Expected output:
# codec_name=hevc
# width=1920 (or 3840 for 4K)
# height=1080 (or 2160 for 4K)
```

### 4.6 Test Playback in Plex

1. Add test library in Plex:
   - Library name: `Test TV`
   - Folder: `/media/test-output`
   - Scan library

2. Browse to the test episode in Plex web UI

3. Play the episode and verify:
   - ✓ No buffering or stuttering
   - ✓ Video quality looks good
   - ✓ Audio plays correctly (including 5.1 if applicable)
   - ✓ Subtitles work (if present)
   - ✓ No artifacts or encoding issues

### 4.7 Test on TCL TV

**Critical step:** Play the test episode on your actual TCL 65R613-CA:

1. Open Plex app on the TV
2. Navigate to Test TV library
3. Play the episode
4. Verify:
   - Direct play (not transcoding) - check Plex dashboard
   - Smooth playback at full quality
   - Proper audio output
   - HDR displays correctly (if source was HDR)

### 4.8 Decision Point

**If test successful:**
- ✓ Video codec is HEVC
- ✓ Plays smoothly on TCL TV
- ✓ Quality is acceptable
- ✓ File size reduced appropriately

**Proceed to Phase 5** to configure full library transcoding.

**If test has issues:**
- Adjust CRF value (lower = better quality, higher = smaller files)
- Try different preset (veryfast, fast, medium)
- Check audio codec settings
- Re-run test with adjusted settings

### 4.9 Cleanup Test

Once satisfied with results:

```bash
# Remove test library from Tdarr
# Delete test library from Plex

# Move successful test file to actual library
kubectl exec -n media -c tdarr deployment/tdarr -- \
  mv /media/test-output/*.mkv /media/tv/ShowName/Season_01/

# Remove test directories
kubectl exec -n media -c tdarr deployment/tdarr -- \
  rm -rf /staging/test-input /media/test-output
```

## Phase 5: Configure Tdarr for Full Library Transcoding

### 5.1 Access Tdarr

Navigate to `https://tdarr.lab.emc2.build`

### 4.2 Create Libraries

**Library 1 - TV Shows:**
- Name: `TV Shows`
- Source: `/staging/tv`
- Transcode cache: `/temp`
- Output: `/media/tv`
- Options:
  - ✓ Scan on start
  - ✓ Replace original (will move from staging to media-library)
  - File watcher: Enabled

**Library 2 - Movies:**
- Name: `Movies`
- Source: `/staging/movies`
- Transcode cache: `/temp`
- Output: `/media/movies`
- Options: Same as above

### 4.3 Configure Transcode Flow - TCL 65R613-CA Optimized

Your TCL 65R613-CA (6-Series Roku TV) supports:

- Video: H.264, H.265/HEVC, 4K resolution
- Audio: AAC, AC3 (Dolby Digital), EAC3 (Dolby Digital Plus)
- HDR: HDR10
- Containers: MKV, MP4

**Recommended Tdarr Flow:**

**1. Check Video Codec**

- Plugin: `Migz-Check Video Codec`
- Accept: H.265, HEVC
- Action: Skip transcode if already H.265 (will still move to output)

**2. Transcode Video to H.265 (CPU)**

- Plugin: `Migz-Transcode Using CPU & FFMPEG`
- Video Codec: H.265/HEVC (libx265)
- CRF: 21-23 (balance quality vs encode time; lower = better quality but slower)
- Preset: **fast** or **medium** (recommended for CPU to keep reasonable encode times)
- Resolution: Keep original (don't downscale 4K)
- HDR: Preserve HDR10 metadata if present

**Custom FFmpeg arguments for TCL 6-Series (CPU transcoding):**

```
-c:v libx265 -crf 22 -preset fast -pix_fmt yuv420p10le -c:a copy -c:s copy
```

**Why preset=fast for CPU?**
- `fast`: 2-3x faster than `medium`, slight quality loss
- `medium`: Better quality but 2-3x slower (1-2 days per movie)
- `slow`: Best quality but 4-5x slower (not practical for large libraries)

For CPU transcoding with reasonable timelines, use `preset fast` or `veryfast`.

**3. Check Audio Codec**

- Plugin: `Migz-Check Audio Codec`
- Accept: AAC, AC3, EAC3
- Action: Keep if compatible, transcode if not
- Note: TCL supports 5.1 surround, so keep multi-channel audio

**4. Transcode Audio (if needed)**

- Plugin: `Migz-Transcode Audio`
- Codec: AC3 (Dolby Digital) for surround or AAC for stereo
- Bitrate: 
                                - 5.1 surround: 640 kbps (AC3)
                                - Stereo: 192-256 kbps (AAC)
- Keep original channel count (don't downmix 5.1 to stereo)

**5. Keep Subtitles**

- Plugin: `Migz-Check Subtitle Codec`
- Keep: SRT, ASS (soft subtitles)
- Action: Copy subtitle streams (TCL Roku supports them)

**6. Ensure MKV Container**

- Plugin: Ensure output is MKV format
- Note: TCL Roku supports MKV well, and it handles multiple audio/subtitle tracks better than MP4

**7. Move to Output**

- Ensure "Replace original" is enabled in library settings
- Files will move from `/staging/{tv,movies}` to `/media/{tv,movies}`

**Alternative: Quick Profile for Already-Good Files**

For files that just need minor adjustments:

```
-c:v copy -c:a copy -c:s copy
```

This just remuxes without transcoding (instant)

### 4.4 Start Transcoding

1. Click **Scan** on each library to discover all files
2. Review file count and estimated processing time
3. Click **Start** to begin transcoding
4. Adjust worker count if needed (Settings → Nodes → currently 2 nodes with 2 CPU workers each)

**Expected transcode time:**

- Already H.265 files: Skipped/moved (seconds per file)
- H.264 files: 0.5-2x realtime (a 2hr movie takes 1-4hrs)
- Other codecs: 0.3-1x realtime
- Total: Days to weeks for multi-TB library

### 4.5 Monitor Transcoding

Tdarr dashboard shows:

- Files queued (in `/staging`)
- Files processing (in `/temp`)
- Files completed (moved to `/media`)
- Space saved
- Estimated completion time

Leave Tdarr running continuously.

## Phase 5: Configure Media Apps (As Files Become Available)

### 5.1 Scan Libraries in Plex

Access Plex at `https://plex.lab.emc2.build`:

1. **Add/Update Libraries:**

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - TV Shows → `/media/tv`
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Movies → `/media/movies`
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Music → `/media/music`

2. **Enable automatic scanning:**

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Settings → Library → Scan my library automatically
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Settings → Library → Run a partial scan when changes are detected

3. **Initial scan:**

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                - Settings → Library → Scan Library Files

### 5.2 Configure Sonarr/Radarr/Lidarr

**Sonarr** (`https://sonarr.lab.emc2.build`):

- Settings → Media Management → Root Folders → Add `/media/tv`
- Series → Library Import → Import existing series (run periodically as Tdarr adds files)

**Radarr** (`https://radarr.lab.emc2.build`):

- Settings → Media Management → Root Folders → Add `/media/movies`
- Movies → Library Import → Import existing movies (run periodically)

**Lidarr** (`https://lidarr.lab.emc2.build`):

- Settings → Media Management → Root Folders → Add `/media/music`
- Import existing music library (available immediately)

### 5.3 Gradual Content Availability

As Tdarr transcodes files from staging → media-library:

- Plex will detect new files and add them to library
- Sonarr/Radarr can be re-scanned to import newly transcoded content
- Content becomes watchable as soon as Tdarr moves it to `/media`

## Phase 6: Monitor Progress

### 6.1 Track Transcoding Progress

```bash
# Check staging volume (should decrease as files are processed)
kubectl exec -n media -c tdarr deployment/tdarr -- \
  du -sh /staging/tv /staging/movies

# Check media-library volume (should increase as files are transcoded)
kubectl exec -n media -c tdarr deployment/tdarr -- \
  du -sh /media/tv /media/movies

# Check Tdarr server logs
kubectl logs -n media deployment/tdarr -c tdarr -f

# Check worker node logs
kubectl logs -n media deployment/tdarr-node -f
```

### 6.2 Spot Check Transcoded Files

Periodically verify transcode quality:

```bash
# Check a transcoded file's codec
kubectl exec -n media deployment/plex -- \
  ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,bit_rate \
  -of default=noprint_wrappers=1 \
  /media/movies/SomeMovie/SomeMovie.mkv

# Expected output: codec_name=hevc
```

### 6.3 Verify Plex Playback

As files appear:

- Browse Plex library (content appears gradually)
- Play sample transcoded files
- Verify quality and playback performance

## Phase 7: Cleanup (After Transcoding Completes)

### 7.1 Verify Transcoding Complete

Check that staging is empty:

```bash
# Check staging directories
kubectl exec -n media -c tdarr deployment/tdarr -- \
  ls -la /staging/tv /staging/movies

# Should be empty or contain only failed files
```

### 7.2 Verification Checklist

Before deleting staging:

- [ ] Tdarr shows all files processed
- [ ] `/staging/tv` and `/staging/movies` are empty
- [ ] All expected content appears in Plex/Emby
- [ ] Sonarr/Radarr/Lidarr recognized all files
- [ ] Sample playback works perfectly
- [ ] File counts match (source → staging → media-library)
- [ ] No critical files missing

### 7.3 Delete FileBot Pod

```bash
kubectl delete pod -n media filebot-sorter
```

### 7.4 Delete Transfer Job

```bash
kubectl delete job -n media staging-transfer
```

### 7.5 Delete Staging PVC

**WARNING**: Only after full verification (wait 1-2 weeks):

```bash
# This is irreversible
kubectl delete pvc -n media media-staging
```

### 7.6 Remove Staging Mounts from Tdarr

Edit `homelab/apps/tdarr/deployment.yaml` and remove staging volume mounts:

```bash
# Remove staging volumeMount and volume from deployment
# Then apply
kubectl apply -f homelab/apps/tdarr/deployment.yaml
```

### 7.7 Media Server Cleanup

**Recommended**: Keep media server data for 30-60 days as backup, then:

1. Delete source files from media server
2. Repurpose or archive media server hardware

## Files to Create

```
homelab/apps/migration/
├── media-staging-pvc.yaml       # Temporary 20Ti staging volume
├── staging-transfer-job.yaml    # Transfer source files to staging
├── filebot-pod.yaml             # FileBot for sorting mixed files
└── README.md                    # Migration instructions
```

## Command Reference

### Key Commands

```bash
# Monitor staging transfer
kubectl logs -n media job/staging-transfer -f

# Access FileBot pod
kubectl exec -n media -it filebot-sorter -- /bin/sh

# Check volume sizes
kubectl exec -n media -c tdarr deployment/tdarr -- \
  sh -c 'echo "Staging:"; du -sh /staging/*; echo "Media:"; du -sh /media/*'

# Monitor Tdarr
kubectl logs -n media deployment/tdarr -c tdarr -f
kubectl logs -n media deployment/tdarr-node -f

# Restart Tdarr if needed
kubectl rollout restart deployment/tdarr -n media
kubectl rollout restart deployment/tdarr-node -n media
```

## Tdarr Configuration Notes

### Recommended Transcode Settings

**Video:**

- Codec: H.265/HEVC (best compression)
- CRF: 23 (lower = better quality, 18-28 range)
- Preset: medium (fast/medium/slow)
- Resolution: Keep original

**Audio:**

- Codec: AAC or AC3 (widely compatible)
- Bitrate: 128-256 kbps (stereo), 384-640 kbps (5.1)
- Channels: Keep original or downmix to stereo

**Subtitles:**

- Keep: English, forced
- Remove: Commentary, non-English (unless needed)

### Hardware Acceleration

If nodes have GPUs, update Tdarr deployment:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
```

Use `hevc_nvenc` (Nvidia), `hevc_qsv` (Intel), or `hevc_vaapi` (AMD) encoders for 10-20x faster transcoding.

## Data Flow Summary

```
Media Server
    ↓ rsync
Staging Volume (/staging/tv, /staging/movies)
    ↓ FileBot sorts
Staging Volume (organized)
    ↓ Tdarr transcodes
Media Library (/media/tv, /media/movies)
    ↓ Plex/Emby/Sonarr/Radarr access
End Users
```

## Risk Mitigation

1. **Triple backup**: Originals on media server + staging + transcoded in media-library
2. **Gradual availability**: Content usable as soon as transcoded
3. **Clear separation**: Untranscoded (staging) vs transcoded (media-library)
4. **Reversible**: Can re-run transcoding if issues found
5. **Monitored**: Tdarr tracks all progress and errors

## Timeline Estimate

**Phase 1-2: Setup and Transfer**: 1-3 days

- Infrastructure setup: 30 mins
- File transfer to staging: Hours to days (network dependent)

**Phase 3: FileBot Sorting**: 30 mins - 2 hours

- Automatic sorting of mixed files

**Phase 4-6: Transcoding**: 1-4 weeks

- Depends on library size, codecs, and hardware
- Content becomes available gradually as Tdarr processes files
- Already H.265 files: Moved immediately (seconds)
- H.264 files: 0.5-2x realtime
- Music: Available immediately (no transcoding)

**Phase 7: Cleanup**: After verification period (30-60 days)

- Delete staging volume
- Clean up media server