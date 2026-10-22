variable "cloudflare_api_token" {
  description = "Cloudflare API token. Set in secrets.auto.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID (dashboard -> any zone -> Overview sidebar)."
  type        = string
}

variable "zone_name" {
  description = "DNS zone the tunnel hostnames live under."
  type        = string
  default     = "emc2.build"
}

variable "glyphdex_db_subdomain" {
  description = "Single-level subdomain for the DB tunnel (Universal SSL only covers *.zone)."
  type        = string
  default     = "glyphdex-db"
}

variable "glyphdex_db_dev_emails" {
  description = "Emails allowed through Cloudflare Access to the glyphdex DB tunnel."
  type        = list(string)
  default     = []
}

variable "wordpress_cache_zones" {
  description = "Zones serving the apps/ WordPress sites; each gets the page-cache rule in wordpress-cache.tf."
  type        = list(string)
  # kamloopsdentalsociety.com isn't listed: its nameservers differ from the
  # others, suggesting it lives in another Cloudflare account.
  default = [
    "emc2.build",
    "createsleeprepeat.ca",
    "echoandflow.ca",
  ]
}

variable "glyphdex_db_session_duration" {
  description = "How long an Access login lasts before the dev must re-authenticate."
  type        = string
  default     = "24h"
}
