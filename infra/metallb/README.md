# MetalLB Configuration

MetalLB provides LoadBalancer services for bare-metal Kubernetes clusters. This cluster uses **Layer 2 mode** for VIP management.

## Current Configuration

### IP Address Pool
- **Range**: 192.168.10.90 - 192.168.10.110
- **Name**: `first-pool`
- **Auto-assign**: Enabled

### L2 Advertisement
- **Interface**: `eth0` (main network interface on k3s nodes)
- **Mode**: Layer 2 (ARP-based)
- **File**: [l2advertisement.yaml](./l2advertisement.yaml)

Apply with:
```bash
kubectl apply -f homelab/infra/metallb/l2advertisement.yaml
```

## Services Using MetalLB

### Traefik LoadBalancer
- **VIP**: 192.168.10.91
- **Service**: `traefik` in `traefik-system` namespace
- **Traffic Policy**: `Local` (only nodes with Traefik pod respond)
- **Ports**: 80 (HTTP), 443 (HTTPS), 8080 (Dashboard)

## October 14, 2025: VIP Failover Optimization

### Issue
During pve2 reboot testing, the VIP (192.168.10.91) did not fail over properly because:
1. Default Kubernetes pod eviction timeout is **5 minutes** for NotReady nodes
2. Network switches/routers can be slow to update ARP cache in Layer 2 mode
3. Traefik was using default `externalTrafficPolicy: Cluster` (all nodes respond, inefficient)

### Solution Implemented

#### 1. externalTrafficPolicy: Local
```bash
kubectl patch svc traefik -n traefik-system -p '{"spec":{"externalTrafficPolicy":"Local"}}'
```

**Benefits:**
- ✅ Only nodes with Traefik pod respond to traffic
- ✅ Source IP preservation (applications see real client IP)
- ✅ Faster failover (health checks automatically remove failed nodes)
- ✅ No extra hop through kube-proxy

#### 2. L2Advertisement Interface Specification
```yaml
spec:
  interfaces:
    - eth0
  ipAddressPools:
    - first-pool
```

**Benefits:**
- ✅ Ensures gratuitous ARP is sent on the correct interface
- ✅ Prevents issues with multiple network interfaces
- ✅ More predictable failover behavior

### Failover Behavior

**Expected Timeline:**
1. Node with Traefik goes down → pod becomes unavailable
2. Kubernetes reschedules Traefik to another node → **~5-15 seconds**
3. MetalLB speaker on new node announces VIP → **~2-5 seconds**
4. Network devices update ARP cache → **~5-10 seconds**
5. **Total downtime: 10-30 seconds**

**Failover Process:**
```
Node Failure → Pod Rescheduled → MetalLB Announces → ARP Updated → Traffic Flows
     ↓              ↓                    ↓                 ↓              ↓
   0-5s          5-15s               15-20s            20-30s         30s+
```

### Test Results (October 14, 2025)

**Test scenario**: Rebooted pve2 (hosting k3s-02 and k3s-05) while Traefik was running on k3s-05.

**Observations:**
1. ✅ Kubernetes detected node NotReady status immediately
2. ✅ Traefik pod successfully rescheduled to k3s-04 (pve1)
3. ✅ MetalLB speaker on k3s-04 took over VIP announcement
4. ✅ VIP became accessible again after pod started
5. ⚠️ Initial test had node affinity constraint that prevented automatic failover

**Lesson learned**: Never use `required` node affinity on critical LoadBalancer pods. Use `preferred` if you want to influence scheduling but allow failover.

## Layer 2 vs BGP Mode

### Current: Layer 2 Mode

**How it works:**
- One MetalLB speaker "owns" each VIP
- Speaker responds to ARP requests for the VIP
- On failure, leader election happens and new speaker sends gratuitous ARP
- Network devices update their ARP cache

**Pros:**
- ✅ Simple configuration
- ✅ Works with any network equipment
- ✅ No router configuration needed

**Cons:**
- ⚠️ Single active speaker per VIP (no load balancing)
- ⚠️ Failover depends on ARP cache timeouts (10-30s typical)
- ⚠️ No active health monitoring of speakers

### Alternative: BGP Mode

**Would require:**
- BGP-capable router (UDM Pro does NOT support BGP)
- Or BGP daemon on Proxmox hosts (FRRouting/BIRD)
- BGP AS numbers and peering configuration

**Benefits if implemented:**
- ⚡ Faster failover (1-3 seconds vs 10-30 seconds)
- 🔄 Active health monitoring via BGP keepalives
- 🌐 True load balancing across multiple nodes
- 🛡️ No ARP cache dependency

**Recommendation:** Layer 2 mode is sufficient for homelab use. The 10-30 second failover during planned maintenance is acceptable.

## Troubleshooting

### Check VIP Status
```bash
# Which node has the Traefik pod?
kubectl get pods -n traefik-system -o wide

# Is the VIP responding?
curl -I http://192.168.10.91

# Check MetalLB speaker logs
kubectl logs -n metallb-system -l component=speaker --tail=50 | grep "192.168.10.91"

# Check service endpoints
kubectl get endpoints -n traefik-system traefik
```

### Force VIP Failover
```bash
# Delete Traefik pod to trigger reschedule
kubectl delete pod -n traefik-system -l app.kubernetes.io/name=traefik

# Watch it reschedule
kubectl get pods -n traefik-system -o wide --watch
```

### Monitor During Failover
```bash
# Terminal 1: Continuous ping
ping 192.168.10.91

# Terminal 2: Watch pods
watch -n 1 'kubectl get pods -n traefik-system -o wide'

# Terminal 3: MetalLB events
kubectl logs -n metallb-system -l component=speaker --tail=20 --follow
```

## Configuration Files

- **L2Advertisement**: [l2advertisement.yaml](./l2advertisement.yaml)
- **IP Pool**: Configured via MetalLB Helm chart or ConfigMap
- **Traefik Service**: Uses `externalTrafficPolicy: Local`

## References

- [MetalLB Layer 2 Documentation](https://metallb.universe.tf/concepts/layer2/)
- [Kubernetes externalTrafficPolicy](https://kubernetes.io/docs/tasks/access-application-cluster/create-external-load-balancer/#preserving-the-client-source-ip)
- [MetalLB Speaker Logs](https://metallb.universe.tf/troubleshooting/)

