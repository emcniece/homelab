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
