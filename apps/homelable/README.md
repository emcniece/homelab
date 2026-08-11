# Homelable

Network diagram / infra visualization tool (https://github.com/Pouzor/homelable).
Scans configured CIDRs with `nmap`, imports Proxmox/MQTT inventory, and shows
live up/down status.

## Deploy

```sh
kubectl apply -f apps/homelable/
```

Then edit `03-backend-secret.yaml` with real values (`SECRET_KEY`,
`AUTH_PASSWORD_HASH`, MCP keys, Proxmox token if used) and re-apply.

## Networking model

This runs with **standard pod networking**, not `hostNetwork`. The backend
container gets the `NET_RAW` capability (matching upstream's own
docker-compose setup) so `nmap`/ping work without needing the pod on the
host's network namespace. Outbound scans reach other subnets exactly the way
any other pod's outbound traffic does: SNAT'd through the node, then routed
by your router/firewall like traffic from any other LAN client.

**This only works for a CIDR if the cluster nodes (192.168.10.0/24) can
already route to it.** Before adding a VLAN to `SCANNER_RANGES` in
`02-backend-configmap.yaml`, verify routing from inside the cluster:

```sh
kubectl run netcheck --rm -it --restart=Never --image=nicolaka/netshoot \
  -n homelable -- sh -c "ping -c2 <target-ip-on-that-vlan> && nc -zv <target-ip> <port>"
```

If that fails, the gap is your router/firewall's inter-VLAN rules, not
Kubernetes — adding `hostNetwork: true` to the backend Deployment won't help
unless the *node itself* is multi-homed onto that VLAN (extra NIC/tag) or the
node can already reach it too. Fix routing/firewall rules for the node subnet
first; only reach for `hostNetwork` if scanning needs L2-only discovery
(broadcast/ARP/mDNS), which Homelable's nmap/ping/HTTP checks don't.

## Notes

- The frontend's nginx hardcodes `proxy_pass http://backend:8000`, so the
  backend Service must keep the name `backend` in this namespace.
- `backend-data` PVC uses `csi-rbd-sc` (single-instance app config, matches
  this repo's convention — see `apps/README.md`).
- MCP server is ClusterIP-only for now; give it its own Ingress if you want
  external AI-client access to it.
