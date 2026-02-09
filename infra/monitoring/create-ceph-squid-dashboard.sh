#!/bin/bash
set -e

GRAFANA_URL="https://grafana.lab.emc2.build"
GRAFANA_USER="admin"
GRAFANA_PASS="admin"

echo "Creating Ceph Squid-compatible dashboard..."

# Create a dashboard optimized for Ceph Squid metrics
DASHBOARD_JSON=$(cat << 'DASHBOARD'
{
  "dashboard": {
    "title": "Ceph Squid Cluster Overview",
    "tags": ["ceph", "squid"],
    "timezone": "browser",
    "schemaVersion": 16,
    "version": 0,
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "Cluster Health Status",
        "type": "stat",
        "targets": [
          {
            "expr": "ceph_health_status",
            "refId": "A",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "mappings": [
              {"type": "value", "value": "0", "text": "HEALTH_ERR", "color": "red"},
              {"type": "value", "value": "1", "text": "HEALTH_WARN", "color": "yellow"},
              {"type": "value", "value": "2", "text": "HEALTH_OK", "color": "green"}
            ],
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {"value": null, "color": "red"},
                {"value": 1, "color": "yellow"},
                {"value": 2, "color": "green"}
              ]
            }
          }
        },
        "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
      },
      {
        "id": 2,
        "title": "OSDs Up",
        "type": "stat",
        "targets": [
          {
            "expr": "count(ceph_osd_up == 1)",
            "refId": "A",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "gridPos": {"h": 4, "w": 3, "x": 6, "y": 0}
      },
      {
        "id": 3,
        "title": "OSDs In",
        "type": "stat",
        "targets": [
          {
            "expr": "count(ceph_osd_in == 1)",
            "refId": "A",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "gridPos": {"h": 4, "w": 3, "x": 9, "y": 0}
      },
      {
        "id": 4,
        "title": "Total Cluster Capacity",
        "type": "stat",
        "targets": [
          {
            "expr": "ceph_cluster_total_bytes",
            "refId": "A",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "bytes"
          }
        },
        "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0}
      },
      {
        "id": 5,
        "title": "Cluster Used Capacity",
        "type": "stat",
        "targets": [
          {
            "expr": "ceph_cluster_total_used_bytes",
            "refId": "A",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "bytes"
          }
        },
        "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0}
      },
      {
        "id": 6,
        "title": "OSD Status Map",
        "type": "timeseries",
        "targets": [
          {
            "expr": "ceph_osd_up",
            "refId": "A",
            "legendFormat": "OSD {{ceph_daemon}} - Up",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "custom": {"drawStyle": "line", "fillOpacity": 10},
            "max": 1,
            "min": 0
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4}
      },
      {
        "id": 7,
        "title": "OSD Commit Latency",
        "type": "timeseries",
        "targets": [
          {
            "expr": "ceph_osd_commit_latency_ms",
            "refId": "A",
            "legendFormat": "{{ceph_daemon}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "ms"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4}
      },
      {
        "id": 8,
        "title": "Pool Usage",
        "type": "timeseries",
        "targets": [
          {
            "expr": "ceph_pool_bytes_used",
            "refId": "A",
            "legendFormat": "{{name}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "bytes"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12}
      },
      {
        "id": 9,
        "title": "Pool IOPS (Read)",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(ceph_pool_rd[5m])",
            "refId": "A",
            "legendFormat": "{{name}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "ops"
          }
        },
        "gridPos": {"h": 8, "w": 6, "x": 12, "y": 12}
      },
      {
        "id": 10,
        "title": "Pool IOPS (Write)",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(ceph_pool_wr[5m])",
            "refId": "A",
            "legendFormat": "{{name}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "ops"
          }
        },
        "gridPos": {"h": 8, "w": 6, "x": 18, "y": 12}
      },
      {
        "id": 11,
        "title": "Pool Throughput (Read)",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(ceph_pool_rd_bytes[5m])",
            "refId": "A",
            "legendFormat": "{{name}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "Bps"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 20}
      },
      {
        "id": 12,
        "title": "Pool Throughput (Write)",
        "type": "timeseries",
        "targets": [
          {
            "expr": "rate(ceph_pool_wr_bytes[5m])",
            "refId": "A",
            "legendFormat": "{{name}}",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "Bps"
          }
        },
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 20}
      },
      {
        "id": 13,
        "title": "Recovery Progress",
        "type": "timeseries",
        "targets": [
          {
            "expr": "sum(ceph_pool_recovering_objects_per_sec)",
            "refId": "A",
            "legendFormat": "Objects/sec",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          },
          {
            "expr": "sum(ceph_pool_recovering_bytes_per_sec)",
            "refId": "B",
            "legendFormat": "Bytes/sec",
            "datasource": {"type": "prometheus", "uid": "prometheus"}
          }
        ],
        "fieldConfig": {
          "defaults": {
            "unit": "short"
          },
          "overrides": [
            {
              "matcher": {"id": "byName", "options": "Bytes/sec"},
              "properties": [{"id": "unit", "value": "Bps"}]
            }
          ]
        },
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": 28}
      }
    ]
  },
  "overwrite": true
}
DASHBOARD
)

# Import dashboard
echo "Importing Ceph Squid dashboard to Grafana..."
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
  -d "$DASHBOARD_JSON" \
  "${GRAFANA_URL}/api/dashboards/db")

# Check response
if echo "$RESPONSE" | jq -e '.slug' > /dev/null 2>&1; then
  SLUG=$(echo "$RESPONSE" | jq -r '.slug')
  DASH_UID=$(echo "$RESPONSE" | jq -r '.uid')
  echo "✓ Successfully created Ceph Squid dashboard"
  echo "  URL: ${GRAFANA_URL}/d/${DASH_UID}/${SLUG}"
else
  echo "✗ Failed to create dashboard"
  echo "  Response: $RESPONSE"
  exit 1
fi
