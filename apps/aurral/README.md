# Aurral

Music discovery and requests. It runs the Weekly Flow (single tracks from
slskd), imports Spotify playlists, and hands albums to Lidarr.

- UI: `https://aurral.lab.emc2.build` (LAN only; the web UI is never
  public). The first visit creates the admin account.
- Subsonic API, also the household's music server (Symfonium, Feishin):
  `https://aurral.lab.emc2.build` on the LAN, `https://music.emc2.build`
  from anywhere. On the public host only `/rest` reaches Aurral, only from
  Cloudflare's IPs, rate-limited per `CF-Connecting-IP` (`public.yaml`); the
  rest of the host is the Feishin web player (`apps/feishin/`). The zone's
  DNS-only `*.emc2.build` wildcard exposes the home IP, hence the allowlist.
- Aurral has no failed-login lockout on `/rest` (only on the web UI login),
  so every account needs a long, unique password.
- `TRUST_PROXY` lists Traefik's pod CIDR and Cloudflare's ranges so Aurral
  sees real client IPs. Keep its Cloudflare list in sync with `public.yaml`.
- Image pinned to `2.12.0` (the GHCR tags have no `v` prefix).

## Paths

Aurral needs every app to see shared files at the same container paths:

| Path | Volume | Aurral | Others |
|---|---|---|---|
| `/downloads/music` | `media-library` / `music` | RO | Lidarr RW, Navidrome RO, slskd RO |
| `/downloads/aurral` | `music-discovery` / `aurral` | RW (Downloads Folder) | Navidrome RO (library 2) |
| `/downloads/slskd` | `music-discovery` / `slskd` | RW (moves finished files out) | slskd RW |

## Settings to enter in the UI (stored in Aurral's DB, not in git)

- **Lidarr:** URL `http://lidarr.media.svc.cluster.local:8686`, Lidarr's API
  key. New-artist monitoring: **None**, so adding an artist doesn't grab a
  whole discography.
- **slskd:** URL `http://slskd.media.svc.cluster.local:5030`, plus the key
  part (after the last `;`) of `SLSKD_API_KEY` in `apps/slskd/secret.yaml`.
- **Navidrome:** URL `http://navidrome.media.svc.cluster.local:4533`, and a
  Navidrome user for publishing playlists.
- **Downloads Folder:** `/downloads/aurral`.
- **Flows:** set retention so old weekly flows rotate out.
