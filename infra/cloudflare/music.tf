# Public hostname for Navidrome's Subsonic API (apps/navidrome/). Proxied so
# the home IP isn't published for this name. It's a CNAME to the apex like
# the other public sites, so it follows the apex's origin record.
#
# Traefik only routes /rest and /share on this host, and only from
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
  comment = "navidrome Subsonic API (/rest, /share); managed-by: terraform emcniece/homelab"
}
