# Aurral

Music discovery and requests. It runs the Weekly Flow (single tracks from
slskd), imports Spotify playlists, and hands albums to Lidarr.

- UI: `https://aurral.lab.emc2.build` (LAN only; the web UI is never
  public). The first visit creates the admin account.
- Subsonic API, also the household's music server (Symfonium, Feishin):
  `https://aurral.lab.emc2.build` on the LAN, `https://music.emc2.build`
  from anywhere. On the public host only `/rest` and `/api/image-proxy` (cover art
  redirects) reach Aurral, only from
  Cloudflare's IPs, rate-limited per `CF-Connecting-IP` (`public.yaml`); the
  rest of the host is the Feishin web player (`apps/feishin/`). The zone's
  DNS-only `*.emc2.build` wildcard exposes the home IP, hence the allowlist.
- Aurral has no failed-login lockout on `/rest` (only on the web UI login),
  so every account needs a long, unique password.
- `TRUST_PROXY` lists Traefik's pod CIDR and Cloudflare's ranges so Aurral
  sees real client IPs. Keep its Cloudflare list in sync with `public.yaml`.
- Image pinned to `3.1.0` (the GHCR tags have no `v` prefix). Upgraded from
  2.12.0 on 2026-11-24. Aurral 3 only opens a database that 2.13.0 finished
  upgrading (it exits with "Missing: ..." otherwise), so the upgrade ran
  `2.13.0` once on the same `/config`, then `3.1.0`. The 2.12 database is kept as
  `/config/aurral.backup-2.12.0-2026-11-24.db`, and 3.x saved its own
  pre-migration copies (`aurral.pre-*.db`) next to it. To roll back, see
  https://docs.aurral.org/admin/troubleshooting/#roll-back-to-aurral-2.

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
- **Navidrome:** 3.x no longer publishes playlists through Navidrome's API;
  it writes an M3U file per flow and playlist to `_playlists` in the Library
  folder instead (Navidrome is scaled to 0 anyway).
- **Library folder:** `/downloads/aurral` (`LIBRARY_FOLDER`).
- **Flows:** set retention so old weekly flows rotate out.
