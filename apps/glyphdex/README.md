# Glyphdex Deployment

Glyphdex is a hybrid search engine for OCR'd document corpora, with mandatory
source citations. Reference deployment: Langford, BC municipal documents.

Source of truth for the chart and app code is a separate repo:
https://github.com/emcniece/Glyphdex (`deploy/k8s/glyphdex` Helm chart,
`deploy/k8s/glyphdex/values-homelab.yaml` for this cluster's overrides,
`docs/DEPLOY.md` for the full runbook).

## Architecture

- `web` (Fastify + dashboard), `mcp-server` (9 MCP tools over streamable HTTP),
  `worker` (graphile-worker ingest queue), `extractor` (no egress — untrusted
  PDF processing), `capture` (Playwright, HTTP/S egress only), `ollama`
  (embeddings, `nomic-embed-text`).
- Postgres: CloudNativePG (`cnpg-system`, installed cluster-wide), pgvector +
  pg_trgm, 2 instances on `csi-rbd-sc`.
- Artifact store: `driver: fs`, a ReadWriteMany `csi-cephfs-sc` PVC shared by
  `web` + `worker` — same pattern as Immich's library volume. No S3/MinIO in
  this cluster.

## Access

- `https://gspr.emc2.build` — dashboard
- `https://mcp.gspr.emc2.build/mcp` — MCP streamable-HTTP endpoint (per-key
  `gsk_…` auth)

No DNS record was needed — both hosts resolve via the existing `*.emc2.build`
wildcard CNAME straight to the home public IP (same as `stegastamp.emc2.build`),
which port-forwards to the Traefik LoadBalancer. TLS via the existing
`letsencrypt-prod` ClusterIssuer, same as `stegastamp`'s ingress.

## Node placement

k3s-01/02/03 are tainted control-plane, so pods already land only on the
k3s-04/05/06 workers. The chart's `common.affinity` sets a soft
(`preferredDuringSchedulingIgnoredDuringExecution`) pod anti-affinity on
`app.kubernetes.io/name: glyphdex`, spreading its pods across those three
workers instead of bunching on one.

## Images

CI (`.github/workflows/release.yml` in the Glyphdex repo) builds and pushes
`ghcr.io/emcniece/glyphdex-{web,mcp-server,worker,capture,extractor,postgres}`
on every push to `main`. The GHCR packages are **private** — the `ghcr-pull`
secret in the `glyphdex` namespace (a `kubernetes.io/dockerconfigjson` built
from a `gh auth token` with `read:packages` scope) is required.

## First install (already done)

```sh
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.1.yaml

kubectl create namespace glyphdex
kubectl -n glyphdex create secret generic glyphdex-secrets \
  --from-literal=SESSION_SECRET=<random> \
  --from-literal=FINGERPRINT_SECRET=<random>
kubectl -n glyphdex create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<gh-user> \
  --docker-password=<gh-token-with-read:packages>

helm upgrade --install glyphdex deploy/k8s/glyphdex \
  --namespace glyphdex \
  -f deploy/k8s/glyphdex/values-homelab.yaml \
  --wait --timeout 20m
```

(run from a checkout of the Glyphdex repo). See its `docs/DEPLOY.md` for
upgrades, rollback, and failure modes.

## Note: no kube-prometheus-stack / KEDA in this cluster

`metrics.serviceMonitor.enabled` and `worker.keda.enabled` are both `false` in
`values-homelab.yaml` since neither CRD exists here yet.
