# Glyphdex DB tunnel — remote read-only Postgres access

Gives trusted devs read-only access to the glyphdex Postgres without opening
any port. Path:

```
dev laptop: cloudflared access tcp  ──►  Cloudflare Access (login)  ──►  tunnel
  ──►  glyphdex-db-tunnel pods (this dir)  ──►  glyphdex-pg-rw:5432
```

- **Cloudflare Access** gates who can open the tunnel at all (per-email).
- **NetworkPolicy** (`networkpolicy.yaml`) lets the connector reach only
  Postgres + the Cloudflare edge; Postgres admits it on 5432 only.
- **Postgres** role `glyphdex_readonly` — SELECT-only, no `sessions` /
  `api_keys` / `upgrade_interest`, column-limited `users` / `subscriptions` /
  `watches`; `default_transaction_read_only`, 60s `statement_timeout`,
  10-connection limit. Created by hand in the DB (not in the CNPG `Cluster`
  spec); new tables need an explicit `GRANT SELECT` after their migration.
- Postgres TLS runs end-to-end through the tunnel (raw TCP passthrough).

This is a separate tunnel (Terraform-managed, `infra/cloudflare`) from the UDM's `cloudflared` (which can't reach
in-cluster ClusterIPs anyway), so it can be revoked on its own.

## One-time setup

### 1. Tunnel, DNS and Access (Terraform)

The Cloudflare side (tunnel, TCP route
`glyphdex-db.emc2.build -> tcp://glyphdex-pg-rw.glyphdex.svc.cluster.local:5432`,
CNAME, Access application + per-email policy) is in
[`infra/cloudflare/glyphdex-db.tf`](../../../infra/cloudflare/glyphdex-db.tf).
Set it up per [`infra/cloudflare/README.md`](../../../infra/cloudflare/README.md),
with the devs' emails in `glyphdex_db_dev_emails`, then `terraform apply`.
Don't edit it in the dashboard.

The hostname is a single-level subdomain because Universal SSL only covers
`*.emc2.build`; `db.gspr.emc2.build` would fail the edge TLS handshake.

### 2. Tunnel token -> cluster

```sh
export KUBECONFIG=~/.kube/config-homelab
kubectl -n glyphdex create secret generic glyphdex-db-tunnel \
  --from-literal=TUNNEL_TOKEN="$(terraform -chdir=infra/cloudflare output -raw glyphdex_db_tunnel_token)" \
  --dry-run=client -o yaml \
| kubectl label --local -f - -o yaml \
    app.kubernetes.io/name=glyphdex-db-tunnel app.kubernetes.io/component=db-tunnel \
    app.kubernetes.io/part-of=glyphdex app.kubernetes.io/managed-by=kubectl \
| kubectl annotate --local -f - -o yaml \
    emc2.build/source=github.com/emcniece/homelab/infra/cloudflare \
| kubectl apply -f -
```

(`secret.example.yaml` is the manual alternative if Terraform isn't in use.)

### 3. Deploy the connector

```sh
kubectl apply -f apps/glyphdex/db-tunnel/networkpolicy.yaml
kubectl apply -f apps/glyphdex/db-tunnel/cloudflared.yaml
kubectl -n glyphdex rollout status deploy/glyphdex-db-tunnel
```

The tunnel should show **HEALTHY** with 2 connectors in Zero Trust ->
Networks -> Tunnels.

### 4. Set the role's password

```sh
kubectl -n glyphdex exec -it glyphdex-pg-1 -c postgres -- \
  psql -U postgres -d glyphdex -c '\password glyphdex_readonly'
```

## Dev instructions (share these)

1. Install `cloudflared` (`brew install cloudflared`, or
   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/).
2. Open the local end of the tunnel (a browser login opens the first time):

   ```sh
   cloudflared access tcp --hostname glyphdex-db.emc2.build --url localhost:15432
   ```
3. Connect any Postgres client to it:

   ```sh
   psql "postgresql://glyphdex_readonly@localhost:15432/glyphdex?sslmode=require"
   ```

   For CA-verified TLS, get the CA from an admin (`kubectl -n glyphdex get
   secret glyphdex-pg-ca -o jsonpath='{.data.ca\.crt}' | base64 -d`) and use
   `sslmode=verify-ca&sslrootcert=glyphdex-pg-ca.crt`. (`verify-full` fails —
   the client sees `localhost`, not a name on the server cert.)

## Revoking access

- One dev: remove their email from `glyphdex_db_dev_emails` and
  `terraform apply` (and Access → Users → revoke their session to kick them
  immediately).
- Everyone, fast: `kubectl -n glyphdex scale deploy/glyphdex-db-tunnel --replicas=0`.
- Credential leak: rotate the `glyphdex_readonly` password (step 4); rotate
  the tunnel token per `infra/cloudflare/README.md` and redo step 2.
