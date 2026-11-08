# Aurral

Music discovery and requests. It runs the Weekly Flow (single tracks from
slskd), imports Spotify playlists, and hands albums to Lidarr.

- UI: `https://aurral.lab.emc2.build` (LAN only, never public). The first
  visit creates the admin account.
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
