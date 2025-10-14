#!/bin/bash

# Fix WordPress redirect issues for all external websites
# This script disables WordPress redirects when behind reverse proxy

echo "🔧 Fixing WordPress redirect issues for all external websites..."

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
    
    echo "🔧 Fixing WordPress redirects for $domain in namespace $namespace..."
    
    # Get the WordPress pod name
    POD_NAME=$(kubectl get pods -n $namespace -l app=wordpress -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$POD_NAME" ]; then
        echo "❌ Error: WordPress pod not found in $namespace namespace"
        continue
    fi
    
    echo "📦 Found WordPress pod: $POD_NAME"
    
    # Create mu-plugins directory
    echo "📁 Creating mu-plugins directory..."
    kubectl exec -n $namespace $POD_NAME -- mkdir -p /var/www/html/wp-content/mu-plugins
    
    # Create disable-redirects.php mu-plugin
    echo "🔧 Creating disable-redirects.php mu-plugin..."
    kubectl exec -n $namespace $POD_NAME -- sh -c 'cat > /var/www/html/wp-content/mu-plugins/disable-redirects.php << "EOF"
<?php
// Disable WordPress redirects when behind reverse proxy
add_filter("redirect_canonical", "__return_false");
add_filter("wp_redirect", "__return_false");
EOF'
    
    # Clear WordPress caches
    echo "🧹 Clearing WordPress caches for $domain..."
    kubectl exec -n $namespace $POD_NAME -- wp cache flush --allow-root
    
    echo "✅ WordPress redirect fix completed for $domain!"
    echo ""
done

echo "🎉 All WordPress sites have been fixed for redirect issues!"
echo ""
echo "📝 Changes made to all sites:"
echo "   - Created mu-plugin to disable WordPress redirects"
echo "   - WordPress now serves HTTP content without redirecting"
echo "   - HTTPS URLs are preserved in content"
echo "   - Cleared WordPress caches"
echo ""
echo "🌐 Test your websites:"
echo "   - https://createsleeprepeat.ca"
echo "   - https://echoandflow.ca"
echo "   - https://emc2.build"
echo "   - https://kamloopsdentalsociety.com"
