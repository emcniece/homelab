# Public hostname for Utensil Maker (github.com/emcniece/utensil-maker,
# namespace utensil-maker). Proxied CNAME to the apex like music.tf, so it
# follows the apex's origin record and the home IP isn't published for this
# name. The app's Ingress only accepts Cloudflare's IP ranges (chart value
# web.ingress.cloudflareOnly), since the DNS-only `*.emc2.build` wildcard
# still reaches the origin directly. utensil.lab.emc2.build (LAN) redirects
# here.
#
# The host is also excluded from the WordPress page cache in
# wordpress-cache.tf: it sets session cookies that rule doesn't know about.

locals {
  utensil_hostname = "utensil.${var.zone_name}"
}

resource "cloudflare_dns_record" "utensil" {
  zone_id = data.cloudflare_zone.main.zone_id
  name    = local.utensil_hostname
  type    = "CNAME"
  content = var.zone_name
  proxied = true
  ttl     = 1 # automatic (required when proxied)
  comment = "utensil-maker web; managed-by: terraform emcniece/homelab"
}
