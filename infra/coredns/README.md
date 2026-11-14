# CoreDNS overrides

`coredns-custom.yaml` adds server blocks to k3s's bundled CoreDNS. The
`reload` plugin picks up changes within about 30 seconds; no restart is
needed.

```sh
kubectl apply -f infra/coredns/coredns-custom.yaml
```

Currently it sends `lab.emc2.build` to Cloudflare instead of the UDM, whose
wildcard answer for `*.lab.emc2.build` hijacked search-path lookups like
`github.com.lab.emc2.build`. See the comment in the file and the "DNS Model"
page on docs.emc2.build.

Check from a pod:

```sh
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- \
  nslookup github.com.lab.emc2.build   # expect NXDOMAIN
```

## Replicas and disruption budget

CoreDNS runs **3 replicas** (since 2026-11-13). k3s's spread constraint puts
them on separate nodes (today k3s-01/02/03). `coredns-pdb.yaml` lets a drain
evict only one at a time, so node upgrades never take cluster DNS down.

```sh
kubectl -n kube-system scale deploy coredns --replicas=3
kubectl apply -f infra/coredns/coredns-pdb.yaml
```

The replica count isn't in a manifest here: k3s owns the Deployment
(`/var/lib/rancher/k3s/server/manifests/coredns.yaml`), but that manifest
doesn't set `replicas`, so k3s's reconcile leaves the scaled count alone. If
the Deployment is ever deleted and recreated (e.g. a k3s reinstall), it comes
back at 1; re-run the scale command.
