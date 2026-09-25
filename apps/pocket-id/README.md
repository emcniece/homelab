# Pocket ID

Passkey-only OIDC identity provider, published at **https://id.emc2.build**.
Single sign-on for homelab apps (currently: Outline).

- **App:** [Pocket ID](https://pocket-id.org) (`ghcr.io/pocket-id/pocket-id`, pinned)
- **DB:** SQLite on a 1Gi `csi-rbd-sc` PVC (`/app/data`)
- **Login:** passkeys only — no passwords

## Components

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | namespace `pocket-id` |
| `01-secret.example.yaml` | template — copy to `01-secret.yaml` (gitignored) |
| `10-pocket-id.yaml` | PVC + Deployment + Service |
| `50-ingress.yaml` | Traefik ingress for `id.emc2.build` + LE cert |

## Deploy

```sh
cp apps/pocket-id/01-secret.example.yaml apps/pocket-id/01-secret.yaml
# fill ENCRYPTION_KEY with: openssl rand -base64 32
kubectl apply -f apps/pocket-id/00-namespace.yaml
kubectl apply -f apps/pocket-id/01-secret.yaml
kubectl apply -f apps/pocket-id/
```

**Back up `ENCRYPTION_KEY`** (password manager). It encrypts the OIDC signing
keys; without it the database can't be used.

## First-time setup

1. Open **https://id.emc2.build/setup** and create the admin account (register
   a passkey). Do this promptly after deploying — until then, anyone who can
   reach the URL can claim admin.
2. **Settings → Application Configuration → Email → "Emails verified by
   default"**: enable. Pocket ID has no SMTP here, so emails can't be verified
   by link; Outline refuses to link existing accounts by email unless
   `email_verified` is true.
3. Your own setup account was created *before* step 2, so it is unverified,
   and admins can't toggle their own verified flag. Workaround: in your
   account settings change your email to anything else, save, then change it
   back — a changed email picks up the "verified by default" setting.
   (Alternatively, have a second admin tick "Email verified" on your user.)
4. **Users → Add user** for everyone else. Emails must match their existing
   Outline emails. Each user gets a one-time login code/link to register
   their passkey (**Users → ⋯ → Login Code**).
5. **OIDC Clients → Add OIDC Client** per app (see below).

## Clients

| App | Callback URL | Notes |
|-----|--------------|-------|
| Outline | `https://docs.emc2.build/auth/oidc.callback` | secrets in `apps/outline/01-secret.yaml` (`OIDC_CLIENT_ID/SECRET`) |

To limit an app to certain users, create a user group and set it under the
client's **Allowed user groups**.

## Operations

**Backup** (built-in export, streamed to stdout):
```sh
kubectl -n pocket-id exec deploy/pocket-id -- /app/pocket-id export --path - > pocket-id-$(date +%F).zip
```

**Upgrade:** bump the image tag in `10-pocket-id.yaml` and apply. Read the
release notes first — Pocket ID refuses to downgrade the DB schema.

## Notes

- `TRUST_PROXY=10.42.0.0/16` trusts `X-Forwarded-*` from Traefik on the pod
  network. Client IPs in the audit log will be whatever Traefik forwards.
- On first boot it logs a burst of `Slow SQL statement` / `SQLITE_BUSY`
  warnings as its background jobs all start at once on Ceph RBD. They taper
  off within a couple of minutes. If they persist, move the DB to Postgres
  (`DB_CONNECTION_STRING=postgres://...`).
- SMTP (Application Configuration → Email) uses the same relay as Scrutiny:
  `mail.hostedemail.com:587`, STARTTLS. Needs the `ndots:2` dnsConfig in
  `10-pocket-id.yaml` — without it the pod resolves external names via the
  `*.lab.emc2.build` wildcard and SMTP times out.
