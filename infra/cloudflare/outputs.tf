output "glyphdex_db_hostname" {
  value = local.glyphdex_db_hostname
}

output "glyphdex_db_tunnel_token" {
  description = "TUNNEL_TOKEN for the glyphdex-db-tunnel Secret in the glyphdex namespace."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.glyphdex_db.token
  sensitive   = true
}

output "sms_webhook_hostname" {
  value = local.sms_webhook_hostname
}

output "sms_webhook_tunnel_token" {
  description = "TUNNEL_TOKEN for the sms-webhook-tunnel Secret in the moneymaker namespace."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.sms_webhook.token
  sensitive   = true
}
