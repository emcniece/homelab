# Token from secrets.auto.tfvars (gitignored); see README for its scopes.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "main" {
  filter = {
    name = var.zone_name
  }
}
