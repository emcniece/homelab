#!/bin/bash

# Fix WordPress HTTPS configuration for createsleeprepeat.ca
# This script configures WordPress to use HTTPS URLs instead of HTTP

echo "🔧 Fixing WordPress HTTPS configuration for createsleeprepeat.ca..."

# Switch to media context where WordPress is running
echo "🔄 Switching to media context..."
kubectl config use-context media

# Get the WordPress pod name
POD_NAME=$(kubectl get pods -n createsleeprepeat -l app=wordpress -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "❌ Error: WordPress pod not found in createsleeprepeat namespace"
    echo "💡 Make sure you're in the correct Kubernetes context (media)"
    exit 1
fi

echo "📦 Found WordPress pod: $POD_NAME"

# Configure WordPress to use HTTPS
echo "🔧 Configuring WordPress to use HTTPS URLs..."

# Update WordPress site URL and home URL to use HTTPS
kubectl exec -n createsleeprepeat $POD_NAME -- wp option update siteurl https://createsleeprepeat.ca --allow-root
kubectl exec -n createsleeprepeat $POD_NAME -- wp option update home https://createsleeprepeat.ca --allow-root

# Search and replace HTTP URLs with HTTPS URLs in the database
echo "🔄 Replacing HTTP URLs with HTTPS URLs in WordPress database..."
kubectl exec -n createsleeprepeat $POD_NAME -- wp search-replace http://createsleeprepeat.ca https://createsleeprepeat.ca --all-tables --allow-root

# Update WordPress configuration to force HTTPS
echo "🔒 Adding HTTPS enforcement to WordPress configuration..."
kubectl exec -n createsleeprepeat $POD_NAME -- sh -c 'echo "if (isset(\$_SERVER[\"HTTP_X_FORWARDED_PROTO\"]) && \$_SERVER[\"HTTP_X_FORWARDED_PROTO\"] === \"https\") { \$_SERVER[\"HTTPS\"] = \"on\"; }" >> /var/www/html/wp-config.php'

# Clear any caches
echo "🧹 Clearing WordPress caches..."
kubectl exec -n createsleeprepeat $POD_NAME -- wp cache flush --allow-root

echo "✅ WordPress HTTPS configuration completed!"
echo ""
echo "🎉 The website should now work properly with HTTPS!"
echo "📝 Changes made:"
echo "   - Updated site URL to https://createsleeprepeat.ca"
echo "   - Updated home URL to https://createsleeprepeat.ca"
echo "   - Replaced all HTTP URLs with HTTPS URLs in database"
echo "   - Added HTTPS enforcement to wp-config.php"
echo "   - Cleared WordPress caches"
echo ""
echo "🌐 Test the website at: https://createsleeprepeat.ca"
