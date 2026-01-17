#!/bin/bash

# Uninstall Immich Helm chart
helm ls --namespace immich
helm delete --namespace immich immich

# Delete postgres and prerequisites in reverse order.
# Several resources commented out to make reinstall faster.

#kubectl delete -f 08-immich-servers-transport.yaml
#kubectl delete -f 07-immich-middleware.yaml
#kubectl delete -f 06-immich-pvc.yaml
kubectl delete -f 05-postgres-service.yaml
kubectl delete -f 04-postgres-deployment.yaml
#kubectl delete -f 03a-postgres-init-configmap.yaml
#kubectl delete -f 03-postgres-pvc.yaml
#kubectl delete -f 02-postgres-secret.yaml
#kubectl delete -f 01-namespace.yaml
