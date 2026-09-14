# actions-runner-controller (ARC)

Self-hosted GitHub Actions runners for `emcniece/Glyphdex`, running on this
k3s cluster instead of GitHub-hosted `ubuntu-latest` runners. The point is
billing: GitHub only meters/bills Actions minutes for GitHub-hosted runners —
a job that runs on a self-hosted runner costs GitHub Actions minutes **zero**,
only your own compute. Added 2026-09-14 after Glyphdex's release-image builds
(5 parallel `ubuntu-latest` jobs on every push to `main`) exhausted the
account's monthly minutes.

Uses the actively-maintained [`gha-runner-scale-set`
mode](https://github.com/actions/actions-runner-controller) (the
`actions/actions-runner-controller` project, Helm-chart based) — not the
older `summerwind/actions-runner-controller` CRD project, which is
deprecated.

## Architecture

Two Helm releases:

1. **Controller** (`controller-values.yaml`) — one per cluster, manages every
   runner scale set. Namespace: `arc-systems`.
2. **Runner scale set** (`runner-values.yaml`) — one per repo/workload that
   wants its own runners. Namespace: `arc-runners`. This one is scoped to
   `githubConfigUrl: https://github.com/emcniece/Glyphdex` specifically —
   **repo-scoped, not org-scoped** — so only Glyphdex's workflows can queue
   work onto this hardware. Add a second `helm install` with a different
   release name + `githubConfigUrl` + `runnerScaleSetName` if another repo
   needs its own pool later; don't widen this one to the whole account.

A workflow opts in with `runs-on: glyphdex-arc-runners` (the
`runnerScaleSetName` in `runner-values.yaml`) in place of `ubuntu-latest`.

## Security note — this is a public repo

A self-hosted runner registered against a public repo will execute whatever
workflow YAML a triggering event brings with it, on your hardware, with
whatever the job's steps can reach (this cluster's network, at minimum). The
mitigations in place / to keep in place:

- **Only trigger on `push` to `main`, never on `pull_request`.** A PR from
  anyone (including a fork) is untrusted input; only pushes to `main` are
  something only the repo owner can produce. Glyphdex's
  `.github/workflows/release.yml` already only triggers on `push:
  branches: [main]` + tags + `workflow_dispatch` — keep it that way. Do NOT
  add `pull_request` or `pull_request_target` triggers to any workflow that
  targets `runs-on: glyphdex-arc-runners`.
- Repo Settings → Actions → General → "Fork pull request workflows" should
  stay on the restrictive default (requires approval for first-time
  contributors) as a second layer, even though (1) already covers it for
  this specific runner.
- The runner pods run with `containerMode: dind` (privileged, for Docker
  builds) — privileged pods can affect the node they're scheduled on, so
  don't casually point untrusted workflows at this scale set later.

## Prerequisites

**A GitHub PAT with repo admin access** (to register/deregister runners).
Fine-grained token, scoped to just this repo, with **Administration:
read and write** permission — that's the minimum ARC needs. Create one at
<https://github.com/settings/personal-access-tokens/new>, "Only select
repositories" → `emcniece/Glyphdex`.

(A GitHub App is the more robust long-term option — no token expiry, works
across an org — but is more setup for a single personal repo. Revisit if
more repos get their own runner scale sets.)

## Install

```sh
export KUBECONFIG=~/.kube/config-homelab
CHART_VERSION=0.14.2   # pin — check https://github.com/actions/actions-runner-controller/releases for newer

# 1. Controller (once per cluster)
helm upgrade --install arc \
  --namespace arc-systems --create-namespace \
  -f infra/actions-runner-controller/controller-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "$CHART_VERSION" --wait

# 2. GitHub credential — created directly, never written to a file or git.
#    Paste your PAT when prompted; it never appears in shell history this way.
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
read -rsp 'GitHub PAT: ' GH_PAT && echo
kubectl create secret generic glyphdex-arc-github-secret \
  --namespace arc-runners \
  --from-literal=github_token="$GH_PAT"
unset GH_PAT

# 3. Runner scale set (one per repo)
helm upgrade --install glyphdex-runners \
  --namespace arc-runners \
  -f infra/actions-runner-controller/runner-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$CHART_VERSION" --wait
```

## Point Glyphdex's workflows at it

In `emcniece/Glyphdex`, change the jobs you want to move off GitHub-hosted
minutes:

```diff
- runs-on: ubuntu-latest
+ runs-on: glyphdex-arc-runners
```

Start with `.github/workflows/release.yml` (the expensive one — 5 parallel
Docker-build jobs on every push) before `CI.yml`, and confirm a real push
schedules and completes a job before switching everything over.

## Verify

```sh
kubectl -n arc-systems get pods                 # controller running
kubectl -n arc-runners get pods                  # 0 runner pods at idle (minRunners: 0) — expected
kubectl -n arc-runners get autoscalingrunnersets  # the scale set object, should be healthy
# push to main / trigger a workflow that uses runs-on: glyphdex-arc-runners, then:
kubectl -n arc-runners get pods --watch           # a runner pod should appear within ~10-30s
```

The scale set should also show as an available runner group under Glyphdex's
repo Settings → Actions → Runners on GitHub.

## Troubleshooting

- **No runner pod appears on a triggered job**: check the controller logs
  (`kubectl -n arc-systems logs deploy/arc-gha-rs-controller`) and the
  listener pod's logs in `arc-runners` — a bad PAT or wrong
  `githubConfigUrl` shows up there first.
- **Job starts but the Docker build step fails**: dind sidecar didn't come up
  — check `kubectl -n arc-runners describe pod <runner-pod>` for a blocked
  privileged-pod admission (PodSecurity policy) or resource pressure on the
  node it landed on.
- **Runner pod evicted / OOMKilled mid-build**: raise
  `template.spec.containers[0].resources` in `runner-values.yaml` — the
  extractor image (torch) and the multi-arch node images are the heaviest
  builds.

## Uninstall

```sh
helm -n arc-runners uninstall glyphdex-runners
kubectl -n arc-runners delete secret glyphdex-arc-github-secret
helm -n arc-systems uninstall arc
```

Revert any `runs-on: glyphdex-arc-runners` back to `ubuntu-latest` in
Glyphdex's workflows first, or pushes will queue with no runner to pick them
up.

## References

- <https://github.com/actions/actions-runner-controller>
- <https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/deploy-runner-scale-sets-with-actions-runner-controller>
