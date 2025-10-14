# Media Server to Homelab Migration Plan

## 🎯 **Objective**
Migrate all services from media server (192.168.1.100) to homelab cluster (192.168.10.91) and use homelab Traefik as the central reverse proxy.

## 🏗️ **Target Architecture**

```
Internet → UDM Pro (Port 80/443) → Homelab Traefik (192.168.10.91)
Homelab Traefik → Routes to:
  - *.home.emc2.build → External services (temporarily)
  - *.lab.emc2.build → Local Kubernetes services
```

## 📋 **Migration Steps**

### **Phase 1: Configure Homelab as Reverse Proxy**

1. **Update Traefik Configuration**
   ```bash
   # Update Traefik to use standard ports
   helm upgrade traefik traefik/traefik \
     --namespace traefik-system \
     --values traefik-values.yaml
   ```

2. **Configure External Routing**
   - Create ingress resources for external services
   - Set up routing rules for *.home.emc2.build domains
   - Test routing to media server services

### **Phase 2: Migrate Services**

1. **Identify Services to Migrate**
   - List all services on media server
   - Determine which can be containerized
   - Plan migration order

2. **Create Kubernetes Manifests**
   - Convert Docker Compose to Kubernetes
   - Create ingress resources
   - Configure persistent volumes

3. **Migrate Services One by One**
   - Start with non-critical services
   - Test each service thoroughly
   - Update DNS records

### **Phase 3: Update Network Configuration**

1. **Update UDM Pro**
   - Change port forwarding from 192.168.1.100 to 192.168.10.91
   - Test external access

2. **Update DNS Records**
   - Point all domains to homelab cluster
   - Remove media server DNS entries

## 🔧 **Technical Implementation**

### **Traefik Configuration**

```yaml
# External routing for home.emc2.build domains
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: home-external-routing
  namespace: traefik-system
  annotations:
    traefik.ingress.kubernetes.io/router.rule: "Host(`*.home.emc2.build`)"
    traefik.ingress.kubernetes.io/router.service: "home-cluster"
spec:
  ingressClassName: traefik
  rules:
  - host: "*.home.emc2.build"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: home-cluster
            port:
              number: 80
```

### **Service Migration Template**

```yaml
# Example service migration
apiVersion: apps/v1
kind: Deployment
metadata:
  name: plex
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: plex
  template:
    metadata:
      labels:
        app: plex
    spec:
      containers:
      - name: plex
        image: plexinc/pms-docker:latest
        ports:
        - containerPort: 32400
        volumeMounts:
        - name: plex-data
          mountPath: /data
        - name: plex-config
          mountPath: /config
      volumes:
      - name: plex-data
        persistentVolumeClaim:
          claimName: plex-data-pvc
      - name: plex-config
        persistentVolumeClaim:
          claimName: plex-config-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: plex
  namespace: media
spec:
  selector:
    app: plex
  ports:
  - port: 32400
    targetPort: 32400
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: plex-ingress
  namespace: media
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - plex.home.emc2.build
    secretName: plex-tls
  rules:
  - host: plex.home.emc2.build
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: plex
            port:
              number: 32400
```

## 🚀 **Benefits of This Approach**

1. **Centralized Management**: Single cluster for all services
2. **Better Resource Utilization**: Shared resources across services
3. **Easier Backup**: Single backup strategy
4. **Simplified Networking**: No complex routing between clusters
5. **Cost Effective**: Single server instead of multiple

## ⚠️ **Considerations**

1. **Data Migration**: Plan for data transfer from media server
2. **Service Dependencies**: Identify inter-service dependencies
3. **Downtime**: Plan for minimal downtime during migration
4. **Testing**: Test each service thoroughly before going live
5. **Rollback Plan**: Have a rollback strategy if issues arise

## 📊 **Migration Checklist**

- [x] Configure homelab Traefik for external routing
- [x] Test routing to media server services
- [x] Configure SSL certificates for external domains
- [ ] Create Kubernetes manifests for each service
- [ ] Migrate data and configurations
- [ ] Test each service in homelab cluster
- [ ] Update DNS records
- [ ] Update UDM Pro port forwarding
- [ ] Decommission media server

## 🎉 **Recent Progress (October 14, 2025)**

### **✅ SSL Certificate Migration - COMPLETED**

**All external domains now have Let's Encrypt certificates:**

1. **emc2.build** ✅
   - Certificate: Let's Encrypt (R13)
   - Valid: Oct 14, 2025 - Jan 12, 2026
   - Auto-renewal: ✅ Configured

2. **echoandflow.ca** ✅
   - Certificate: Let's Encrypt (R13)
   - Valid: Oct 14, 2025 - Jan 12, 2026
   - Auto-renewal: ✅ Configured

3. **kamloopsdentalsociety.com** ✅
   - Certificate: Let's Encrypt (R12)
   - Valid: Oct 14, 2025 - Jan 12, 2026
   - Auto-renewal: ✅ Configured

4. **createsleeprepeat.ca** ✅
   - Certificate: Let's Encrypt (R12)
   - Valid: Oct 14, 2025 - Jan 12, 2026
   - Auto-renewal: ✅ Configured

### **🔧 Technical Implementation Details**

**Cloudflare DNS01 Challenge Configuration:**
- ✅ Cloudflare API token configured with proper zone access
- ✅ DNS01 solver configured for all domains
- ✅ Automatic certificate renewal every 90 days
- ✅ No more self-signed certificates

**Traefik Ingress Configuration:**
- ✅ All domains configured for both HTTP and HTTPS
- ✅ Let's Encrypt certificates automatically applied
- ✅ External routing to media server (192.168.1.100) working
- ✅ WordPress applications accessible via HTTPS

**Network Configuration:**
- ✅ UDM Pro port forwarding: 80/443 → 192.168.10.91
- ✅ Homelab Traefik routing external domains to media server
- ✅ All domains accessible externally with valid SSL certificates

### **🚀 Next Steps**

1. **Service Migration Planning**
   - Inventory all services on media server
   - Determine migration order and dependencies
   - Plan data migration strategy

2. **Kubernetes Manifests Creation**
   - Convert Docker Compose services to Kubernetes
   - Create persistent volume claims
   - Configure ingress resources for each service

3. **Testing and Validation**
   - Test each service in homelab cluster
   - Validate SSL certificate generation
   - Performance testing and optimization

## 🔍 **Testing Strategy**

1. **Internal Testing**: Test services within homelab cluster
2. **External Testing**: Test external access via UDM Pro
3. **SSL Testing**: Verify certificate generation and HTTPS
4. **Performance Testing**: Ensure performance is acceptable
5. **Backup Testing**: Verify backup and restore procedures
