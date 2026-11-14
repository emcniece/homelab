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

Models use these on their own. Native function calling is the default in
0.13, and `models.default_metadata` (mirrored in `DEFAULT_MODEL_METADATA`)
pre-selects the **Web fetch** tool (`server:web-fetch`) and turns on **Web
Search** in every new chat. The built-in `search_web`/`fetch_url` tools need
all of: `web.search.enable`, the model's `web_search` capability, and the
chat's Web Search toggle.

Without any tools, `qwen3-coder` still tries to call one mid-answer, and the
reply ends at a bare `<tool_call>`.

As of 2026-11-11 all 378 settings are saved in `webui.db`, so env changes to
existing settings no longer apply. Edit them in Admin Panel, or in the
`config` table (back up first, then restart the pod).

## Performance tuning for the GPU Ollama

On this hardware Open WebUI's cost is prompt size and request count, not
its own CPU use. Ollama has one slot and one resident model, and reads
prompts at ~1000 tok/s on the 8060S (generation ~55-73 tok/s).

| Setting | Value | Why |
|---|---|---|
| `builtinTools` in `models.default_metadata` | only `time`, `user_input`, `files`, `web_search`, `code_interpreter` | Tool schemas are re-sent every prompt. All 18 categories plus Web fetch = 12,220 tokens / 13.9 s before the first token; trimmed = 3,298 tokens / 2.6 s (measured 2026-11-11). |
| `task.tags.enable`, `task.follow_up.enable` | false | Extra requests after every answer queue on the single slot and evict the cached prompt, forcing the next turn to re-read the whole chat. |
| `task.query.*.enable` | false | Only used by legacy function calling. |
| `task.model.default` | "" (the chat's own model) | A different task model would swap the 18 GB chat model out and back in. |
| `web.fetch.max_content_length` | 24000 chars | Was unlimited. Keeps one page to ~6k tokens. |
| `web.search.bypass_embedding_and_retrieval` | true | No CPU embedding pass over fetched pages. |
| `rag.embedding_engine` | "" (local CPU MiniLM) | Ollama embeddings would load a second model and, with `OLLAMA_MAX_LOADED_MODELS=1`, evict the chat model. |
| `models.default_params` | {} | Never set `num_ctx` per model. A value different from Ollama's 32768 forces a model reload. |

Per-category token costs (qwen3-coder tokenizer): knowledge 2151, memory
1523, calendar 1407, skills 1382, automations 1260, files 1137, notes 1131,
channels 701, subagents 658, image_generation 570, chats 532, tasks 512,
time 498, user_input 438, tools 425, web_search 412, notifications 346,
code_interpreter 312; Web fetch server (6 tools) 1677.

## Coding: Sandbox terminal, Context7, and the Coder model

| Piece | What | Config |
|---|---|---|
| **Sandbox** | Open Terminal (`apps/open-terminal/`): shell, files, builds | `TERMINAL_SERVER_CONNECTIONS` (id `sandbox`) |
| **Context7** | Remote MCP, current library docs (`resolve-library-id`, `query-docs`) | `TOOL_SERVER_CONNECTIONS` (type `mcp`, id `context7`, tool id `server:mcp:context7`) |
| **Coder** | Workspace model: `qwen3:30b-a3b` + Sandbox + Context7 + Web fetch, short coding system prompt | `model` table, id `coder` |
| **Coder (gpt-oss)** | Same tools and prompt on `gpt-oss:120b`: stronger, about half the speed | `model` table, id `coder-oss` |

Keys (`OPEN_TERMINAL_API_KEY`, `CONTEXT7_API_KEY`) are in the gitignored
`01-secret.yaml` and substituted into the connection JSON with `$(VAR)`.
Context7 isn't in `models.default_metadata`, so other chats don't pay for its
tool schemas.

**Why Coder isn't qwen3-coder.** With prose before a tool call, qwen3-coder
often leaves out the `<tool_call>` opener. Ollama's qwen3coder (0.40.12-0.40.16)
parser (unchanged upstream as of 0.40.17-rc0) then returns the call as text,
and the chat ends on `...</function></tool_call>`.

Measured with Context7's schemas, 6 trials each (2026-11-11):

| Model | Tool names | Proper tool calls |
|---|---|---|
| qwen3-coder:30b | hyphenated (as Context7 ships them) | 1/6 |
| qwen3-coder:30b | underscores | 4/6 |
| qwen3:30b-a3b | hyphenated | 6/6 |
| gpt-oss:120b | hyphenated | 6/6 |
| qwen3.8-flash-next (UD-Q3_K_XL) | hyphenated | 6/6 |

Speed on the 8060S (Vulkan, 32k context, 100% GPU): gpt-oss:120b (64 GB
resident) reads prompts at ~630 tok/s and generates ~34 tok/s; the 30B
models ~1000 and ~55-73; qwen3.8-flash-next ~490 and ~25. Only one model stays loaded, so switching between
them costs a reload.

qwen3:30b-a3b (JSON tool calls) and gpt-oss:120b (harmony format) don't hit this. Use
plain `qwen3-coder:30b` for code writing without tools.

## Possible follow-up: sign in with Pocket ID

Open WebUI supports OIDC, and `apps/pocket-id` (id.emc2.build) already serves
Outline. It needs a client registered in Pocket ID, then `ENABLE_OAUTH_SIGNUP`,
`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` (in the secret),
`OPENID_PROVIDER_URL=https://id.emc2.build/.well-known/openid-configuration`
and `OAUTH_PROVIDER_NAME=Pocket ID`.
