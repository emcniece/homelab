# Ceph Dashboard Compatibility Issues

## Problem Summary

The official Ceph dashboards from Grafana.com (IDs 2842, 5336, 5342) were designed for **older versions of Ceph** and expect metrics that **no longer exist** in **Ceph Squid (19.x)**.

Your cluster is running: **Ceph 19.2.3 (Squid)**

Many panels show no data because they query metrics like:
- `ceph_osd_op_w_in_bytes` ❌ (doesn't exist)
- `ceph_osd_op_r_in_bytes` ❌ (doesn't exist)  
- `ceph_osd_stat_bytes_used` ❌ (doesn't exist)
- ... and many others

## Root Cause

### Metric Schema Changes

Ceph's Prometheus metrics have evolved significantly:

**Old Ceph (< 16.x "Pacific")**:
- Exported detailed per-OSD operation metrics
- Included metrics like `ceph_osd_op_*`, `ceph_osd_stat_*`
- Per-OSD throughput and IOPS

**Ceph Squid (19.x - current)**:
- Simplified metric set
- Pool-level metrics instead of per-OSD operations
- Focus on cluster health and aggregated stats

### Available Metrics in Ceph Squid

Query Prometheus to see all available Ceph metrics:

```bash
kubectl exec -n monitoring deployment/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' | \
  jq -r '.data[] | select(startswith("ceph"))' | sort
```

**Key metrics that DO exist:**

#### Cluster Health
- `ceph_health_status` - Overall health (0=ERR, 1=WARN, 2=OK)
- `ceph_cluster_total_bytes` - Total cluster capacity
- `ceph_cluster_total_used_bytes` - Used capacity
- `ceph_num_objects_degraded` - Degraded objects count
- `ceph_num_objects_misplaced` - Misplaced objects count

#### OSD Metrics
- `ceph_osd_up` - OSD up status (1=up, 0=down)
- `ceph_osd_in` - OSD in status (1=in, 0=out)
- `ceph_osd_weight` - OSD weight
- `ceph_osd_metadata` - OSD metadata (hostname, device, etc.)
- `ceph_osd_apply_latency_ms` - Apply latency
- `ceph_osd_commit_latency_ms` - Commit latency

#### Pool Metrics (aggregated)
- `ceph_pool_bytes_used` - Pool storage usage
- `ceph_pool_objects` - Number of objects
- `ceph_pool_rd` - Read operations (counter)
- `ceph_pool_wr` - Write operations (counter)
- `ceph_pool_rd_bytes` - Read bytes (counter)
- `ceph_pool_wr_bytes` - Write bytes (counter)
- `ceph_pool_recovering_bytes_per_sec` - Recovery bandwidth
- `ceph_pool_recovering_objects_per_sec` - Recovery rate

#### Monitor & Manager
- `ceph_mon_quorum_status` - Monitor quorum
- `ceph_mgr_status` - Manager active/standby status
- `ceph_mon_metadata` - Monitor metadata
- `ceph_mgr_metadata` - Manager metadata

## Solution: Custom Ceph Squid Dashboard

I've created a **new dashboard optimized for Ceph Squid** that uses only metrics that actually exist:

### View the New Dashboard

**Ceph Squid Cluster Overview**
- URL: https://grafana.lab.emc2.build/d/c936dc12-b337-4196-a261-476452c3f753/ceph-squid-cluster-overview

This dashboard includes:
- ✅ Cluster health status
- ✅ OSD up/down status
- ✅ Total capacity and usage
- ✅ OSD latency metrics
- ✅ Pool usage and objects
- ✅ Pool IOPS (read/write rates)
- ✅ Pool throughput (bandwidth)
- ✅ Recovery progress

### Old Dashboards

The imported dashboards (2842, 5336, 5342) will have many empty panels. You can:

**Option 1: Delete them** (recommended)
```bash
# Via Grafana UI:
# https://grafana.lab.emc2.build/dashboards
# Click dashboard → Settings → Delete
```

**Option 2: Keep them for panels that DO work**
- Some panels may show data if they use available metrics
- Most panels will be empty and can be ignored
- Consider this a reference for what metrics USED to exist

## Creating Custom Panels

To add custom panels for your specific needs:

### Example: Pool Write IOPS

```promql
rate(ceph_pool_wr[5m])
```

### Example: Pool Read Throughput

```promql
rate(ceph_pool_wr_bytes[5m])
```

### Example: OSD Health Check

```promql
count(ceph_osd_up == 1) / count(ceph_osd_up)
```

### Example: Cluster Utilization Percentage

```promql
(ceph_cluster_total_used_bytes / ceph_cluster_total_bytes) * 100
```

### Example: Recovery Active

```promql
sum(ceph_pool_recovering_objects_per_sec) > 0
```

## Checking Available Metrics

Before creating a dashboard panel, verify the metric exists:

### Via Prometheus UI

```bash
kubectl port-forward -n monitoring svc/prometheus 9090:9090
```

Then visit: http://localhost:9090/graph

### Via API

```bash
kubectl exec -n monitoring deployment/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/series?match[]=ceph_pool_wr'
```

### Via Grafana Explore

1. Go to https://grafana.lab.emc2.build
2. Click **Explore** (compass icon)
3. Type `ceph_` and use autocomplete to see available metrics

## Why Per-OSD Metrics Are Gone

From Ceph Squid onwards, the design philosophy shifted:

### Old Approach
- Export every possible metric
- Per-OSD operation counters
- High cardinality (lots of time series)
- Performance impact on large clusters

### New Approach (Squid+)
- Export aggregated metrics
- Pool-level statistics
- Lower cardinality
- Better performance at scale
- Use Ceph Dashboard for detailed per-OSD views

## Alternative: Ceph Dashboard

For detailed per-OSD metrics, use the built-in Ceph Dashboard:

```bash
# Get dashboard URL
ssh pve2 "ceph mgr services | jq -r '.dashboard'"

# Access via browser (typically port 8443)
# https://<pve-host>:8443

# Get credentials
ssh pve2 "ceph dashboard ac-user-show admin"
```

The Ceph Dashboard provides:
- Detailed per-OSD stats
- Real-time performance graphs
- Disk usage per OSD
- Operation latency per OSD
- Much more detailed than Prometheus metrics

## Metric Mapping Guide

If you're trying to migrate old dashboard panels, here's what's available:

| Old Metric (doesn't exist) | New Metric/Alternative | Type |
|----------------------------|------------------------|------|
| `ceph_osd_op_w_in_bytes` | `ceph_pool_wr_bytes` | Counter (pool-level) |
| `ceph_osd_op_r_in_bytes` | `ceph_pool_rd_bytes` | Counter (pool-level) |
| `ceph_osd_op_w` | `ceph_pool_wr` | Counter (pool-level) |
| `ceph_osd_op_r` | `ceph_pool_rd` | Counter (pool-level) |
| `ceph_osd_stat_bytes_used` | N/A | Use Ceph Dashboard |
| `ceph_osd_stat_bytes` | N/A | Use Ceph Dashboard |
| `ceph_osd_perf_*` | `ceph_osd_commit_latency_ms`, `ceph_osd_apply_latency_ms` | Gauge |

**Note**: Use `rate()` function for counter metrics to get per-second rates:
```promql
rate(ceph_pool_wr_bytes[5m])  # Write bytes per second
```

## Recommendations

1. **Use the new Ceph Squid dashboard** - It's designed for your cluster version
2. **Delete old dashboards** - They'll mostly show empty panels
3. **Use Ceph Dashboard** - For detailed per-OSD metrics
4. **Create custom panels** - Based on available metrics (see list above)
5. **Monitor at pool level** - That's where the metrics are now

## Backup New Dashboard

Export the working dashboard to git:

```bash
cd /Users/emcniece/code/homelab/homelab/infra/monitoring/dashboards

curl -s -u admin:admin \
  "https://grafana.lab.emc2.build/api/dashboards/uid/c936dc12-b337-4196-a261-476452c3f753" | \
  jq '.' > ceph-squid-cluster-overview.json

git add ceph-squid-cluster-overview.json
git commit -m "Add Ceph Squid-compatible dashboard"
git push
```

## Future: Upgrading Dashboards

If you upgrade Ceph or find new dashboards:

1. **Check Ceph version compatibility** - Look for dashboards tagged with your version
2. **Test before committing** - Import to test, verify panels show data
3. **Export working dashboards** - Save to git after verifying
4. **Document metrics used** - Note which metrics each dashboard needs

## Related Resources

- [Ceph Prometheus Module Docs](https://docs.ceph.com/en/squid/mgr/prometheus/)
- [Grafana Explore](https://grafana.lab.emc2.build/explore)
- [Prometheus Metrics Browser](http://localhost:9090/graph) (after port-forward)
- [Ceph Squid Dashboard](https://grafana.lab.emc2.build/d/c936dc12-b337-4196-a261-476452c3f753/ceph-squid-cluster-overview)
