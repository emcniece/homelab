# Traefik Configuration TODO

## 2025-12-13 - Traefik Configuration Fixes

### Issues Resolved

1. **Removed `acme-json-certs` PVC Requirement**
   - Disabled persistence in Traefik Helm values (`persistence.enabled: false`)
   - Removed ACME/Cloudflare DNS challenge configuration (not needed with cert-manager)
   - Removed init container that was setting permissions on `/certs`
   - **Reason**: Using cert-manager for certificate management, so Traefik's built-in ACME is redundant

2. **Fixed Port Configuration**
   - Patched deployment to use container ports 80/443 instead of default 8000/8443
   - Updated entrypoints to listen on :80 and :443
   - Fixed service port mapping to use named ports correctly
   - **Note**: The container port override in `traefik-values-clean.yaml` may need adjustment based on Helm chart version

3. **Restored Ingress Class Configuration**
   - Added `kubernetesIngress.ingressClass: traefik` to ensure Traefik processes ingresses
   - Configured `kubernetesIngress.publishedService.enabled: true`
   - **Reason**: Without ingress class specification, Traefik wasn't processing ingress resources

4. **Fixed Provider Configuration**
   - Corrected Traefik v3 provider syntax (removed invalid `--providers.kubernetes` flag)
   - Used proper `kubernetesIngress` and `kubernetescrd` providers
   - **Reason**: Traefik v3 split the kubernetes provider into separate ingress and CRD providers

### Current Configuration

- **File**: `traefik-values-clean.yaml`
- **Certificate Management**: cert-manager (not Traefik's built-in ACME)
- **Persistence**: Disabled
- **Container Ports**: 80, 443, 8080, 9100
- **Entrypoints**: web (:80), websecure (:443), traefik (:8080)

### Status

✅ Traefik pod running without PVC requirement
✅ Websites accessible over HTTPS
✅ Ingress processing working correctly
✅ Endpoints showing correct ports (80/443)

### Next Steps (Optional)

- [ ] Add HTTP to HTTPS redirect configuration if needed
- [ ] Verify container port configuration persists across Helm upgrades
- [ ] Test all websites to confirm accessibility
- [ ] Consider adding HTTP redirect middleware for better security

### Files Modified

- `/Users/emcniece/code/homelab/homelab/infra/traefik/traefik-values-clean.yaml` - Clean Traefik configuration without ACME
- `/Users/emcniece/code/homelab/homelab/infra/traefik/dashboard-ingressroute.yaml` - Dashboard IngressRoute (created earlier)

### Deployment Command

```bash
helm upgrade traefik traefik/traefik -n traefik-system -f homelab/infra/traefik/traefik-values-clean.yaml
```

**Note**: The container ports were patched directly on the deployment. To make this permanent, ensure the `deployment.containers` section in the values file works with your Helm chart version, or apply the patch after each Helm upgrade.

