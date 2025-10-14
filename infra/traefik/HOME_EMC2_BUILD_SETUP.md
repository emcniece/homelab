# Home.emc2.build Setup Guide

This guide documents the configuration for `*.home.emc2.build` domains that route from the homelab cluster to the media cluster with Organizr authentication.

## Overview

The `*.home.emc2.build` domains are configured with:
- **SSL Certificates**: Let's Encrypt certificates for all domains
- **Authentication**: Organizr authentication middleware (configured in media cluster)
- **Public Access**: `home.emc2.build` (Organizr) is publicly accessible
- **Protected Services**: All other `*.home.emc2.build` services require authentication

## Architecture

```
Internet → Public IP → UDM Pro → Homelab Cluster → Media Cluster → Services
```

### Routing Flow
1. **DNS**: `*.home.emc2.build` resolves to homelab cluster IP (`192.168.10.91`)
2. **Homelab Cluster**: Routes traffic to media cluster (`192.168.1.100`)
3. **Media Cluster**: Applies Organizr authentication and routes to services
4. **Services**: Plex, Sonarr, Radarr, etc. with authentication required

## Configuration Files

### 1. SSL Certificates
- **File**: `home-emc2-build-ssl-certificates.yaml`
- **Purpose**: Creates Let's Encrypt certificates for all domains
- **Namespace**: `traefik-system`

### 2. Services
- **File**: `home-emc2-build-services.yaml`
- **Purpose**: ExternalName services routing to media cluster
- **Namespace**: `default`

### 3. Ingresses with TLS
- **File**: `home-emc2-build-ingresses-with-tls.yaml`
- **Purpose**: Ingress resources with TLS configuration
- **Namespace**: `default`

### 4. Certificate Copy Script
- **File**: `copy-ssl-certificates-to-default.sh`
- **Purpose**: Copies certificates from `traefik-system` to `default` namespace
- **Reason**: Homelab cluster's Traefik reads certificates from `default` namespace

## Setup Instructions

### Prerequisites
- Homelab cluster running with Traefik and cert-manager
- Media cluster running with Organizr and services
- DNS configured for `*.home.emc2.build` → homelab cluster IP

### Step 1: Apply SSL Certificates
```bash
kubectl apply -f home-emc2-build-ssl-certificates.yaml
```

### Step 2: Wait for Certificate Issuance
```bash
# Check certificate status
kubectl get certificate -n traefik-system | grep "home.emc2.build"

# Wait for all certificates to show "True" status
```

### Step 3: Copy Certificates to Default Namespace
```bash
./copy-ssl-certificates-to-default.sh
```

### Step 4: Apply Services
```bash
kubectl apply -f home-emc2-build-services.yaml
```

### Step 5: Apply Ingresses with TLS
```bash
kubectl apply -f home-emc2-build-ingresses-with-tls.yaml
```

### Step 6: Configure Media Cluster Authentication
The media cluster needs to have Organizr authentication middleware configured on its ingresses. This is done in the media cluster, not the homelab cluster.

## Verification

### Test Public Access (Organizr)
```bash
curl -I https://home.emc2.build
# Should return: HTTP/2 200
```

### Test Protected Services
```bash
curl -I https://plex.home.emc2.build
# Should return: HTTP/2 401 (authentication required)

curl -I https://sonarr.home.emc2.build
# Should return: HTTP/2 401 (authentication required)
```

## Troubleshooting

### SSL Certificate Issues
- Check certificate status: `kubectl get certificate -n traefik-system`
- Check certificate requests: `kubectl get certificaterequest -n traefik-system`
- Check challenges: `kubectl get challenge -n traefik-system`

### Authentication Issues
- Verify Organizr is running in media cluster
- Check media cluster ingresses have authentication middleware
- Test Organizr endpoint: `curl -I http://192.168.1.100/api/v2/auth/1`

### Routing Issues
- Check homelab cluster ingresses: `kubectl get ingress -n default`
- Check services: `kubectl get service -n default`
- Check Traefik logs: `kubectl logs -n traefik-system deployment/traefik`

## Current Status

### ✅ Working Domains
- `https://home.emc2.build/` - Organizr (public access)
- `https://plex.home.emc2.build/` - Plex (auth required)
- `https://sonarr.home.emc2.build/` - Sonarr (auth required)
- `https://radarr.home.emc2.build/` - Radarr (auth required)
- `https://lidarr.home.emc2.build/` - Lidarr (auth required)
- `https://deluge.home.emc2.build/` - Deluge (auth required)
- `https://sabnzbd.home.emc2.build/` - Sabnzbd (auth required)
- `https://plexpy.home.emc2.build/` - PlexPy (auth required)
- `https://emby.home.emc2.build/` - Emby (auth required)

### 🔧 Configuration Details
- **SSL**: Let's Encrypt certificates for all domains
- **Authentication**: Organizr middleware in media cluster
- **Routing**: Homelab → Media cluster → Services
- **Access Control**: Public Organizr, protected services

## Notes

- The authentication middleware is configured in the **media cluster**, not the homelab cluster
- SSL certificates are created in `traefik-system` namespace but copied to `default` namespace
- All services route through the media cluster's Traefik for authentication
- Organizr must be running and accessible in the media cluster
