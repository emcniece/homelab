# udmp-persist

Installs the `/data/on_boot.d/` survives-firmware-updates scripts on the UDM
Pro. Background and rationale: https://docs.emc2.build/doc/udm-pro-persisting-config-across-firmware-updates-1cdqqdD4wQ

## Required vars

- `udmp_authorized_keys`: list of public key strings to persist to
  `/root/.ssh/authorized_keys`.
- `cloudflare_tunnel_token`: the cloudflared tunnel token (from the
  Cloudflare Zero Trust dashboard, Networks > Tunnels > `<tunnel>` >
  Configure). Define this in `secrets.yml`, not in the playbook.

## Notes

- The cloudflared binary itself is not pushed by this role — the on_boot.d
  script downloads it from GitHub the first time it runs if
  `/data/cloudflared/cloudflared` doesn't already exist, and reuses the
  persisted copy on every boot after that.
- To rotate the tunnel token, update `cloudflare_tunnel_token` in
  `secrets.yml` and rerun the playbook.
- To add/remove an SSH key, update `udmp_authorized_keys` and rerun the
  playbook — don't edit `/root/.ssh/authorized_keys` directly, it won't
  survive the next firmware update.
