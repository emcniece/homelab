# Homelab

## Recent Changes (October 2025)

### ✅ Home.emc2.build Services Configuration
- **SSL Certificates**: All `*.home.emc2.build` domains now have valid Let's Encrypt certificates
- **Authentication**: Organizr authentication middleware configured for all services
- **Public Access**: `home.emc2.build` (Organizr) is publicly accessible
- **Protected Services**: All other `*.home.emc2.build` services require authentication
- **Routing**: Homelab cluster → Media cluster → Services

### 📁 Configuration Files
- `infra/traefik/HOME_EMC2_BUILD_SETUP.md` - Complete setup guide
- `infra/traefik/home-emc2-build-ssl-certificates.yaml` - SSL certificates
- `infra/traefik/home-emc2-build-ingresses-with-tls.yaml` - Ingress resources
- `infra/traefik/home-emc2-build-services.yaml` - ExternalName services
- `infra/traefik/copy-ssl-certificates-to-default.sh` - Certificate copy script

### 🔧 Media Cluster Changes
- `media-srv-apps/media/MEDIA_CLUSTER_AUTH_SETUP.md` - Authentication setup guide
- Organizr authentication middleware configured for all services
- SSL certificates working for all domains

## Deploy Automation

Roles and resources must be configured in the cluster before Github Actions can be used:

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl apply -f ci/gh_actions/
```

Inspiration: https://nicwortel.nl/blog/2022/continuous-deployment-to-kubernetes-with-github-actions
