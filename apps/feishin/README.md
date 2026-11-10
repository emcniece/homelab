# Feishin web

The Feishin music player's web build, at `https://music.emc2.build/`. Log in
with an Aurral account; the server is fixed to Aurral (`SERVER_LOCK`), so the
login page only asks for username and password.

- Static nginx site, no state or credentials. The browser talks to Aurral's
  Subsonic API directly at `music.emc2.build/rest` (same origin, no CORS).
- Same Cloudflare-only allowlist and per-client rate limit as `/rest`
  (middlewares in `apps/aurral/public.yaml`), and the same certificate
  (`music-letsencrypt-tls`, issued for the `aurral-public` Ingress).
- Image pinned to `1.17.0`. The desktop app (macOS/Windows/Linux) is the same
  player; see the Music page on docs.emc2.build.

```sh
kubectl --context homelab apply -f apps/feishin/
```
