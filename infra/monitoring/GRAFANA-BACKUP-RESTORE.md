# Grafana Backup and Restore Guide

This guide provides comprehensive backup and restore procedures for Grafana to prevent data loss.

## Overview

The backup solution includes:
- **Automated Daily Backups**: CronJob runs at 2 AM daily
- **Manual Backup**: On-demand backup job
- **Quick Restore**: Job to restore from the latest backup
- **Retention**: Keeps last 7 daily backups

## Architecture

```
┌─────────────────┐      ┌──────────────────┐
│  Grafana PVC    │─────▶│  Backup CronJob  │
│  (grafana-      │      │  (Daily 2 AM)    │
│   storage)      │      └──────────────────┘
└─────────────────┘               │
                                  ▼
                         ┌──────────────────┐
                         │  Backup PVC      │
                         │  (grafana-       │
                         │   backup-storage)│
                         └──────────────────┘
                                  │
                                  ▼
                         ┌──────────────────┐
                         │  Restore Job     │
                         │  (Manual)        │
                         └──────────────────┘
```

## Initial Setup

Deploy the backup infrastructure:

```bash
# Create the backup storage PVC
kubectl apply -f grafana-backup-pvc.yaml

# Deploy the automated backup CronJob
kubectl apply -f grafana-backup-cronjob.yaml

# Verify the CronJob is scheduled
kubectl get cronjobs -n monitoring
```

## Creating Backups

### Automated Backups

The CronJob runs automatically every day at 2 AM:

```bash
# Check CronJob status
kubectl get cronjob grafana-backup -n monitoring

# View recent backup jobs
kubectl get jobs -n monitoring -l app.kubernetes.io/name=grafana-backup

# View backup job logs
kubectl logs -n monitoring -l job-name=grafana-backup-<timestamp>
```

### Manual Backup

Create a backup immediately:

```bash
# Create a manual backup
kubectl apply -f grafana-backup-job.yaml

# Wait for completion
kubectl wait --for=condition=complete job/grafana-backup-manual -n monitoring --timeout=5m

# View backup logs
kubectl logs -n monitoring job/grafana-backup-manual

# Clean up the job
kubectl delete job grafana-backup-manual -n monitoring
```

### List Available Backups

```bash
# List all backups
kubectl run -it --rm backup-list \
  --image=alpine:latest \
  --restart=Never \
  -n monitoring \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "backup-list",
      "image": "alpine:latest",
      "command": ["ls", "-lh", "/backups"],
      "volumeMounts": [{
        "name": "backup-storage",
        "mountPath": "/backups"
      }]
    }],
    "volumes": [{
      "name": "backup-storage",
      "persistentVolumeClaim": {
        "claimName": "grafana-backup-storage"
      }
    }]
  }
}'
```

## Restoring from Backup

### Prerequisites

**⚠️ WARNING**: Restoring will **DELETE ALL CURRENT DATA** in Grafana!

Before restoring:
1. Verify a backup exists
2. Scale down Grafana to prevent conflicts
3. Take a final backup if you want to preserve current state

### Restore Procedure

```bash
# 1. Scale down Grafana
kubectl scale deployment grafana -n monitoring --replicas=0

# 2. Wait for Grafana to shut down
kubectl wait --for=delete pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=2m

# 3. Run the restore job
kubectl apply -f grafana-restore-job.yaml

# 4. Wait for restore to complete
kubectl wait --for=condition=complete job/grafana-restore -n monitoring --timeout=5m

# 5. View restore logs
kubectl logs -n monitoring job/grafana-restore

# 6. Scale Grafana back up
kubectl scale deployment grafana -n monitoring --replicas=1

# 7. Wait for Grafana to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=3m

# 8. Verify Grafana is accessible
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Open http://localhost:3000

# 9. Clean up the restore job
kubectl delete job grafana-restore -n monitoring
```

### Restore from Specific Backup

To restore from a specific backup (not the latest):

```bash
# 1. List available backups and note the filename
kubectl run -it --rm backup-list \
  --image=alpine:latest \
  --restart=Never \
  -n monitoring \
  --overrides='...' # See "List Available Backups" above

# 2. Edit grafana-restore-job.yaml and modify the script:
# Change:
#   LATEST_BACKUP=$(ls -t /backups/grafana-backup-*.tar.gz | head -n 1)
# To:
#   LATEST_BACKUP="/backups/grafana-backup-20260122-140530.tar.gz"  # Your specific backup

# 3. Follow the restore procedure above
```

## Backup Retention

- **Daily backups**: Kept for 7 days
- **Storage**: 5GB allocated for backups
- **Automatic cleanup**: Old backups deleted automatically

To change retention:
1. Edit `grafana-backup-cronjob.yaml`
2. Modify the cleanup line: `tail -n +8` (8 = keep 7 backups)
3. Apply changes: `kubectl apply -f grafana-backup-cronjob.yaml`

## Monitoring Backups

### Check Backup Health

```bash
# Check if CronJob is running
kubectl get cronjob grafana-backup -n monitoring

# View recent jobs
kubectl get jobs -n monitoring -l app.kubernetes.io/name=grafana-backup --sort-by=.status.startTime

# Check last backup date
kubectl run -it --rm backup-check \
  --image=alpine:latest \
  --restart=Never \
  -n monitoring \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "backup-check",
      "image": "alpine:latest",
      "command": ["sh", "-c", "ls -lt /backups/grafana-backup-*.tar.gz | head -5"],
      "volumeMounts": [{
        "name": "backup-storage",
        "mountPath": "/backups"
      }]
    }],
    "volumes": [{
      "name": "backup-storage",
      "persistentVolumeClaim": {
        "claimName": "grafana-backup-storage"
      }
    }]
  }
}'
```

### Backup Failed?

If a backup fails:

```bash
# 1. Check job logs
kubectl logs -n monitoring -l job-name=grafana-backup-<timestamp>

# 2. Check PVC status
kubectl get pvc -n monitoring grafana-backup-storage
kubectl describe pvc -n monitoring grafana-backup-storage

# 3. Check disk space
kubectl run -it --rm disk-check \
  --image=alpine:latest \
  --restart=Never \
  -n monitoring \
  --overrides='...' # Mount backup PVC and run 'df -h /backups'

# 4. Manually trigger a backup to test
kubectl apply -f grafana-backup-job.yaml
```

## Additional Backup Methods

### Export Dashboards to Git

For additional protection, export dashboards to version control:

```bash
# Export all dashboards
mkdir -p dashboards
kubectl exec -n monitoring deployment/grafana -- \
  curl -s http://admin:admin@localhost:3000/api/search | \
  python3 -c "import sys, json; [print(d['uid']) for d in json.load(sys.stdin) if d['type']=='dash-db']" | \
  while read uid; do
    kubectl exec -n monitoring deployment/grafana -- \
      curl -s "http://admin:admin@localhost:3000/api/dashboards/uid/$uid" | \
      python3 -m json.tool > "dashboards/${uid}.json"
  done

# Commit to git
git add dashboards/
git commit -m "Backup Grafana dashboards"
git push
```

### Backup to External Storage

For off-cluster backups, sync to an external location:

```bash
# Copy backups to local machine
kubectl cp monitoring/$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana-backup -o jsonpath='{.items[0].metadata.name}'):/backups ./grafana-backups/

# Or use rsync (if you have a backup server)
# Add an rsync step to the backup CronJob script
```

## Disaster Recovery

### Complete PVC Loss

If the Grafana PVC is completely lost:

1. **Recreate PVC**:
   ```bash
   kubectl apply -f grafana-pvc.yaml
   ```

2. **Follow restore procedure** (see above)

3. **If no backups exist**:
   - Grafana will start fresh with empty database
   - Datasources are provisioned automatically from ConfigMap
   - Alert rules are provisioned automatically from ConfigMap
   - Dashboards must be recreated or imported

### Backup PVC Loss

If the backup PVC is lost:

1. **Recreate backup PVC**:
   ```bash
   kubectl apply -f grafana-backup-pvc.yaml
   ```

2. **Create immediate backup**:
   ```bash
   kubectl apply -f grafana-backup-job.yaml
   ```

3. **Resume automated backups** (CronJob continues automatically)

## Best Practices

1. **Test restores regularly** - Run a test restore quarterly
2. **Monitor backup size** - Ensure backup PVC has enough space
3. **Export critical dashboards** - Keep dashboard JSON in git
4. **Document custom configurations** - Note any manual changes made via UI
5. **Use dashboard provisioning** - Store dashboards as code when possible
6. **Set up alerts** - Monitor backup job failures
7. **Off-cluster backups** - Periodically copy backups to external storage

## Troubleshooting

### Backup Job Fails

```bash
# Check job events
kubectl describe job grafana-backup-manual -n monitoring

# Check pod logs
kubectl logs -n monitoring -l job-name=grafana-backup-manual

# Common issues:
# - PVC full: Increase size or reduce retention
# - Permission denied: Check PVC mount permissions
# - Grafana locked: Ensure read-only mount works
```

### Restore Job Fails

```bash
# Check restore logs
kubectl logs -n monitoring job/grafana-restore

# Common issues:
# - Grafana still running: Scale down first
# - Corrupted backup: Try different backup file
# - Permission issues: Job runs as root to fix permissions
```

### Dashboard Changes Not Persisting

If dashboard changes are lost after restart:
- Check if dashboard provisioning is overwriting changes
- Set `allowUiUpdates: false` in dashboard provider to prevent edits
- Or ensure `allowUiUpdates: true` and save to persistent storage

## Recovery Time Objective (RTO)

Expected recovery times:
- **Manual backup**: ~1-2 minutes
- **Restore operation**: ~2-5 minutes
- **Total RTO**: ~10 minutes (including verification)

## Recovery Point Objective (RPO)

- **Automated backups**: Up to 24 hours of data loss
- **Manual backups**: Reduce RPO to minutes before maintenance
