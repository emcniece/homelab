# Navidrome

**Being retired (2026-11-10).** Aurral's built-in Subsonic server replaces
it; `music.emc2.build` now points at Aurral (`apps/aurral/public.yaml`).
Navidrome is LAN-only until it's scaled to zero and removed.

Music server (Subsonic API) for the household. It reads, read-only:

- Library 1, `/downloads/music`: the music Lidarr manages (`media-library`
  volume, `music/` subPath).
- Library 2, `/downloads/aurral`: Aurral's Downloads Folder, where Weekly
  Flow tracks land (`music-discovery` volume). Added in Settings →
  Libraries.

These are the same container paths Lidarr, Aurral and slskd use. Aurral
publishes playlists by file path, so don't change them in only one app.

| Host | Routes | Reached via |
|---|---|---|
| `navidrome.lab.emc2.build` | everything (web UI, admin, API) | LAN, Traefik 192.168.10.91 |

Clients (Symfonium): `https://navidrome.lab.emc2.build`, LAN only.

## Deploy

```sh
kubectl --context homelab apply -f apps/navidrome/
```

DNS: `navidrome` is in `local.lab_hosts` in `infra/cloudflare/`.

The first login on the web UI creates the admin user. After that, create the
regular users (`eric`, `mel`) under Settings → Users.

## Security notes

- **`ExtAuth.TrustedSources` is deliberately unset.** In Navidrome it does two
  things: it makes Navidrome trust X-Forwarded-For / X-Real-IP from the listed
  proxies, *and* it turns on header login (`Remote-User`), which
  auto-creates users. Traefik forwards client headers, so setting it to the
  pod CIDR would let any client log in as anyone. As a result Navidrome logs
  Traefik's pod IP as the client. Use Traefik's access log for real IPs.

## Storage

- `navidrome-data` (RBD, RWO): SQLite DB, caches, `/data/plugins`. Hence the
  `Recreate` strategy.
- Both Ceph CSI drivers have `fsGroupPolicy: File` (recursive chown on mount).
  The library volume is `readOnly` at the volume level so it's skipped, and
  `fsGroupChangePolicy: OnRootMismatch` is a second guard. Don't drop either.
