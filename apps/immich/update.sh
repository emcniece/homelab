#!/bin/bash
# Update Immich deployment with new values from values.yaml

echo "Upgrading Immich..."
helm upgrade immich oci://ghcr.io/immich-app/immich-charts/immich \
  --namespace immich \
  -f values.yaml

if [ $? -eq 0 ]; then
  echo ""
  echo "✓ Upgrade completed successfully!"
  echo ""
  echo "Waiting for pods to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=server -n immich --timeout=300s
  
  echo ""
  echo "Current pods:"
  kubectl get pods -n immich
  
  echo ""
  echo "Immich is available at: https://immich.lab.emc2.build"
else
  echo ""
  echo "✗ Upgrade failed!"
  exit 1
fi
