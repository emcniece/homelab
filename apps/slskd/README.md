# slskd

Soulseek client. Aurral uses it to download single tracks for flows and
playlists. Full albums go through Lidarr and Usenet instead.

- Web UI: `https://slskd.lab.emc2.build` (LAN only).
- API for Aurral: `http://slskd.media.svc.cluster.local:5030`. The API key
  is ReadWrite and only accepted from pod IPs (10.42.0.0/16).
- Peer port: TCP 50300 on `slskd-peer` (MetalLB 192.168.10.92). Forward TCP
  50300 on the UDM to 192.168.10.92:50300. Nothing else is exposed.

## Storage

| Path | Volume | Access |
|---|---|---|
| `/app` | `slskd-config` (RBD) | RW |
| `/downloads/slskd/{complete,incomplete}` | `music-discovery`, subPath `slskd` | RW |
| `/downloads/music` | `media-library`, subPath `music` | **RO**, shared on Soulseek |

slskd is the only app with an internet-facing port, so it never gets write
access to the main library. Uploads are capped at 5 slots and 2 MiB/s.

## Secret

`secret.yaml` is gitignored. Copy `secret.yaml.example` to create it.
There's no Soulseek sign-up: the first login with an unused username
creates the account.

```sh
kubectl --context homelab apply -f apps/slskd/secret.yaml
kubectl --context homelab apply -f apps/slskd/
```
