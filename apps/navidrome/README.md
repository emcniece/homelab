# Navidrome

Music server (Subsonic API) for the household. It reads the music Lidarr
manages, from the shared `media-library` CephFS volume (`/downloads/music` in
Lidarr is `/music` here), read-only.

| Host | Routes | Reached via |
|---|---|---|
| `navidrome.lab.emc2.build` | everything (web UI, admin, API) | LAN, Traefik 192.168.10.91 |
| `music.emc2.build` | `/rest` (Subsonic API) and `/share` only | Cloudflare proxy → home IP → Traefik |

Clients (Symfonium): primary `https://navidrome.lab.emc2.build`, alternate
`https://music.emc2.build`.

## Deploy

```sh
kubectl --context homelab apply -f apps/navidrome/
```

DNS: `navidrome` is in `local.lab_hosts` and `music` is
`cloudflare_dns_record.music` in `infra/cloudflare/` (`terraform apply` there).

The first login on the web UI creates the admin user. After that, create the
regular users (`eric`, `mel`) under Settings → Users.

## Security notes

- **Public host is Cloudflare-only.** The zone has a DNS-only `*.emc2.build`
  CNAME that resolves any name to the home IP, so the origin is reachable
  without Cloudflare. The public router therefore allows only Cloudflare's IP
  ranges (`navidrome-cloudflare-only`), and rate-limits per
  `CF-Connecting-IP`, which can't be spoofed once the allowlist is in place.
- **`ExtAuth.TrustedSources` is deliberately unset.** In Navidrome it does two
  things: it makes Navidrome trust X-Forwarded-For / X-Real-IP from the listed
  proxies, *and* it turns on header login (`Remote-User`), which
  auto-creates users. Traefik forwards client headers, so setting it to the
  pod CIDR would let any client log in as anyone. As a result Navidrome logs
  Traefik's pod IP as the client. Use Traefik's access log for real IPs.
- Subsonic logins are password-based and the API is internet-facing: use
  strong, unique passwords.

## Storage

- `navidrome-data` (RBD, RWO): SQLite DB, caches, `/data/plugins`. Hence the
  `Recreate` strategy.
- Both Ceph CSI drivers have `fsGroupPolicy: File` (recursive chown on mount).
  The library volume is `readOnly` at the volume level so it's skipped, and
  `fsGroupChangePolicy: OnRootMismatch` is a second guard. Don't drop either.
