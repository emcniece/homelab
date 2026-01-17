#!/bin/bash
# https://github.com/immich-app/immich-charts/blob/main/README.md

# Apply postgres and prerequisites
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-postgres-secret.yaml
kubectl apply -f 03-postgres-pvc.yaml
kubectl apply -f 03a-postgres-init-configmap.yaml
kubectl apply -f 04-postgres-deployment.yaml
kubectl apply -f 05-postgres-service.yaml
kubectl apply -f 06-immich-pvc.yaml
kubectl apply -f 07-immich-middleware.yaml
kubectl apply -f 08-immich-servers-transport.yaml

# Wait for postgres to be ready
echo "Waiting for postgres to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres -n immich --timeout=300s

# Install Immich via Helm
helm install --create-namespace \
 --namespace immich \
 immich oci://ghcr.io/immich-app/immich-charts/immich \
 -f values.yaml
