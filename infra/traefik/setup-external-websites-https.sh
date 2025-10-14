#!/bin/bash

# Setup HTTPS for external websites
# This script applies SSL certificates and configures WordPress for HTTPS

echo "🚀 Setting up HTTPS for external websites..."

# Step 1: Apply SSL certificates
echo "📜 Step 1: Applying SSL certificates..."
kubectl apply -f external-websites-ssl-certificates.yaml

# Wait for certificates to be ready
echo "⏳ Waiting for SSL certificates to be ready..."
kubectl wait --for=condition=Ready certificate/createsleeprepeat-ca-letsencrypt-tls -n traefik-system --timeout=300s
kubectl wait --for=condition=Ready certificate/echoandflow-ca-letsencrypt-tls -n traefik-system --timeout=300s
kubectl wait --for=condition=Ready certificate/emc2-build-letsencrypt-tls -n traefik-system --timeout=300s
kubectl wait --for=condition=Ready certificate/kamloopsdentalsociety-com-letsencrypt-tls -n traefik-system --timeout=300s

# Step 2: Copy certificates to default namespace
echo "📋 Step 2: Copying SSL certificates to default namespace..."
./copy-external-website-ssl-certificates.sh

# Step 3: Apply updated routing with TLS
echo "🛣️  Step 3: Applying updated routing with TLS configuration..."
kubectl apply -f external-website-routing.yaml

# Step 4: Fix WordPress HTTPS configuration
echo "🔧 Step 4: Configuring WordPress for HTTPS..."
./fix-wordpress-https.sh

echo ""
echo "🎉 HTTPS setup completed for external websites!"
echo ""
echo "📋 Summary of changes:"
echo "   ✅ SSL certificates created and applied"
echo "   ✅ TLS configuration added to ingress resources"
echo "   ✅ WordPress configured to use HTTPS URLs"
echo "   ✅ HTTP to HTTPS URL replacement completed"
echo ""
echo "🌐 Test your websites:"
echo "   - https://createsleeprepeat.ca"
echo "   - https://echoandflow.ca"
echo "   - https://emc2.build"
echo "   - https://kamloopsdentalsociety.com"
echo ""
echo "🔍 If you still see mixed content errors, try:"
echo "   1. Clear your browser cache"
echo "   2. Hard refresh the page (Ctrl+F5 or Cmd+Shift+R)"
echo "   3. Check browser console for any remaining HTTP resources"
