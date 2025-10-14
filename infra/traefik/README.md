# Traefik Ingress Controller Setup

## Overview

This directory contains the Traefik ingress controller configuration for the homelab Kubernetes cluster, including cert-manager for SSL certificate management.

## Current Status

### ✅ Working Components

- **DNS Resolution**: All domains correctly resolve to `192.168.10.90`
  - `lab.emc2.build` → `192.168.10.90`
  - `traefik.lab.emc2.build` → `192.168.10.90`
  - `sonarr.lab.emc2.build` → `192.168.10.90`
  - `*.lab.emc2.build` → `192.168.10.90`

- **Traefik Ingress Controller**: Running and responding
  - Status: `1/1 Running`
  - LoadBalancer IP: `192.168.10.90` (assigned by MetalLB)
  - Dashboard: `http://192.168.10.90:8080` ✅
  - HTTP Port 80: `http://192.168.10.90` ✅ (responds with 404)

- **Cert-Manager**: Installed and running
  - Main controller: Running
  - CA Injector: Running
  - Webhook: Running
  - ClusterIssuers: Let's Encrypt (staging/prod) and self-signed
    - Email: emcniece+lab-emc2-build@gmail.com

- **MetalLB**: LoadBalancer service working
  - IP Pool: `192.168.10.91` assigned to new Traefik (Helm)
  - Old IP: `192.168.10.90` (previous manual installation)

### ✅ Recently Fixed

1. **Domain Connectivity**: `http://lab.emc2.build` now working ✅
   - DNS resolution works correctly
   - Domain connectivity resolved
   - Traefik dashboard accessible at `http://lab.emc2.build:8080`

2. **Kubernetes Provider**: Traefik ingress routing now working ✅
   - **Solution**: Installed Traefik using Helm chart (v3.5.3)
   - **Result**: Ingress routing working perfectly
   - **Test**: `sonarr.lab.emc2.build` and `lab.emc2.build` both working
   - **New IP**: Traefik now running on `192.168.10.91`

### 🔧 Previous Troubleshooting Attempts

- **Configuration File**: Failed with both v2.10 and v3.0
- **Command Line Args**: Failed with both v2.10 and v3.0  
- **Simplified Config**: Failed with minimal Kubernetes provider config
- **✅ Helm Chart**: Successfully resolved the Kubernetes provider issue

## Network Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Network                          │
│  DNS: lab.emc2.build → 192.168.10.90                          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                    MetalLB LoadBalancer                        │
│  IP: 192.168.10.90 (assigned to Traefik service)             │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                 Traefik Ingress Controller                     │
│  Port 80: HTTP traffic                                         │
│  Port 443: HTTPS traffic                                       │
│  Port 8080: Dashboard                                          │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                Kubernetes Cluster (k3s)                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   k3s-01        │  │   k3s-02        │  │   k3s-03        │ │
│  │ 192.168.10.38   │  │ 192.168.10.39   │  │ 192.168.10.40   │ │
│  │ (Control Plane) │  │ (Control Plane) │  │ (Control Plane) │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   k3s-04        │  │   k3s-05        │  │   k3s-06        │ │
│  │ 192.168.10.41   │  │ 192.168.10.42   │  │ 192.168.10.43   │ │
│  │ (Worker)        │  │ (Worker)        │  │ (Worker)        │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## File Structure

```
./homelab/infra/traefik/
├── README.md                           # This documentation
├── cert-manager.yaml                   # Cert-manager installation
├── cluster-issuer.yaml                 # Let's Encrypt issuers (with Cloudflare DNS01)
├── cloudflare-secret.yaml              # Cloudflare API token secret
├── self-signed-issuer.yaml            # Self-signed certificates
├── test-ingress.yaml                   # Test application
├── traefik-values.yaml                 # Traefik Helm values for external routing
├── traefik-external-routing.yaml       # External routing configuration
├── home-external-routing.yaml          # Home domain routing (*.home.emc2.build)
├── external-website-routing.yaml       # External website routing
├── CLOUDFLARE_SETUP.md                 # Cloudflare DNS verification guide
└── MIGRATION_PLAN.md                   # Media server migration plan
```

**Note**: Traefik is now managed by Helm chart, so manual configuration files have been cleaned up.

## Next Steps

### 1. ✅ Traefik Installation Complete
**Solution**: Helm Chart Installation successful!

```bash
# Successfully installed with:
helm install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --set ingressClass.enabled=true \
  --set ingressClass.isDefaultClass=true
```

### 2. Current Working Status
- **Traefik Dashboard**: ✅ Working at `http://192.168.10.91:8080/dashboard/`
- **Domain Connectivity**: ✅ Working for `lab.emc2.build` (needs DNS update)
- **LoadBalancer**: ✅ Working with MetalLB (IP: 192.168.10.91)
- **Ingress Routing**: ✅ Working perfectly!
- **Test Application**: ✅ Accessible via ingress

### 3. Routing Configuration
**External Websites** (routed to media server 192.168.1.100):
- `echoandflow.ca` → Media server
- `emc2.build` → Media server  
- `kamloopsdentalsociety.com` → Media server
- `createsleeprepeat.ca` → Media server

**Home Services** (routed to media server 192.168.1.100):
- `*.home.emc2.build` → Media server

**Lab Services** (routed to homelab cluster):
- `*.lab.emc2.build` → Local Kubernetes services

### 4. SSL Certificate Setup
Configure automatic SSL certificate provisioning:
- ✅ Self-signed certificates working
- 🔧 Cloudflare DNS01 verification configured
- 📋 See `CLOUDFLARE_SETUP.md` for complete setup guide
- 🚀 Ready for Let's Encrypt production certificates

### 5. Application Deployment
Deploy applications with ingress:
- Create ingress resources for each application
- Configure subdomain routing (e.g., `sonarr.lab.emc2.build`)
- Test SSL certificate generation

## Commands

### Check Status
```bash
# Check Traefik pods
kubectl get pods -n traefik-system

# Check cert-manager pods
kubectl get pods -n cert-manager

# Check ingress resources
kubectl get ingress -A

# Check services
kubectl get services -A | grep traefik
```

### Test Connectivity
```bash
# Test direct IP access
curl -I http://192.168.10.90

# Test dashboard
curl -I http://192.168.10.91:8080/dashboard/

# Test domain (now working!)
curl -I http://lab.emc2.build
curl -I http://lab.emc2.build:8080
```

### Apply Configuration
```bash
# Apply Traefik configuration
kubectl apply -f traefik-final.yaml

# Apply cert-manager
kubectl apply -f cert-manager.yaml

# Apply test ingress
kubectl apply -f test-ingress.yaml
```

## Troubleshooting

### Common Issues

1. **Traefik Pod Crashing**
   - Check logs: `kubectl logs -n traefik-system <pod-name>`
   - Usually caused by invalid configuration in ConfigMap

2. **No Endpoints on Service**
   - Check pod labels match service selector
   - Verify pod is running and ready

3. **Domain Timeout** ✅ FIXED
   - DNS resolution works but connection fails
   - Check network routing and firewall rules
   - Test from within cluster

4. **Ingress Not Working**
   - Verify Kubernetes provider is enabled in Traefik
   - Check ingress class is set to `traefik`
   - Ensure ingress resources exist

### Logs to Check
```bash
# Traefik logs
kubectl logs -n traefik-system deployment/traefik-ingress-controller

# Cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Test app logs
kubectl logs -n test-app deployment/test-app
```

## Configuration Files

### Main Components
- **traefik-final.yaml**: Main Traefik deployment with LoadBalancer service
- **traefik-simple-config.yaml**: Working Traefik configuration (no Kubernetes provider)
- **cert-manager.yaml**: Cert-manager installation with all components
- **cluster-issuer.yaml**: Let's Encrypt and self-signed certificate issuers
- **test-ingress.yaml**: Test application with ingress configuration

### Key Features
- **LoadBalancer**: MetalLB assigns IP `192.168.10.90`
- **Dashboard**: Available at `http://192.168.10.90:8080` and `http://lab.emc2.build:8080`
- **SSL**: Cert-manager for automatic certificate management
- **Ingress**: Support for `*.lab.emc2.build` subdomains (pending Kubernetes provider)