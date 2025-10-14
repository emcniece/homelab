# External Websites HTTPS Setup

This guide documents the configuration for external websites (createsleeprepeat.ca, echoandflow.ca, emc2.build, kamloopsdentalsociety.com) to use HTTPS with SSL termination at the homelab cluster level.

## Problem

The external websites were experiencing mixed content issues because:
1. SSL termination was happening at the homelab cluster level
2. WordPress was configured to use HTTP URLs
3. Browsers were blocking HTTP resources when the page was served over HTTPS

## Solution

The solution involves:
1. **SSL Certificates**: Create Let's Encrypt certificates for all external domains
2. **TLS Configuration**: Add TLS configuration to ingress resources
3. **WordPress HTTPS**: Configure WordPress to use HTTPS URLs
4. **URL Replacement**: Replace all HTTP URLs with HTTPS URLs in the database

## Files Created

### 1. SSL Certificates
- **File**: `external-websites-ssl-certificates.yaml`
- **Purpose**: Creates Let's Encrypt certificates for all external domains
- **Namespace**: `traefik-system`

### 2. Certificate Copy Script
- **File**: `copy-external-website-ssl-certificates.sh`
- **Purpose**: Copies certificates from `traefik-system` to `default` namespace
- **Reason**: Homelab cluster's Traefik reads certificates from `default` namespace

### 3. WordPress HTTPS Fix
- **File**: `fix-wordpress-https.sh`
- **Purpose**: Configures WordPress to use HTTPS URLs
- **Actions**:
  - Updates site URL and home URL to HTTPS
  - Replaces HTTP URLs with HTTPS URLs in database
  - Adds HTTPS enforcement to wp-config.php
  - Clears WordPress caches

### 4. Complete Setup Script
- **File**: `setup-external-websites-https.sh`
- **Purpose**: Orchestrates the entire HTTPS setup process
- **Steps**:
  1. Apply SSL certificates
  2. Copy certificates to default namespace
  3. Apply updated routing with TLS
  4. Configure WordPress for HTTPS

## Setup Instructions

### Prerequisites
- Homelab cluster running with Traefik and cert-manager
- Media cluster running with WordPress and services
- DNS configured for external domains → homelab cluster IP

### Quick Setup
```bash
# Run the complete setup script
./setup-external-websites-https.sh
```

### Manual Setup
```bash
# Step 1: Apply SSL certificates
kubectl apply -f external-websites-ssl-certificates.yaml

# Step 2: Copy certificates to default namespace
./copy-external-website-ssl-certificates.sh

# Step 3: Apply updated routing with TLS
kubectl apply -f external-website-routing.yaml

# Step 4: Configure WordPress for HTTPS
./fix-wordpress-https.sh
```

## Architecture

```
Internet → Public IP → UDM Pro → Homelab Cluster (SSL Termination) → Media Cluster → WordPress
```

### Routing Flow
1. **DNS**: External domains resolve to homelab cluster IP
2. **Homelab Cluster**: SSL termination with Let's Encrypt certificates
3. **Media Cluster**: WordPress with HTTPS URLs configured
4. **WordPress**: All resources served over HTTPS

## Configuration Details

### SSL Certificates
- **Provider**: Let's Encrypt
- **Issuer**: `letsencrypt-prod` ClusterIssuer
- **Domains**: createsleeprepeat.ca, echoandflow.ca, emc2.build, kamloopsdentalsociety.com
- **Namespace**: `traefik-system` (copied to `default`)

### Ingress Configuration
- **Entry Point**: `websecure` (HTTPS only)
- **TLS**: Automatic certificate resolution
- **Backend**: ExternalName services pointing to media cluster (192.168.1.100:443)

### WordPress Configuration
- **Site URL**: https://createsleeprepeat.ca
- **Home URL**: https://createsleeprepeat.ca
- **Database**: All HTTP URLs replaced with HTTPS URLs
- **HTTPS Enforcement**: Added to wp-config.php

## Troubleshooting

### Mixed Content Errors
If you still see mixed content errors:
1. Clear browser cache
2. Hard refresh the page (Ctrl+F5 or Cmd+Shift+R)
3. Check browser console for any remaining HTTP resources
4. Verify WordPress configuration

### WordPress Configuration
```bash
# Check current WordPress configuration
kubectl exec -n createsleeprepeat <pod-name> -- wp option get siteurl --allow-root
kubectl exec -n createsleeprepeat <pod-name> -- wp option get home --allow-root

# Re-run HTTPS configuration if needed
./fix-wordpress-https.sh
```

### SSL Certificate Status
```bash
# Check certificate status
kubectl get certificates -n traefik-system
kubectl describe certificate createsleeprepeat-ca-letsencrypt-tls -n traefik-system

# Check certificate in default namespace
kubectl get secrets -n default | grep letsencrypt-tls
```

### Ingress Status
```bash
# Check ingress configuration
kubectl get ingress -n default
kubectl describe ingress createsleeprepeat-ca-routing -n default
```

## Testing

After setup, test the websites:
- https://createsleeprepeat.ca
- https://echoandflow.ca
- https://emc2.build
- https://kamloopsdentalsociety.com

All websites should load without mixed content errors and show the green lock icon in the browser.
