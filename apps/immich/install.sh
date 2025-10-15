#!/bin/bash
# https://github.com/immich-app/immich-charts/blob/main/README.md

helm install --create-namespace \
 --namespace immich \
 immich oci://ghcr.io/immich-app/immich-charts/immich \
 -f values.yaml
