# Public hostname for Aurral's Subsonic API (apps/aurral/public.yaml) and
# the Feishin web player (apps/feishin/). Proxied so
# the home IP isn't published for this name. It's a CNAME to the apex like
# the other public sites, so it follows the apex's origin record.
#
# Traefik routes /rest to Aurral and everything else to Feishin on this host, and only from
# Cloudflare's IP ranges: the hand-managed DNS-only `*.emc2.build` wildcard
# still resolves any name to the home IP, so the origin is reachable directly.
# This explicit record takes precedence over the wildcard for `music`.

resource "cloudflare_dns_record" "music" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = "music.${var.zone_name}"
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1 # automatic (required when proxied)
  comment = "aurral Subsonic API (/rest) + feishin web; managed-by: terraform emcniece/homelab"
}
