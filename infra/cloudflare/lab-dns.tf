# Explicit A records for the LAN-only *.lab.emc2.build services, replacing the
# old `*.lab.emc2.build` wildcard.
#
# Why no wildcard: pods use the cluster search path, and with the default
# ndots:5 a lookup like `github.com` is first tried as
# `github.com.lab.emc2.build` (when a node's search domains include
# lab.emc2.build). The wildcard answered those with the Traefik IP, so
# external names silently resolved to the homelab. Explicit records make
# unknown names NXDOMAIN again. The UDM has its own *.lab answer too, so
# CoreDNS sends lab.emc2.build to Cloudflare (infra/coredns/), which makes
# this list what pods see: a host missing here doesn't resolve in-cluster.
#
# The list is every *.lab.emc2.build host with an Ingress or IngressRoute on
# the homelab cluster. lab, jellyfin, plex and pve1-3 already have records
# created by hand in the dashboard and aren't managed here. A new LAN service
# needs its hostname added below.

locals {
  lab_traefik_ip = "192.168.10.91" # traefik-system/traefik LoadBalancer

  lab_hosts = toset([
    "calibre-downloader",
    "calibre-web",
    "deluge",
    "emby",
    "etherpad",
    "grafana",
    "heimdall",
    "homelable",
    "homelable-mcp",
    "homepage",
    "homer",
    "immich",
    "lidarr",
    "plexpy",
    "prometheus",
    "prowlarr",
    "radarr",
    "registry",
    "sabnzbd",
    "scrutiny",
    "sonarr",
    "subarr",
    "tdarr",
    "traefik",
  ])
}

resource "cloudflare_dns_record" "lab" {
  for_each = local.lab_hosts

  zone_id = data.cloudflare_zone.main.zone_id
  name    = "${each.key}.lab.${var.zone_name}"
  type    = "A"
  content = local.lab_traefik_ip
  proxied = false # private IP; LAN only
  ttl     = 1     # automatic
  comment = "homelab Traefik (LAN); managed-by: terraform emcniece/homelab infra/cloudflare"
}
