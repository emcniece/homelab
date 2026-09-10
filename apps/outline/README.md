# Outline

Team knowledge base / wiki, published at **https://docs.emc2.build**.

- **App:** [Outline](https://www.getoutline.com/) (`outlinewiki/outline`)
- **Auth:** Google OAuth (only sign-in method configured)
- **DB:** in-namespace Postgres 16 (`csi-rbd-sc`, 5Gi)
- **Cache/queue:** in-namespace Redis 7 (ephemeral)
- **File storage:** Backblaze B2 (S3-compatible API). Outline's browser
  uploads/downloads directly against the B2 endpoint via presigned URLs.

## Components

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | namespace `outline` |
| `01-secret.example.yaml` | template — copy to `01-secret.yaml` (gitignored) and fill in |
| `10-postgres.yaml` | Postgres PVC + Deployment + Service |
| `20-redis.yaml` | Redis Deployment + Service |
| `40-outline.yaml` | Outline Deployment + Service (auto-migrates on start) |
| `50-ingress.yaml` | Traefik ingress for `docs.emc2.build` + LE cert |

## First-time setup

### 1. Google OAuth credentials

Google Cloud Console → **APIs & Services → Credentials → Create credentials →
OAuth client ID**:

- Application type: **Web application**
- Authorized JavaScript origin: `https://docs.emc2.build`
- Authorized redirect URI: `https://docs.emc2.build/auth/google.callback`

Configure the OAuth consent screen (External; add your email as a test user or
publish). Copy the client ID and secret.

### 2. Backblaze B2 bucket

1. **Create a bucket** (private). Note its **Endpoint**
   (e.g. `s3.us-west-004.backblazeb2.com`) — the region is the middle segment
   (`us-west-004`).
2. **Application key:** B2 → *Application Keys* → *Add a New Application Key*,
   scoped to that bucket, read + write. Save the `keyID` and `applicationKey`.
3. **CORS:** the browser POSTs/GETs directly to B2, so the bucket needs CORS
   rules. Bucket → *CORS Rules*. Either "Share everything in this bucket with
   every origin", or a scoped rule:
   - Allowed origins: `https://docs.emc2.build`
   - Allowed operations: `s3_head`, `s3_get`, `s3_put`, `s3_post`, `s3_delete`
   - Allowed headers: `*`
   - Expose headers: `ETag`, `Content-Length`
   Via CLI: `b2 bucket update --cors-rules "$(cat cors.json)" <bucket> allPrivate`

### 3. Secret

```sh
cp apps/outline/01-secret.example.yaml apps/outline/01-secret.yaml
# fill in:
#   POSTGRES_PASSWORD                       openssl rand -hex 20
#   SECRET_KEY, UTILS_SECRET                openssl rand -hex 32
#   GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET from step 1
#   AWS_ACCESS_KEY_ID                       B2 keyID
#   AWS_SECRET_ACCESS_KEY                   B2 applicationKey
#   AWS_REGION                              e.g. us-west-004
#   AWS_S3_UPLOAD_BUCKET_URL                https://s3.<region>.backblazeb2.com
#   AWS_S3_UPLOAD_BUCKET_NAME               the bucket name
```

`01-secret.yaml` is gitignored (this repo is public). In the initial commit it
already has the random `SECRET_KEY` / `UTILS_SECRET` / `POSTGRES_PASSWORD`
filled; the `GOOGLE_*` and B2 values are `REPLACE_ME`.

### 4. DNS

Add a Cloudflare DNS record for `docs.emc2.build` matching `planka.emc2.build`
(same target, proxied). The LE cert uses the DNS-01 solver so it issues once
the record exists.

> If Cloudflare proxying is on, note the free plan caps request bodies at
> 100 MB. Uploads go browser → B2 directly (not through the proxy), so this
> only limits Outline's own API payloads, not attachments.

### 5. Deploy

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl apply -f apps/outline/00-namespace.yaml
kubectl apply -f apps/outline/01-secret.yaml
kubectl apply -f apps/outline/            # the rest
kubectl -n outline get pods -w
```

### 6. First login

The first user to sign in via Google becomes the admin. Restrict who else can
join under **Settings → Security** (allowed domains / invite-only).

First boot runs ~10 years of DB migrations (~3 min) before the app listens;
the `startupProbe` covers this. `kubectl -n outline logs -f deploy/outline`
to watch.

## Operations

Outline runs pending migrations itself on every start (the `outlinewiki/outline`
image no longer ships `yarn`, so there is no separate migrate step). To force
it: `kubectl -n outline rollout restart deploy/outline`.

**Postgres backup:**
```sh
kubectl -n outline exec deploy/postgres -- \
  sh -c 'pg_dump -U outline outline' > outline-$(date +%F).sql
```

Attachments live in B2 — back that up with B2 lifecycle rules / versioning.

## Notes / follow-ups

- **Pin the image.** `outlinewiki/outline:latest` is used to match repo
  convention; pin to a released tag (e.g. `outlinewiki/outline:0.82.0`) so a
  future release with breaking migrations can't roll in unnoticed.
- **MCP server.** To let Claude read/write docs, generate an API token in
  Outline (**Settings → API Tokens**) and run a community Outline MCP server
  (`outline-mcp` / `mcp-outline`) pointed at `https://docs.emc2.build`.
- If Outline hits an HTTPS redirect loop behind Traefik, set
  `FORCE_HTTPS=false` in `40-outline.yaml`.
- SMTP is not configured, so email invites/notifications are disabled. Add
  `SMTP_*` env vars later if wanted.
- If B2 rejects presigned requests, try `AWS_S3_FORCE_PATH_STYLE=false` in
  `40-outline.yaml` (B2's S3 API accepts both; path-style is the default here).
