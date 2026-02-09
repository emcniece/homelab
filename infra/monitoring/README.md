# Monitoring Stack

This directory contains Kubernetes manifests for a complete monitoring stack including Prometheus, Grafana, and node_exporter.

## Components

### Prometheus
- **Deployment**: `prometheus-deployment.yaml` - Main Prometheus server
- **Service**: `prometheus-service.yaml` - ClusterIP service for Prometheus
- **ConfigMap**: `prometheus-configmap.yaml` - Prometheus configuration
- **PVC**: `prometheus-pvc.yaml` - Persistent storage for metrics data
- **ServiceAccount**: `prometheus-serviceaccount.yaml` - RBAC for Prometheus

### Grafana
- **Deployment**: `grafana-deployment.yaml` - Grafana dashboard server
- **Service**: `grafana-service.yaml` - ClusterIP service for Grafana
- **ConfigMap**: `grafana-configmap.yaml` - Grafana datasource configuration
- **Alert Rules**: `grafana-alert-rules.yaml` - Pre-configured Ceph alerting rules
- **PVC**: `grafana-pvc.yaml` - Persistent storage for Grafana data
- **Ingress**: `grafana-ingress.yaml` - External access via Traefik
- **Backup CronJob**: `grafana-backup-cronjob.yaml` - Automated daily backups at 2 AM
- **Backup PVC**: `grafana-backup-pvc.yaml` - Backup storage (5GB, keeps 7 days)
- **Backup/Restore Jobs**: `grafana-backup-job.yaml`, `grafana-restore-job.yaml` - Manual backup/restore

### Node Exporter
- **DaemonSet**: `node-exporter-daemonset.yaml` - Node metrics collection
- **Service**: `node-exporter-service.yaml` - Service for node metrics

### Kube State Metrics
- **Deployment**: `kube-state-metrics-deployment.yaml` - Kubernetes object metrics
- **Service**: `kube-state-metrics-service.yaml` - Service for kube-state-metrics
- **ServiceAccount**: `kube-state-metrics-serviceaccount.yaml` - RBAC for kube-state-metrics

### Ceph Manager Metrics
- **Service**: `ceph-mgr-service.yaml` - Headless service for Ceph MGR metrics
- **Endpoints**: `ceph-mgr-endpoints.yaml` - Direct endpoints to all three Proxmox hosts (pve1, pve2, pve3)
- **Note**: The Ceph MGR Prometheus exporter runs on the active manager (port 9283). Prometheus scrapes all three hosts to handle MGR failover automatically.

## Deployment

Deploy the entire monitoring stack:

```bash
kubectl apply -k .
```

Or deploy individual components:

```bash
# Deploy namespace first
kubectl apply -f namespace.yaml

# Deploy Prometheus
kubectl apply -f prometheus-*.yaml

# Deploy Grafana
kubectl apply -f grafana-*.yaml

# Deploy node exporter
kubectl apply -f node-exporter-*.yaml

# Deploy kube-state-metrics
kubectl apply -f kube-state-metrics-*.yaml
```

## Access

- **Grafana**: https://grafana.lab.emc2.build (admin/admin)
- **Prometheus**: Access via port-forward: `kubectl port-forward -n monitoring svc/prometheus 9090:9090`

## Backup and Restore

### Grafana Backups

Automated daily backups protect against data loss:

- **Automated**: Daily backups at 2:00 AM via CronJob
- **Retention**: Last 7 daily backups kept
- **Storage**: 5GB backup PVC (`grafana-backup-storage`)
- **Contents**: All dashboards, datasources, users, settings, and alert state

#### Quick Backup Commands

```bash
# Create immediate backup
kubectl apply -f grafana-backup-job.yaml

# View backup status
kubectl get cronjob grafana-backup -n monitoring

# List available backups
kubectl run -it --rm backup-list --image=alpine:latest --restart=Never -n monitoring \
  --overrides='{"spec":{"containers":[{"name":"backup-list","image":"alpine:latest","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"backup-storage","mountPath":"/backups"}]}],"volumes":[{"name":"backup-storage","persistentVolumeClaim":{"claimName":"grafana-backup-storage"}}]}}'
```

#### Restore from Backup

```bash
# 1. Scale down Grafana
kubectl scale deployment grafana -n monitoring --replicas=0

# 2. Restore from latest backup
kubectl apply -f grafana-restore-job.yaml
kubectl wait --for=condition=complete job/grafana-restore -n monitoring --timeout=5m

# 3. Scale back up
kubectl scale deployment grafana -n monitoring --replicas=1
```

**📚 Full Documentation**: See [GRAFANA-BACKUP-RESTORE.md](./GRAFANA-BACKUP-RESTORE.md) for detailed procedures and [BACKUP-QUICKSTART.md](./BACKUP-QUICKSTART.md) for quick reference.

## Storage

The monitoring stack uses the `ceph-rbd` storage class for persistent volumes. Ensure this storage class is available in your cluster.

## Configuration

### Prometheus
- Retention: 3 days
- Scrape interval: 30s
- Monitors: Kubernetes API, nodes, pods, services, and custom applications

### Grafana
- Pre-configured with Prometheus datasource
- Default admin credentials: admin/admin
- Persistent storage for dashboards and configuration

### Node Exporter
- Collects system metrics from all nodes
- Excludes certain filesystem types and mount points
- Runs with appropriate security context

## Monitoring Targets

The Prometheus configuration automatically discovers and monitors:
- Kubernetes API server
- Kubernetes nodes (via kubelet)
- Kubernetes pods (via cAdvisor)
- Node exporter metrics
- Kube-state-metrics
- Ceph cluster metrics (via MGR Prometheus exporter on pve1, pve2, pve3)
- Traefik ingress controller metrics
- Services with `prometheus.io/scrape: "true"` annotation

## Customization

To add custom monitoring targets, modify the `prometheus-configmap.yaml` file and add new scrape configurations.

To add custom dashboards to Grafana, you can:
1. Import dashboards through the Grafana UI
2. Add dashboard JSON files to a ConfigMap and mount them
3. Use Grafana's provisioning system for automated dashboard deployment

### Recommended Ceph Dashboards

Import these official Grafana dashboards for Ceph monitoring:
- **Ceph Cluster**: Dashboard ID 2842
- **Ceph OSD**: Dashboard ID 5336
- **Ceph Pools**: Dashboard ID 5342

```bash
# Access Grafana
https://grafana.lab.emc2.build

# Navigate to: Dashboards > Import > Enter Dashboard ID
```

## Ceph Metrics

The Ceph MGR Prometheus exporter provides comprehensive cluster metrics:

### Health Metrics
- `ceph_health_status` - Overall cluster health (0=ERR, 1=WARN, 2=OK)
- `ceph_mon_quorum_status` - Monitor quorum membership
- `ceph_mgr_status` - Manager active/standby status

### OSD Metrics
- `ceph_osd_up` - OSD up status (1=up, 0=down)
- `ceph_osd_in` - OSD in status (1=in, 0=out)
- `ceph_osd_metadata` - OSD metadata (hostname, device, etc.)
- `ceph_osd_stat_bytes` - OSD total capacity
- `ceph_osd_stat_bytes_used` - OSD used capacity
- `ceph_osd_perf_commit_latency_seconds` - OSD commit latency
- `ceph_osd_perf_apply_latency_seconds` - OSD apply latency

### Pool Metrics
- `ceph_pool_objects` - Number of objects per pool
- `ceph_pool_bytes_used` - Pool storage usage
- `ceph_pool_max_avail` - Pool maximum available space
- `ceph_pool_rd` - Pool read operations
- `ceph_pool_wr` - Pool write operations
- `ceph_pool_rd_bytes` - Pool read bytes
- `ceph_pool_wr_bytes` - Pool write bytes

### PG Metrics
- `ceph_pg_total` - Total placement groups
- `ceph_pg_active` - Active PGs
- `ceph_pg_clean` - Clean PGs
- `ceph_pg_degraded` - Degraded PGs
- `ceph_pg_undersized` - Undersized PGs
- `ceph_pg_backfilling` - PGs in backfill state

### Recovery Metrics
- `ceph_cluster_recovering_objects_per_sec` - Recovery rate
- `ceph_cluster_recovering_bytes_per_sec` - Recovery bandwidth
- `ceph_num_objects_degraded` - Number of degraded objects
- `ceph_num_objects_misplaced` - Number of misplaced objects

## High Availability

The Ceph monitoring setup is designed for high availability:

### MGR Failover Handling
- Prometheus scrapes all three Proxmox hosts (pve1, pve2, pve3)
- Only the active MGR responds with metrics (returns metrics on port 9283)
- Standby MGRs return connection refused (Prometheus ignores these)
- When MGR fails over, metrics automatically come from the new active MGR
- No manual intervention required

### Network Resilience
- If a Proxmox host becomes unreachable, Prometheus continues scraping the others
- Metrics remain available as long as the active MGR is reachable
- Each endpoint is labeled with `proxmox_host` for identification

### Example Queries

Check which MGR is currently active:
```promql
ceph_mgr_status{ceph_daemon=~"mgr.*"} == 1
```

Monitor OSD health across all OSDs:
```promql
count(ceph_osd_up == 1) / count(ceph_osd_up)
```

Track cluster health over time:
```promql
ceph_health_status
```

Monitor recovery progress:
```promql
rate(ceph_cluster_recovering_objects_per_sec[5m])
```

## Alerting

### Grafana Alert Rules

The monitoring stack includes pre-configured alert rules for critical Ceph events:

- **`grafana-alert-rules.yaml`**: Alert rules provisioned automatically on Grafana startup

#### Configured Alerts

1. **Ceph OSD Down** (Critical)
   - Triggers when any OSD goes down (`ceph_osd_up == 0`)
   - Severity: Critical
   - Wait time: 2 minutes
   - Includes runbook link to recovery documentation

2. **Ceph OSD Nearly Full** (Warning)
   - Triggers when OSD utilization exceeds 80%
   - Severity: Warning
   - Wait time: 5 minutes
   - Helps prevent cluster full conditions

3. **Ceph Cluster Health Warning** (Warning)
   - Triggers when cluster enters HEALTH_WARN state (`ceph_health_status == 1`)
   - Severity: Warning
   - Wait time: 10 minutes
   - Filters out transient warnings

4. **Ceph Cluster Health Error** (Critical)
   - Triggers when cluster enters HEALTH_ERR state (`ceph_health_status == 2`)
   - Severity: Critical
   - Wait time: 2 minutes
   - Immediate attention required

#### Viewing Alerts

Access Grafana alerts:
1. Navigate to https://grafana.lab.emc2.build
2. Go to **Alerting** > **Alert rules**
3. Look for the **Ceph Storage Alerts** folder

#### Alert States

- **OK**: No issues detected
- **Alerting**: Condition met for the specified duration
- **No Data**: Prometheus is not receiving Ceph metrics
- **Error**: Query or evaluation error

#### Customizing Alerts

To modify alert rules:
1. Edit `grafana-alert-rules.yaml`
2. Adjust thresholds, durations, or add new alerts
3. Apply changes: `kubectl apply -k .`
4. Restart Grafana: `kubectl rollout restart deployment/grafana -n monitoring`

#### Alert Notification Channels

To receive alert notifications, configure notification channels in Grafana:
1. Go to **Alerting** > **Contact points**
2. Add notification channels (email, Slack, PagerDuty, etc.)
3. Create notification policies to route alerts

### Prometheus Alert Manager (Alternative)

For more advanced alerting, consider deploying Prometheus AlertManager:
- Supports complex routing rules
- De-duplication and grouping
- Silencing and inhibition
- Multiple notification integrations
