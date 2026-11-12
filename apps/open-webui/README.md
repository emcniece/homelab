# Open WebUI

Browser chat UI for the GPU Ollama in `apps/ollama/`, at
**https://chat.lab.emc2.build** (LAN only, 192.168.0.0/16).

```sh
cp apps/open-webui/01-secret.example.yaml apps/open-webui/01-secret.yaml   # fill in; gitignored
kubectl apply -f apps/open-webui/
```

- Backend: `OLLAMA_BASE_URL=http://ollama.ollama.svc.cluster.local:11434`
  (in-cluster, so Ollama's own ingress isn't involved).
- State: SQLite, uploads, the RAG index and the embedding-model cache are on
  a 10Gi Ceph RBD PVC (`open-webui-data`). The pod isn't tied to k3s-07.
- Accounts: the **first sign-up becomes admin**. Later sign-ups are `pending`
  until approved in Admin Panel > Users. To close sign-ups entirely, set
  `ENABLE_SIGNUP=false` after creating your accounts.
- Models: pull from the UI (Admin Panel > Settings > Models) or with
  `kubectl -n ollama exec deploy/ollama -- ollama pull <model>`.
- First start takes ~3.5 min (embedding model download + migrations). The
  `startupProbe` allows up to 10 min.

## Web search and page fetching

| Path | Who fetches | Customizable |
|---|---|---|
| Web Search toggle / built-in `search_web` | SearXNG (`apps/searxng/`) searches; Open WebUI's loader fetches result pages | engines, timeouts and proxy in SearXNG `settings.yml` |
| `#https://…` in chat, built-in `fetch_url` | Open WebUI web loader | `USER_AGENT`, `WEB_LOADER_TIMEOUT` (env) |
| **Web fetch** tool server (`20-fetch-tools.yaml`) | `mcp-fetch-server` behind `mcpo` | **per request:** any headers (incl. `Cookie`, `User-Agent`), proxy, length/offset |

Settings precedence: env vars only seed the config. Anything saved in Admin
Panel > Settings is stored in `webui.db` (`config` table) and wins over
the env. `TOOL_SERVER_CONNECTIONS` had been saved as `[]` and had to be
deleted from that table before the env value applied.

Neither fetcher can reach LAN addresses: the web loader by default
(`ENABLE_LOCAL_WEB_FETCH=false`), and `mcp-fetch-server` always refuses
private and localhost targets.

To let a model use these on its own: Admin Panel > Settings > Models >
model > Advanced Params > **Function Calling = Native**. Then enable
**Web Search** and the **Web fetch** tool for the model, or per chat from
the `+` menu.

## Possible follow-up: sign in with Pocket ID

Open WebUI supports OIDC, and `apps/pocket-id` (id.emc2.build) already serves
Outline. It needs a client registered in Pocket ID, then `ENABLE_OAUTH_SIGNUP`,
`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` (in the secret),
`OPENID_PROVIDER_URL=https://id.emc2.build/.well-known/openid-configuration`
and `OAUTH_PROVIDER_NAME=Pocket ID`.
