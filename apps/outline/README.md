# Outline

Team knowledge base / wiki, published at **https://docs.emc2.build**.

- **App:** [Outline](https://www.getoutline.com/) (`outlinewiki/outline`)
- **Auth:** Google OAuth (only sign-in method configured)
- **DB:** in-namespace Postgres 16 (`csi-rbd-sc`, 5Gi)
- **Cache/queue:** in-namespace Redis 7 (ephemeral)
- **File storage:** in-namespace MinIO (`csi-rbd-sc`, 20Gi), bucket `outline`.
  S3 API published at **https://s3.emc2.build** (the browser uploads/downloads
  there directly via presigned URLs); the MinIO console stays internal.

## Components

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | namespace `outline` |
| `01-secret.example.yaml` | template — copy to `01-secret.yaml` (gitignored) and fill in |
| `10-postgres.yaml` | Postgres PVC + Deployment + Service |
| `20-redis.yaml` | Redis Deployment + Service |
| `30-minio.yaml` | MinIO PVC + Deployment + Service (S3 API :9000, console :9001) |
| `31-minio-bucket-job.yaml` | creates the `outline` bucket + scoped access key |
| `35-minio-ingress.yaml` | Traefik ingress for `s3.emc2.build` (S3 API only) + LE cert |
| `40-outline.yaml` | migrate initContainer + Outline Deployment + Service |
| `50-ingress.yaml` | Traefik ingress for `docs.emc2.build` + LE cert |

## First-time setup

### 1. Google OAuth credentials

Google Cloud Console → **APIs & Services → Credentials → Create credentials →
OAuth client ID**:

- Application type: **Web application**
- Authorized JavaScript origin: `https://docs.emc2.build`
- Authorized redirect URI: `https://docs.emc2.build/auth/google.callback`

Also configure the OAuth consent screen (External, add your email as a test
user, or publish). Copy the client ID and secret.

### 2. Secret

```sh
cp apps/outline/01-secret.example.yaml apps/outline/01-secret.yaml
# fill in:
#   POSTGRES_PASSWORD        openssl rand -hex 20
#   MINIO_ROOT_PASSWORD      openssl rand -hex 20
#   OUTLINE_S3_SECRET_KEY    openssl rand -hex 20
#   SECRET_KEY               openssl rand -hex 32
#   UTILS_SECRET             openssl rand -hex 32
#   GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET   from step 1
```

`01-secret.yaml` is gitignored (this repo is public). The committed
`01-secret.yaml` in the initial deploy already has the random values filled;
only the two `GOOGLE_*` keys need to be set before logins work.

### 3. DNS

Add Cloudflare DNS records for **`docs.emc2.build`** and **`s3.emc2.build`**,
each matching `planka.emc2.build` (same target, proxied). The LE certs use the
DNS-01 solver so they issue once the records exist.

> If Cloudflare proxying is on, make sure the upload size limit is acceptable
> (free plan caps request bodies at 100 MB) or set an appropriate
> `FILE_STORAGE_UPLOAD_MAX_SIZE` in `40-outline.yaml`.

### 4. Deploy

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl apply -f apps/outline/00-namespace.yaml
kubectl apply -f apps/outline/01-secret.yaml
kubectl apply -f apps/outline/            # the rest
kubectl -n outline get pods -w
```

Apply order matters only in that the namespace and secrets come first;
`kubectl apply -f apps/outline/` re-applies everything and is safe to repeat.

### 5. First login

The first user to sign in via Google becomes the admin. Restrict who else can
join under **Settings → Security** (allowed domains / invite-only).

## Operations

**MinIO console:**
```sh
kubectl -n outline port-forward svc/minio 9001:9001
# http://localhost:9001  (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD)
```

**Re-run the bucket job:**
```sh
kubectl -n outline delete job minio-bucket-setup
kubectl apply -f apps/outline/31-minio-bucket-job.yaml
```

**Re-run migrations manually:**
```sh
kubectl -n outline exec deploy/outline -- yarn db:migrate
```

**Postgres backup:**
```sh
kubectl -n outline exec deploy/postgres -- \
  sh -c 'pg_dump -U outline outline' > outline-$(date +%F).sql
```

## Notes / follow-ups

- **Pin the image.** `outlinewiki/outline:latest` is used to match repo
  convention; pin to a released tag (e.g. `outlinewiki/outline:0.82.0`) so a
  future release with breaking migrations can't roll in unnoticed.
- **MCP server.** To let Claude read/write docs, run an Outline MCP server
  (community: `outline-mcp` / `mcp-outline`) pointed at
  `https://docs.emc2.build` with an API token from **Settings → API Tokens**.
- If Outline hits an HTTPS redirect loop behind Traefik, set
  `FORCE_HTTPS=false` in `40-outline.yaml` (Traefik already terminates TLS and
  the ingress redirects http→https).
- SMTP is not configured, so email invites/notifications are disabled. Add
  `SMTP_*` env vars later if wanted.
