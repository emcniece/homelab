# SearXNG

Self-hosted metasearch, used as Open WebUI's web search engine. In-cluster
only, with no ingress:
`http://searxng.searxng.svc.cluster.local:8080/search?q=<query>&format=json`

```sh
kubectl -n searxng create secret generic searxng-secret \
  --from-literal=SEARXNG_SECRET="$(openssl rand -hex 32)"
kubectl apply -f apps/searxng/searxng.yaml
```

- Config is `settings.yml` in the ConfigMap (`use_default_settings: true`
  plus overrides). After editing, bump the `settings-revision` annotation
  so the pod restarts.
- `json` output is enabled (Open WebUI needs it). The rate limiter is off
  because only in-cluster clients can reach it.
- SearXNG only searches. It sends its own browser-like user agents to the
  engines and only lets you set `outgoing.useragent_suffix`. Page fetching
  and its user agent are configured in Open WebUI (see
  `apps/open-webui/README.md`).
- On first test, DuckDuckGo returned a CAPTCHA; Brave and Google CSE
  answered. Use `engines:` in `settings.yml` to enable or disable engines.
