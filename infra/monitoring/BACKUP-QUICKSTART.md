# Grafana Backup Quick Reference

## Quick Commands

### Create Immediate Backup
```bash
kubectl apply -f grafana-backup-job.yaml
kubectl wait --for=condition=complete job/grafana-backup-manual -n monitoring --timeout=5m
kubectl logs -n monitoring job/grafana-backup-manual
kubectl delete job grafana-backup-manual -n monitoring
```

### List Backups
```bash
kubectl run -it --rm backup-list --image=alpine:latest --restart=Never -n monitoring \
  --overrides='{"spec":{"containers":[{"name":"backup-list","image":"alpine:latest","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"backup-storage","mountPath":"/backups"}]}],"volumes":[{"name":"backup-storage","persistentVolumeClaim":{"claimName":"grafana-backup-storage"}}]}}'
```

### Restore from Backup
```bash
# 1. Scale down Grafana
kubectl scale deployment grafana -n monitoring --replicas=0

# 2. Wait for shutdown
kubectl wait --for=delete pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=2m

# 3. Restore
kubectl apply -f grafana-restore-job.yaml
kubectl wait --for=condition=complete job/grafana-restore -n monitoring --timeout=5m

# 4. Scale back up
kubectl scale deployment grafana -n monitoring --replicas=1
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=3m

# 5. Cleanup
kubectl delete job grafana-restore -n monitoring
```

### Check Backup Status
```bash
# View CronJob
kubectl get cronjob grafana-backup -n monitoring

# View recent jobs
kubectl get jobs -n monitoring -l app.kubernetes.io/name=grafana-backup

# View logs of last backup
kubectl logs -n monitoring $(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana-backup --sort-by=.metadata.creationTimestamp -o name | tail -1)
```

## Backup Schedule

- **Frequency**: Daily at 2:00 AM
- **Retention**: 7 days
- **Location**: PVC `grafana-backup-storage` (5GB)

## Important Notes

⚠️ **Before major changes**: Always create a manual backup first!

⚠️ **Restore warning**: Restoring deletes all current Grafana data!

📝 **Best practice**: Export important dashboards to JSON and commit to git

## See Full Documentation

For detailed procedures, troubleshooting, and disaster recovery:
- [GRAFANA-BACKUP-RESTORE.md](./GRAFANA-BACKUP-RESTORE.md)
