# Home Assistant

Routes `https://ha.lab.emc2.build` through traefik to Home Assistant, which
runs outside the cluster at `192.168.10.10:8123`.

`ha.lab.emc2.build` resolves locally via the UniFi `*.lab.emc2.build` record
(→ traefik VIP `192.168.10.91`). There is no public DNS record; the
certificate is issued via the Cloudflare DNS-01 solver.

## Deploy

```sh
kubectl apply -f apps/home-assistant/
```

## Home Assistant config

HA rejects proxied requests (HTTP 400) unless traefik is trusted. In
`configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.42.0.0/16   # k3s pod network
```
