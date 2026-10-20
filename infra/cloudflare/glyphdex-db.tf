# Read-only Postgres access for trusted devs: Cloudflare Tunnel (TCP) gated
# by Cloudflare Access. The in-cluster connector is
# apps/glyphdex/db-tunnel/cloudflared.yaml; its TUNNEL_TOKEN comes from the
# `glyphdex_db_tunnel_token` output.

locals {
  glyphdex_db_hostname = "${var.glyphdex_db_subdomain}.${var.zone_name}"

  # Identifiers stamped on everything that can carry them. The tunnel, its
  # config and the Access policy have no tag/comment field, so their names
  # (all prefixed "glyphdex-db") are the identifier there.
  glyphdex_db_ids = {
    project    = "glyphdex"
    component  = "db-tunnel"
    managed-by = "terraform"
  }
  # DNS record comments are capped at 100 chars on the Free plan, and tags
  # aren't available on it at all, so the record gets a compact comment.
  glyphdex_db_dns_comment = format(
    "%s/%s; %s: emcniece/homelab infra/cloudflare",
    local.glyphdex_db_ids.project,
    local.glyphdex_db_ids.component,
    local.glyphdex_db_ids.managed-by,
  )
}

# Access tags only take a name (shown as filter chips in the App Launcher /
# Access apps list), so the project and how it's managed become two tags.
resource "cloudflare_zero_trust_access_tag" "glyphdex" {
  account_id = var.account_id
  name       = local.glyphdex_db_ids.project
}

resource "cloudflare_zero_trust_access_tag" "terraform" {
  account_id = var.account_id
  name       = local.glyphdex_db_ids.managed-by
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "glyphdex_db" {
  account_id = var.account_id
  name       = "glyphdex-db"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "glyphdex_db" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.glyphdex_db.id

  config = {
    ingress = [
      {
        hostname = local.glyphdex_db_hostname
        service  = "tcp://glyphdex-pg-rw.glyphdex.svc.cluster.local:5432"
      },
      # cloudflared requires a catch-all last rule.
      { service = "http_status:404" },
    ]
  }
}

resource "cloudflare_dns_record" "glyphdex_db" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = local.glyphdex_db_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.glyphdex_db.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic; required value for proxied records
  comment = local.glyphdex_db_dns_comment

  lifecycle {
    precondition {
      condition     = length(local.glyphdex_db_dns_comment) <= 100
      error_message = "DNS record comments are limited to 100 characters on the Free plan."
    }
  }
}

resource "cloudflare_zero_trust_access_policy" "glyphdex_db_devs" {
  account_id = var.account_id
  name       = "glyphdex-db devs"
  decision   = "allow"
  include    = [for e in var.glyphdex_db_dev_emails : { email = { email = e } }]
}

resource "cloudflare_zero_trust_access_application" "glyphdex_db" {
  account_id       = var.account_id
  name             = "glyphdex-db"
  type             = "self_hosted"
  domain           = local.glyphdex_db_hostname
  session_duration = var.glyphdex_db_session_duration
  tags = [
    cloudflare_zero_trust_access_tag.glyphdex.name,
    cloudflare_zero_trust_access_tag.terraform.name,
  ]

  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.glyphdex_db_devs.id
      precedence = 1
    },
  ]
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "glyphdex_db" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.glyphdex_db.id
}
