# Claude Code Router (CCR)

Model gateway for Claude Code at **https://ccr.lab.emc2.build** (LAN only,
192.168.0.0/16). Claude Code points `ANTHROPIC_BASE_URL` here. CCR sends
the main session to one provider and lets sub-agents pick others, such as
the GPU Ollama (`apps/ollama/`).

Upstream: https://github.com/musistudio/claude-code-router (MIT). Image:
`musistudio/claude-code-router:3.1.3` (Docker Hub, built by the project's
release workflow). Upstream Docker guide:
https://ccrdesk.top/en/guides/docker/

```sh
cp apps/claude-code-router/01-secret.example.yaml apps/claude-code-router/01-secret.yaml   # gitignored
# set CCR_WEB_AUTH_TOKEN (openssl rand -hex 32), then:
kubectl apply -f apps/claude-code-router/00-namespace.yaml \
  -f apps/claude-code-router/01-secret.yaml \
  -f apps/claude-code-router/05-entrypoint-fix.yaml \
  -f apps/claude-code-router/10-claude-code-router.yaml \
  -f apps/claude-code-router/50-ingress.yaml
```

Apply the files by name. `kubectl apply -f apps/claude-code-router/` would
also apply the example secret. It sorts first, so the real secret still
wins, but don't rely on it.

## Token leak in the 3.1.3 image (patched here)

In 3.1.3, the Nginx config written by the entrypoint redirects `/` and a
token-less `/pages/home/index.html` to `...?ccr_web_token=<the real
CCR_WEB_AUTH_TOKEN>`. Anyone who loads the page gets admin, and through it
the provider credentials. Confirmed on this deployment 2026-11-14. Upstream
fixed it in `ec0cb4fec` (2026-10-09), but no release includes the fix yet.

`05-entrypoint-fix.yaml` mounts the entrypoint from that commit over
`/usr/local/bin/ccr-docker-entrypoint`. The image's entrypoint is
byte-identical to v3.1.3's `docker/entrypoint.sh`, and the commit changes
only that file. Drop the ConfigMap after upgrading to a release with the
fix.

Verified after the patch:
- `/` redirects with no token.
- The page body has no token.
- The management RPC returns 401 with no token or a wrong one.

The token exposed before the patch was rotated. The CCR server still logs
its own startup URL with the token once, so pod logs (and Loki) count as
sensitive.

## Three credentials

| Credential | Purpose | Where |
|---|---|---|
| `CCR_WEB_AUTH_TOKEN` | Management UI / RPC | Secret `ccr-secret`. Open `https://ccr.lab.emc2.build/?ccr_web_token=<token>` |
| CCR client key | Claude Code to CCR | UI > **API Keys** |
| Provider credentials | CCR to Anthropic, Ollama, ... | UI > **Providers**, stored in SQLite on the `ccr-data` PVC |

## First-time setup (in the UI)

1. **Providers.**
   - **Ollama:** protocol `anthropic_messages`, base URL
     `http://ollama.ollama.svc.cluster.local:11434` (in-cluster), any key
     (Ollama ignores it). Models: `qwen3:30b-a3b` and `gpt-oss:120b`, which
     passed 6/6 tool-call trials. Not `qwen3-coder:30b`: its tool calls
     break in Ollama's parser (`apps/open-webui/README.md`).
   - **Claude:** an Anthropic API key (Console billing), entered yourself.
     CCR can also import a Claude Code subscription login, but on a server
     that means copying your OAuth token into this pod.
2. **Models.** Give each model you want sub-agents to pick a
   **Description** (task fit, speed, limits), for example "qwen3:30b-a3b:
   local, fast; file search, summaries, small edits". Without
   descriptions, CCR doesn't route sub-agents.
3. **Agent Config.** Enable Claude Code, with a Claude model as the
   default.
4. **API Keys.** Create a client key.
5. **Server.** Start the gateway. `https://ccr.lab.emc2.build/health`
   should return 200 (it's 502 until steps 1-5 are done).

## Using it from Claude Code

Use a separate command so plain `claude` stays direct to Anthropic:

```sh
# ~/.zshrc; CCR_CLIENT_KEY from step 4, kept out of shell history
claude-ccr() {
  ANTHROPIC_BASE_URL=https://ccr.lab.emc2.build \
  ANTHROPIC_AUTH_TOKEN="$CCR_CLIENT_KEY" ANTHROPIC_API_KEY="" \
  claude "$@"
}
```

How sub-agent routing works: CCR adds the described models to the
`Agent`/`Task` tool description. Claude starts each sub-agent prompt with
`<CCR-SUBAGENT-MODEL>provider/model</CCR-SUBAGENT-MODEL>`, and CCR removes
the tag and routes that request. If Claude leaves the tag out, the
sub-agent stays on the default model. Request logs show
`builtin:claude-code-subagent` when routing happened.

Caveats:
- Anthropic doesn't support routing Claude Code to non-Claude models.
- Remote Control is off while `ANTHROPIC_BASE_URL` isn't Anthropic's.
- Ollama keeps one model loaded, so mixing local models means reloads.
- Request logs (`request-logs.sqlite` on the PVC) hold prompts and
  responses.
