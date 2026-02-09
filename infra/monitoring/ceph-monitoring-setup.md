# Ceph Monitoring Setup Guide

This guide covers the setup and deployment of Ceph cluster monitoring in Prometheus.

## Architecture

The Ceph monitoring setup uses a **multi-endpoint approach** for high availability:

```
┌─────────────────────────────────────────────────┐
│ Kubernetes Prometheus (monitoring namespace)    │
│                                                  │
│  Scrapes all 3 endpoints every 30s:             │
│  ├─ 192.168.10.3:9283 (pve1)                   │
│  ├─ 192.168.10.4:9283 (pve2) ← Active MGR      │
│  └─ 192.168.10.5:9283 (pve3)                   │
│                                                  │
│  Only active MGR returns metrics                │
└─────────────────────────────────────────────────┘
                    │
                    │ HTTP GET /metrics
                    ▼
┌─────────────────────────────────────────────────┐
│ Ceph Cluster (Proxmox hosts)                    │
│                                                  │
│  pve1 (192.168.10.3) - MGR Standby             │
│  pve2 (192.168.10.4) - MGR Active ✓            │
│  pve3 (192.168.10.5) - MGR Standby             │
│                                                  │
│  Prometheus module: Enabled on active MGR       │
│  Port: 9283                                      │
└─────────────────────────────────────────────────┘
```

## Components

### 1. Ceph MGR Endpoints (`ceph-mgr-endpoints.yaml`)
Defines the static IP addresses of all three Proxmox hosts that can run the Ceph Manager:
- `192.168.10.3` (pve1) - mapped to k3s-04
- `192.168.10.4` (pve2) - mapped to k3s-05  
- `192.168.10.5` (pve3) - mapped to k3s-06

### 2. Ceph MGR Service (`ceph-mgr-service.yaml`)
Headless service (ClusterIP: None) that references the endpoints above. This allows Prometheus to discover and scrape all three endpoints.

### 3. Prometheus Scrape Config
Added to `prometheus-configmap.yaml` as a dedicated `ceph` job that:
- Discovers endpoints via Kubernetes service discovery
- Filters for the `ceph-mgr` service
- Labels metrics with `proxmox_host` and `cluster` tags
- Scrapes every 30 seconds with a 10-second timeout

## Deployment

### Prerequisites

Verify Ceph MGR Prometheus module is enabled:

```bash
ssh pve3 "ceph mgr module ls | grep prometheus"
```

Should show `prometheus` in the enabled modules list.

Check which MGR is currently active:

```bash
ssh pve3 "ceph mgr dump | grep active_name"
```

Test metrics endpoint:

```bash
# Replace IP with your active MGR host
curl http://192.168.10.4:9283/metrics | head -20
```

### Deploy to Kubernetes

Apply the monitoring stack with Ceph monitoring:

```bash
# Navigate to monitoring directory
cd homelab/infra/monitoring

# Apply all resources (includes Ceph monitoring)
kubectl apply -k .

# Or apply Ceph resources individually
kubectl apply -f ceph-mgr-service.yaml
kubectl apply -f ceph-mgr-endpoints.yaml

# Restart Prometheus to reload configuration
kubectl rollout restart deployment/prometheus -n monitoring
```

### Verify Deployment

Check that the service and endpoints were created:

```bash
# View service
kubectl get svc -n monitoring ceph-mgr

# View endpoints (should show 3 IPs)
kubectl get endpoints -n monitoring ceph-mgr

# Expected output:
# NAME       ENDPOINTS                                                AGE
# ceph-mgr   192.168.10.3:9283,192.168.10.4:9283,192.168.10.5:9283   1m
```

Check Prometheus targets:

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Open browser: http://localhost:9090/targets
# Look for 'ceph' job - should show 3 targets
# Only the active MGR should show "UP" status
```

### Verify Metrics

Query Prometheus for Ceph metrics:

```bash
# From Prometheus UI (http://localhost:9090)
# Or via API:
curl -s 'http://localhost:9090/api/v1/query?query=ceph_health_status' | jq .
```

Example queries to test:
- `ceph_health_status` - Cluster health
- `ceph_osd_up` - OSD status
- `ceph_pool_bytes_used` - Pool usage
- `ceph_mgr_status` - MGR active/standby

## High Availability Behavior

### Normal Operation
- Prometheus scrapes all 3 endpoints
- Only active MGR (e.g., pve2) returns HTTP 200 with metrics
- Standby MGRs return connection refused (Prometheus marks as DOWN, but this is expected)
- Metrics flow continuously from active MGR

### MGR Failover Scenario
1. Active MGR fails or is stopped
2. Ceph elects a new active MGR (e.g., pve1 or pve3)
3. Prometheus continues scraping all endpoints
4. New active MGR starts responding with metrics
5. **No configuration changes needed** - automatic failover

### Network Partition
- If a Proxmox host becomes unreachable, Prometheus continues scraping the others
- As long as the active MGR is reachable, metrics remain available
- Use `proxmox_host` label to identify which host is responding

## Troubleshooting

### No Ceph targets appear in Prometheus

Check service discovery:
```bash
kubectl get endpoints -n monitoring ceph-mgr
```

If endpoints are empty or missing:
```bash
kubectl describe endpoints -n monitoring ceph-mgr
```

### All 3 targets show as DOWN

Verify network connectivity from Kubernetes to Proxmox:
```bash
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# Inside pod:
apk add curl
curl http://192.168.10.4:9283/metrics
```

Check Ceph MGR status:
```bash
ssh pve3 "ceph mgr services"
```

### Prometheus module not enabled

Enable the Prometheus module:
```bash
ssh pve3 "ceph mgr module enable prometheus"
```

Verify it's running:
```bash
ssh pve3 "ceph mgr services"
# Should output: {"prometheus": "http://192.168.10.X:9283/"}
```

### Metrics are missing or incomplete

Check MGR log for errors:
```bash
ssh pve2 "journalctl -u ceph-mgr@pve2 -n 100"
```

Restart the MGR module:
```bash
ssh pve3 "ceph mgr module disable prometheus"
ssh pve3 "ceph mgr module enable prometheus"
```

### After MGR failover, old host still showing as UP

Wait 2-3 scrape intervals (60-90 seconds) for Prometheus to detect the change. The old MGR will stop responding and Prometheus will mark it as DOWN.

## Configuration Reference

### Prometheus Scrape Config

```yaml
- job_name: 'ceph'
  honor_labels: true
  scrape_interval: 30s
  scrape_timeout: 10s
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
          - monitoring
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      action: keep
      regex: ceph-mgr
```

### Key Labels
- `job`: ceph-mgr
- `cluster`: homelab-ceph
- `proxmox_host`: pve1, pve2, or pve3
- `instance`: Node name (k3s-04, k3s-05, k3s-06)

## Grafana Dashboards

### Import Official Ceph Dashboards

1. Access Grafana: https://grafana.lab.emc2.build
2. Navigate to: **Dashboards** → **Import**
3. Import these dashboard IDs:
   - **2842** - Ceph Cluster Overview
   - **5336** - Ceph OSD Performance
   - **5342** - Ceph Pools Detail

### Custom Dashboard Queries

**Cluster Health Status**:
```promql
ceph_health_status
```

**Total Available Storage**:
```promql
sum(ceph_osd_stat_bytes) / 1024^4
```

**Storage Usage Percentage**:
```promql
100 * sum(ceph_osd_stat_bytes_used) / sum(ceph_osd_stat_bytes)
```

**Number of OSDs Up**:
```promql
count(ceph_osd_up == 1)
```

**OSD Down Alert**:
```promql
count(ceph_osd_up == 0) > 0
```

**Recovery Rate**:
```promql
rate(ceph_cluster_recovering_bytes_per_sec[5m])
```

**Degraded Objects**:
```promql
ceph_num_objects_degraded
```

## Alerting

### Example Prometheus Alert Rules

Add to Prometheus alerting rules:

```yaml
groups:
  - name: ceph
    interval: 30s
    rules:
      - alert: CephHealthError
        expr: ceph_health_status == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Ceph cluster in HEALTH_ERR"
          description: "Ceph cluster {{ $labels.cluster }} is in error state"

      - alert: CephHealthWarning
        expr: ceph_health_status == 1
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Ceph cluster in HEALTH_WARN"
          description: "Ceph cluster {{ $labels.cluster }} has warnings"

      - alert: CephOSDDown
        expr: ceph_osd_up == 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Ceph OSD is down"
          description: "OSD {{ $labels.ceph_daemon }} is down on {{ $labels.hostname }}"

      - alert: CephHighStorageUsage
        expr: (sum(ceph_osd_stat_bytes_used) / sum(ceph_osd_stat_bytes)) > 0.85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Ceph storage usage high"
          description: "Ceph cluster storage usage is {{ $value | humanizePercentage }}"

      - alert: CephRecoveryInProgress
        expr: ceph_num_objects_degraded > 0
        for: 1h
        labels:
          severity: info
        annotations:
          summary: "Ceph recovery in progress"
          description: "{{ $value }} degraded objects, recovery ongoing"
```

## Maintenance

### Updating Endpoints

If you add or remove Proxmox hosts, update `ceph-mgr-endpoints.yaml`:

```bash
# Edit the file
vim homelab/infra/monitoring/ceph-mgr-endpoints.yaml

# Apply changes
kubectl apply -f homelab/infra/monitoring/ceph-mgr-endpoints.yaml

# No Prometheus restart needed - service discovery picks up changes automatically
```

### Monitoring Prometheus Scrape Health

Check scrape success rate:
```promql
up{job="ceph-mgr"}
```

Check scrape duration:
```promql
scrape_duration_seconds{job="ceph-mgr"}
```

Monitor scrape failures:
```promql
rate(prometheus_target_scrapes_failed_total{job="ceph-mgr"}[5m])
```

## Related Documentation

- [Ceph Prometheus Module Docs](https://docs.ceph.com/en/latest/mgr/prometheus/)
- [Prometheus Kubernetes SD](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
- [Main Monitoring README](./README.md)
- [Ceph OSD Recovery Guide](../ceph-osd-recovery.md)
