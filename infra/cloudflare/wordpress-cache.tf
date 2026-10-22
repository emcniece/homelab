# Edge-cache anonymous HTML for the WordPress sites in apps/. Without this
# every page view is rendered by PHP (cf-cache-status: DYNAMIC, ~0.4-1.2s at
# the origin). Static assets were already cached by Cloudflare's defaults.
#
# Edge TTL respects the origin: WordPress sends no Cache-Control on public
# pages, so Cloudflare applies its default (2h for a 200), while pages that
# call nocache_headers() (WooCommerce cart/checkout, logged-in views) stay
# uncached. Content edits can take up to that TTL to show unless the cache
# is purged; emc2.build's Cloudflare plugin purges edited URLs itself.

locals {
  # Requests that may involve a session, a form round-trip or per-user
  # output. Query strings are excluded wholesale (search, previews,
  # add-to-cart, wc-ajax, ...) rather than enumerated.
  wordpress_cache_bypass_paths = [
    "/wp-admin",
    "/wp-login.php",
    "/wp-json",
    "/wp-cron.php",
    "/xmlrpc.php",
    "/cart",
    "/checkout",
    "/my-account",
  ]
  wordpress_cache_bypass_cookies = [
    "wordpress_logged_in_",
    "wordpress_sec_",
    "wp-postpass_",
    "comment_author_",
    "woocommerce_",
    "wp_woocommerce_session_",
  ]

  wordpress_cache_expression = join(" and ", concat(
    [for p in local.wordpress_cache_bypass_paths : "not starts_with(http.request.uri.path, \"${p}\")"],
    [for c in local.wordpress_cache_bypass_cookies : "not http.cookie contains \"${c}\""],
    ["http.request.uri.query eq \"\""],
  ))
}

data "cloudflare_zone" "wordpress" {
  for_each = toset(var.wordpress_cache_zones)

  filter = {
    name = each.value
  }
}

# One cache-settings entry-point ruleset per zone. If a zone already has
# cache rules made in the dashboard, import its ruleset first or the create
# fails (Cloudflare allows one entry point per phase).
resource "cloudflare_ruleset" "wordpress_cache" {
  for_each = data.cloudflare_zone.wordpress

  zone_id     = each.value.zone_id
  name        = "WordPress page cache"
  description = "Cache anonymous HTML; managed by Terraform (emcniece/homelab infra/cloudflare)"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [{
    ref         = "wordpress_cache_anonymous_html"
    description = "Cache anonymous WordPress pages"
    expression  = local.wordpress_cache_expression
    action      = "set_cache_settings"
    action_parameters = {
      cache       = true
      edge_ttl    = { mode = "respect_origin" }
      browser_ttl = { mode = "respect_origin" }
    }
    enabled = true
  }]
}
