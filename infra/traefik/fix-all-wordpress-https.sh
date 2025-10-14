#!/bin/bash

# Fix WordPress HTTPS configuration for all external websites
# This script configures all WordPress sites to use HTTPS URLs instead of HTTP

echo "🔧 Fixing WordPress HTTPS configuration for all external websites..."

# Switch to media context where WordPress sites are running
echo "🔄 Switching to media context..."
kubectl config use-context media

# List of WordPress sites to fix
sites=(
    "createsleeprepeat:createsleeprepeat.ca"
    "echoandflow:echoandflow.ca"
    "emc2-build:emc2.build"
    "kdds:kamloopsdentalsociety.com"
)

# Fix each WordPress site
for site_info in "${sites[@]}"; do
    IFS=':' read -r namespace domain <<< "$site_info"
    
    echo "🔧 Fixing WordPress HTTPS for $domain in namespace $namespace..."
    
    # Get the WordPress pod name
    POD_NAME=$(kubectl get pods -n $namespace -l app=wordpress -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$POD_NAME" ]; then
        echo "❌ Error: WordPress pod not found in $namespace namespace"
        continue
    fi
    
    echo "📦 Found WordPress pod: $POD_NAME"
    
    # Configure WordPress to use HTTPS
    echo "🔧 Configuring WordPress to use HTTPS URLs for $domain..."
    
    # Update WordPress site URL and home URL to use HTTPS
    kubectl exec -n $namespace $POD_NAME -- wp option update siteurl https://$domain --allow-root
    kubectl exec -n $namespace $POD_NAME -- wp option update home https://$domain --allow-root
    
    # Search and replace HTTP URLs with HTTPS URLs in the database
    echo "🔄 Replacing HTTP URLs with HTTPS URLs in WordPress database for $domain..."
    kubectl exec -n $namespace $POD_NAME -- wp search-replace http://$domain https://$domain --all-tables --allow-root
    
    # Update WordPress configuration to force HTTPS
    echo "🔒 Adding HTTPS enforcement to WordPress configuration for $domain..."
    kubectl exec -n $namespace $POD_NAME -- sh -c 'echo "if (isset(\$_SERVER[\"HTTP_X_FORWARDED_PROTO\"]) && \$_SERVER[\"HTTP_X_FORWARDED_PROTO\"] === \"https\") { \$_SERVER[\"HTTPS\"] = \"on\"; }" >> /var/www/html/wp-config.php'
    
    # Clear any caches
    echo "🧹 Clearing WordPress caches for $domain..."
    kubectl exec -n $namespace $POD_NAME -- wp cache flush --allow-root
    
    echo "✅ WordPress HTTPS configuration completed for $domain!"
    echo ""
done

echo "🎉 All WordPress sites have been configured for HTTPS!"
echo ""
echo "📝 Changes made to all sites:"
echo "   - Updated site URLs to HTTPS"
echo "   - Updated home URLs to HTTPS"
echo "   - Replaced all HTTP URLs with HTTPS URLs in databases"
echo "   - Added HTTPS enforcement to wp-config.php"
echo "   - Cleared WordPress caches"
echo ""
echo "🌐 Test your websites:"
echo "   - https://createsleeprepeat.ca"
echo "   - https://echoandflow.ca"
echo "   - https://emc2.build"
echo "   - https://kamloopsdentalsociety.com"
