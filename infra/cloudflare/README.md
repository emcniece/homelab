# Cloudflare (Terraform)

Terraform for Cloudflare resources in the `emc2.build` account. Manages:

- The **glyphdex DB tunnel** (`glyphdex-db.tf`): the tunnel, its TCP route to
  Postgres, the DNS record, and the Access application + policy.
- The **WordPress page cache** (`wordpress-cache.tf`): a cache rule on each
  zone in `wordpress_cache_zones` that caches anonymous HTML at the edge.
- The **LAN service records** (`lab-dns.tf`): one A record per
  `*.lab.emc2.build` host, pointing at the homelab Traefik LoadBalancer.

The UDM's tunnel and the existing DNS records are still managed by hand.
`terraform import` can bring them in later if wanted.

**Don't edit these resources in the Cloudflare dashboard.** The next
`terraform apply` will overwrite the change.

## Identifiers

Everything this module creates is marked as `glyphdex` / `db-tunnel`, managed
by `terraform`, wherever Cloudflare allows it:

| Resource | How it's marked |
|---|---|
| Access application | Access tags `glyphdex` and `terraform` (filter chips in Zero Trust → Access → Applications) |
| DNS record | Comment: `glyphdex/db-tunnel; terraform: emcniece/homelab infra/cloudflare` |
| Tunnel, tunnel config, Access policy | No tag or comment field, so the `glyphdex-db` name prefix is the identifier |

The zone is on the **Free** plan. DNS-record `tags` aren't available there,
and comments are capped at 100 characters. A precondition on the record
fails `plan` if the comment grows past that. If the zone moves to a paid plan,
add `tags` to `cloudflare_dns_record.glyphdex_db`.

The state bucket can't be tagged either: B2's S3 API returns `NotImplemented`
for bucket tagging. Its purpose is recorded here instead:
`emc2-homelab-tfstate` holds Terraform state for `infra/cloudflare`.

## State: Backblaze B2

State is kept in a private B2 bucket through B2's S3-compatible API
(`backend "s3"`). It contains the tunnel secret and token, so it must never be
committed (it's gitignored). Treat the bucket as a secret store.

### One-time B2 setup

1. **Create a bucket** (B2 → Buckets → Create a Bucket), e.g. `emc2-homelab-tfstate`:
   - Files: **Private**
   - Default encryption: **Enable** (SSE-B2)
   - Lifecycle: **Keep all versions** (so you can roll back a bad state)
2. **Create an application key** (B2 → Application Keys → Add a New
   Application Key):
   - Allow access to bucket: only that bucket
   - Type of access: Read and Write

   Note the `keyID` and `applicationKey`.
3. `cp backend.hcl.example backend.hcl` and fill in the bucket name, region
   and endpoint (the bucket's "Endpoint" value).

State is not locked: B2 doesn't support the S3 conditional writes that
Terraform's `use_lockfile` relies on. Don't run two `apply`s at once.

## Credentials (AWS profile + gitignored secrets file)

The B2 application key (scoped to `emc2-homelab-tfstate`, Read and Write)
lives in the `b2-tfstate` AWS profile (`~/.aws/credentials` + `config`).
`backend.hcl` pins `profile = "b2-tfstate"`, so no `AWS_*` env vars are needed.
Don't use the B2 master key: B2's S3 API rejects it.

The Cloudflare API token goes in `secrets.auto.tfvars` (gitignored, `chmod
600`, auto-loaded by Terraform). Copy it from `secrets.auto.tfvars.example`.
Create the token under My Profile → API Tokens → Create Custom Token, with:

- Account → Cloudflare Tunnel: Edit
- Account → Access: Apps and Policies: Edit
- Zone → DNS: Edit (Zone Resources: Include → Specific zone → emc2.build)
- Zone → Zone: Read (same zone, for the zone-ID lookup)
- Zone → Cache Rules: Edit and Zone → Zone: Read (Zone Resources: each zone
  in `wordpress_cache_zones`: emc2.build, createsleeprepeat.ca, echoandflow.ca)

To rotate it: roll it in the dashboard and replace the value in
`secrets.auto.tfvars`.

## Usage

```sh
cd infra/cloudflare
cp terraform.tfvars.example terraform.tfvars   # account_id + dev emails
cp secrets.auto.tfvars.example secrets.auto.tfvars   # Cloudflare API token
chmod 600 secrets.auto.tfvars
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`terraform.tfvars` is gitignored because it lists dev email addresses and this
repo is public.

### Glyphdex DB tunnel

After the first `apply`, load the tunnel token into the cluster. This replaces
the hand-edited `apps/glyphdex/db-tunnel/secret.yaml`:

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl -n glyphdex create secret generic glyphdex-db-tunnel \
  --from-literal=TUNNEL_TOKEN="$(terraform output -raw glyphdex_db_tunnel_token)" \
  --dry-run=client -o yaml \
| kubectl label --local -f - -o yaml \
    app.kubernetes.io/name=glyphdex-db-tunnel app.kubernetes.io/component=db-tunnel \
    app.kubernetes.io/part-of=glyphdex app.kubernetes.io/managed-by=kubectl \
| kubectl annotate --local -f - -o yaml \
    emc2.build/source=github.com/emcniece/homelab/infra/cloudflare \
| kubectl apply -f -
kubectl -n glyphdex rollout restart deploy/glyphdex-db-tunnel
```

To add or remove a dev, edit `glyphdex_db_dev_emails` in `terraform.tfvars`
and run `terraform apply`. Removing someone stops new logins. To also end
their current session right away, go to Zero Trust → Access → Users → revoke.

To rotate the tunnel token: `terraform apply -replace=cloudflare_zero_trust_tunnel_cloudflared.glyphdex_db`,
then re-run the secret command above. Replacing the tunnel gives it a new ID,
and Terraform updates the CNAME and route to match.

### WordPress page cache

`wordpress-cache.tf` adds one cache rule per zone. It caches every request
except those with a query string, under `/wp-admin`, `/wp-login.php`,
`/wp-json`, `/cart`, `/checkout` or `/my-account`, or carrying a
logged-in, password-post, commenter or WooCommerce cookie. Edge TTL follows
the origin. WordPress sends no `Cache-Control` on public pages, so
Cloudflare's 2h default applies. An edited page can be stale for up to 2h
unless you purge it. emc2.build's Cloudflare plugin purges on edit; for the
others, purge from the dashboard (Caching → Configuration).

If a zone already has cache rules from the dashboard, Cloudflare refuses a
second entry-point ruleset. Import the existing one first:

```sh
terraform import 'cloudflare_ruleset.wordpress_cache["echoandflow.ca"]' zones/<zone_id>/<ruleset_id>
```

Check that it works with `curl -sI https://<site>/ | grep cf-cache-status`.
The second request should say `HIT`. Logged-in requests should say `DYNAMIC`
or `BYPASS`.

### LAN service records

There is deliberately no `*.lab.emc2.build` wildcard. With pod search domains
and ndots:5, a wildcard made lookups like `github.com.lab.emc2.build`
resolve to Traefik instead of failing over to the real name. When a new LAN
service gets an Ingress, add its hostname to `lab_hosts` in `lab-dns.tf` and
apply. `lab`, `jellyfin`, `plex` and `pve1`-`pve3` are still hand-managed.
