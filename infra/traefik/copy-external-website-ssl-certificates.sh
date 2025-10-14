#!/bin/bash

# Copy SSL certificates from traefik-system namespace to default namespace
# This is needed because the homelab cluster's Traefik reads certificates from the default namespace

echo "Copying SSL certificates for external websites..."

# List of certificates to copy
certificates=(
    "createsleeprepeat-ca-letsencrypt-tls"
    "echoandflow-ca-letsencrypt-tls"
    "emc2-build-letsencrypt-tls"
    "kamloopsdentalsociety-com-letsencrypt-tls"
)

# Copy each certificate
for cert in "${certificates[@]}"; do
    echo "Copying certificate: $cert"
    
    # Get the certificate from traefik-system namespace
    kubectl get secret "$cert" -n traefik-system -o yaml > /tmp/"$cert".yaml
    
    # Remove namespace and resourceVersion from the YAML
    sed -i '/namespace: traefik-system/d' /tmp/"$cert".yaml
    sed -i '/resourceVersion:/d' /tmp/"$cert".yaml
    sed -i '/uid:/d' /tmp/"$cert".yaml
    sed -i '/creationTimestamp:/d' /tmp/"$cert".yaml
    
    # Apply to default namespace
    kubectl apply -f /tmp/"$cert".yaml -n default
    
    # Clean up temp file
    rm /tmp/"$cert".yaml
    
    echo "✅ Copied $cert to default namespace"
done

echo "🎉 All external website SSL certificates copied successfully!"
echo ""
echo "Next steps:"
echo "1. Apply the SSL certificates: kubectl apply -f external-websites-ssl-certificates.yaml"
echo "2. Apply the updated routing: kubectl apply -f external-website-routing.yaml"
echo "3. Configure WordPress to use HTTPS URLs"
