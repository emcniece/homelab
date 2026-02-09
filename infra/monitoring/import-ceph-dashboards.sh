#!/bin/bash
set -e

GRAFANA_URL="https://grafana.lab.emc2.build"
GRAFANA_USER="admin"
GRAFANA_PASS="admin"

echo "Importing Ceph dashboards to Grafana..."

# Dashboard IDs from grafana.com
DASHBOARDS=(
  "2842:Ceph Cluster"
  "5336:Ceph OSD"
  "5342:Ceph Pools"
)

for dashboard in "${DASHBOARDS[@]}"; do
  IFS=':' read -r DASHBOARD_ID DASHBOARD_NAME <<< "$dashboard"
  
  echo ""
  echo "=== Importing Dashboard: $DASHBOARD_NAME (ID: $DASHBOARD_ID) ==="
  
  # Download dashboard JSON from grafana.com
  echo "Downloading dashboard JSON..."
  DASHBOARD_JSON=$(curl -s "https://grafana.com/api/dashboards/${DASHBOARD_ID}/revisions/latest/download")
  
  # Check if download was successful
  if [ -z "$DASHBOARD_JSON" ] || [ "$DASHBOARD_JSON" = "null" ]; then
    echo "ERROR: Failed to download dashboard $DASHBOARD_ID"
    continue
  fi
  
  # Prepare import payload
  IMPORT_PAYLOAD=$(jq -n \
    --arg dashboard "$DASHBOARD_JSON" \
    --arg dsUid "prometheus" \
    '{
      dashboard: ($dashboard | fromjson),
      overwrite: true,
      inputs: [
        {
          name: "DS_PROMETHEUS",
          type: "datasource",
          pluginId: "prometheus",
          value: $dsUid
        }
      ]
    }')
  
  # Import dashboard
  echo "Importing to Grafana..."
  RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    -d "$IMPORT_PAYLOAD" \
    "${GRAFANA_URL}/api/dashboards/import")
  
  # Check response
  if echo "$RESPONSE" | jq -e '.slug' > /dev/null 2>&1; then
    SLUG=$(echo "$RESPONSE" | jq -r '.slug')
    DASH_UID=$(echo "$RESPONSE" | jq -r '.uid')
    echo "✓ Successfully imported: $DASHBOARD_NAME"
    echo "  URL: ${GRAFANA_URL}/d/${DASH_UID}/${SLUG}"
  else
    echo "✗ Failed to import: $DASHBOARD_NAME"
    echo "  Response: $RESPONSE"
  fi
done

echo ""
echo "=== Import Complete ==="
echo "View dashboards at: ${GRAFANA_URL}/dashboards"
