#!/bin/bash
# Script to copy SSL certificates from traefik-system namespace to default namespace
# This is required because the homelab cluster's Traefik reads certificates from the default namespace

echo "Copying SSL certificates from traefik-system to default namespace..."

# List of certificates to copy
certificates=(
    "home-emc2-build-letsencrypt-tls"
    "plex-home-emc2-build-letsencrypt-tls"
    "sonarr-home-emc2-build-letsencrypt-tls"
    "radarr-home-emc2-build-letsencrypt-tls"
    "lidarr-home-emc2-build-letsencrypt-tls"
    "deluge-home-emc2-build-letsencrypt-tls"
    "sabnzbd-home-emc2-build-letsencrypt-tls"
    "plexpy-home-emc2-build-letsencrypt-tls"
    "emby-home-emc2-build-letsencrypt-tls"
)

for cert in "${certificates[@]}"; do
    echo "Copying certificate: $cert"
    kubectl get secret $cert -n traefik-system -o yaml | sed 's/namespace: traefik-system/namespace: default/' | kubectl apply -f -
done

echo "SSL certificates copied successfully!"
echo "You can now apply the ingress resources with TLS configuration."
