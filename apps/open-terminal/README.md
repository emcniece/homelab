# Open Terminal

A sandboxed Linux machine that Open WebUI's models drive through a REST
API: shell commands, files, git, Node 22 / Python 3.12 builds, headless
Chromium. Upstream: https://github.com/open-webui/open-terminal (image
`ghcr.io/open-webui/open-terminal:0.17.7`, the full ~4 GB variant).

```sh
cp apps/open-terminal/01-secret.example.yaml apps/open-terminal/01-secret.yaml   # gitignored
# put the same key in apps/open-webui/01-secret.yaml as OPEN_TERMINAL_API_KEY
kubectl apply -f apps/open-terminal/
```

Open WebUI registers it through `TERMINAL_SERVER_CONNECTIONS`
(`apps/open-webui/10-open-webui.yaml`) as terminal **Sandbox**. In chat it
appears as the terminal picker, file browser and terminal panel. The
**Coder** workspace model selects it by default.

## Isolation

It runs whatever the model asks, so the pod is the boundary:

| Control | Where |
|---|---|
| Only the `open-webui` pod can connect (port 8000) | `20-networkpolicy.yaml` |
| Egress: DNS + public internet only; 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10 blocked (no LAN, no cluster services, no k8s API) | `20-networkpolicy.yaml` |
| No ServiceAccount token, no service-link env vars | `10-open-terminal.yaml` |
| API key required | Secret `open-terminal-secret` |
| Not privileged; 4 CPU / 6 GiB limits | `10-open-terminal.yaml` |

Verified 2026-11-11: GitHub returns 200; pve4 (192.168.10.6) and the Ollama
service time out; `/var/run/secrets` doesn't exist.

`user` has passwordless sudo inside the container (upstream image), so the
model can `apt-get install`. Only `/home/user` (20Gi Ceph RBD) survives a
restart; apt installs don't. The image's own iptables egress filter
(`OPEN_TERMINAL_ALLOWED_DOMAINS`) needs `NET_ADMIN` and isn't used.

No GitHub credentials are in the sandbox. To let it push, add a
fine-grained token scoped to specific repos (`gh auth login` inside the
terminal); it then lives in `/home/user/.config/gh`.
