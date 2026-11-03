# Public ingress for moneymaker's OTP relay webhook: a MacroDroid "HTTP
# Request" automation on the account owner's phone POSTs a freshly-received
# SMS body here when OpenD's login flow needs a verification code. Cloudflare
# Tunnel (HTTP, not TCP like glyphdex-db.tf) so the phone never needs a VPN
# client and the cluster never opens an inbound port — see
# docs/opend-operations.md in the moneymaker repo for the full story on why
# this exists (Pushbullet's notification-mirroring turned out to depend on a
# separately-revocable Android permission).
#
# Deliberately NO Cloudflare Access in front of this, unlike glyphdex-db:
# Access intercepts with an interactive SSO login, which a one-shot
# unattended phone automation can't complete. Auth is instead the engine's
# own SMS_WEBHOOK_SECRET header check (X-Webhook-Secret) — see metrics.py's
# _do_sms_webhook. The ingress path restriction below is defense in depth on
# top of that, not instead of it: only /webhook/sms is ever proxied to the
# engine; every other path on this hostname 404s at Cloudflare's edge,
# before ever reaching the cluster.
#
# In-cluster connector: apps/moneymaker/sms-webhook-tunnel.yaml; its
# TUNNEL_TOKEN comes from the `sms_webhook_tunnel_token` output.

locals {
  sms_webhook_hostname = "${var.sms_webhook_subdomain}.${var.zone_name}"

  sms_webhook_dns_comment = format(
    "moneymaker/sms-webhook; terraform: emcniece/homelab infra/cloudflare",
  )
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "sms_webhook" {
  account_id = var.account_id
  name       = "moneymaker-sms-webhook"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sms_webhook" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.sms_webhook.id

  config = {
    ingress = [
      {
        hostname = local.sms_webhook_hostname
        path     = "^/webhook/sms$"
        service  = "http://moneymaker-engine.moneymaker.svc.cluster.local:9100"
      },
      # Same hostname, any other path — 404 before it ever reaches the
      # engine (it has /metrics, /trades, /actions/* etc. that have no
      # business being reachable from the public internet).
      {
        hostname = local.sms_webhook_hostname
        service  = "http_status:404"
      },
      # cloudflared requires a catch-all last rule.
      { service = "http_status:404" },
    ]
  }
}

resource "cloudflare_dns_record" "sms_webhook" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = local.sms_webhook_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.sms_webhook.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic; required value for proxied records
  comment = local.sms_webhook_dns_comment

  lifecycle {
    precondition {
      condition     = length(local.sms_webhook_dns_comment) <= 100
      error_message = "DNS record comments are limited to 100 characters on the Free plan."
    }
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "sms_webhook" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.sms_webhook.id
}
