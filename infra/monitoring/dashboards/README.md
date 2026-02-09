# Grafana Dashboards

This directory contains exported Grafana dashboard JSON files for version control and backup purposes.

## Current Dashboards

### Ceph Monitoring Dashboards

1. **Ceph Cluster** (`tbO9LAiZK.json`)
   - Dashboard ID: 2842 (from grafana.com)
   - Overview of entire Ceph cluster health
   - Monitors: OSDs, MONs, MGRs, pools, PGs
   - URL: https://grafana.lab.emc2.build/d/tbO9LAiZK/ceph-cluster

2. **Ceph OSD Single** (`Fj5fAfzik.json`)
   - Dashboard ID: 5336 (from grafana.com)
   - Detailed metrics for individual OSDs
   - Monitors: OSD performance, latency, throughput
   - URL: https://grafana.lab.emc2.build/d/Fj5fAfzik/ceph-osd-single

3. **Ceph Pools** (`-gtf0Bzik.json`)
   - Dashboard ID: 5342 (from grafana.com)
   - Pool-level metrics and statistics
   - Monitors: Pool usage, IOPS, bandwidth
   - URL: https://grafana.lab.emc2.build/d/-gtf0Bzik/ceph-pools

## Exporting Dashboards

To export all current dashboards:

```bash
cd /Users/emcniece/code/homelab/homelab/infra/monitoring/dashboards

curl -s -u admin:admin "https://grafana.lab.emc2.build/api/search?type=dash-db" | \
  jq -r '.[].uid' | \
  while read uid; do
    echo "Exporting dashboard: $uid"
    curl -s -u admin:admin "https://grafana.lab.emc2.build/api/dashboards/uid/$uid" | \
      jq '.' > "${uid}.json"
  done

# Commit to git
git add *.json
git commit -m "Update Grafana dashboard exports"
git push
```

## Importing Dashboards

To import dashboards from these JSON files:

### Via Grafana UI
1. Go to https://grafana.lab.emc2.build
2. Navigate to **Dashboards** > **Import**
3. Click **Upload JSON file**
4. Select the dashboard JSON file
5. Select the Prometheus datasource
6. Click **Import**

### Via API
```bash
# Import a specific dashboard
DASHBOARD_FILE="tbO9LAiZK.json"

curl -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  -d @"$DASHBOARD_FILE" \
  "https://grafana.lab.emc2.build/api/dashboards/db"
```

### Automated Import Script
Use the provided import script:

```bash
cd /Users/emcniece/code/homelab/homelab/infra/monitoring
./import-ceph-dashboards.sh
```

## Dashboard Metadata

Each JSON file contains:
- Dashboard configuration
- Panel definitions
- Queries and metrics
- Variables and templating
- Display settings

The JSON structure includes a `meta` section with:
- Dashboard UID
- Version
- Created/Updated timestamps
- Folder location

## Maintenance

### After Making Changes in Grafana UI

1. **Export updated dashboards**:
   ```bash
   cd dashboards/
   # Run export commands above
   ```

2. **Review changes**:
   ```bash
   git diff *.json
   ```

3. **Commit updates**:
   ```bash
   git add *.json
   git commit -m "Update dashboards: [describe changes]"
   git push
   ```

### Adding New Dashboards

When adding new dashboards to Grafana:

1. **Create/import in Grafana UI**
2. **Export to this directory**
3. **Document in this README**
4. **Commit to git**

## Backup Strategy

Dashboard JSONs provide an additional layer of backup beyond the automated PVC backups:

1. **PVC Backups**: Daily automated backups of entire Grafana instance
2. **Git Repository**: Version-controlled dashboard JSON files
3. **Combined**: Maximum protection against data loss

## Restoring Dashboards

If dashboards are lost:

### Option 1: Restore from PVC Backup
```bash
# See: ../GRAFANA-BACKUP-RESTORE.md
kubectl scale deployment grafana -n monitoring --replicas=0
kubectl apply -f ../grafana-restore-job.yaml
kubectl scale deployment grafana -n monitoring --replicas=1
```

### Option 2: Re-import from JSON Files
```bash
# Import all dashboards from this directory
for dashboard in *.json; do
  curl -X POST \
    -H "Content-Type: application/json" \
    -u admin:admin \
    -d @"$dashboard" \
    "https://grafana.lab.emc2.build/api/dashboards/db"
done
```

## Notes

- Dashboard UIDs are unique identifiers (e.g., `tbO9LAiZK`)
- Filenames match dashboard UIDs for easy identification
- Some UIDs may start with special characters (e.g., `-gtf0Bzik`)
- All dashboards are configured for the `prometheus` datasource
- Dashboards auto-refresh and use relative time ranges

## Related Documentation

- [Grafana Backup & Restore Guide](../GRAFANA-BACKUP-RESTORE.md)
- [Backup Quick Reference](../BACKUP-QUICKSTART.md)
- [Monitoring Stack README](../README.md)
