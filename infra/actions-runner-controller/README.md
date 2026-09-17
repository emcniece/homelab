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

## Security note — this is a public repo (Glyphdex)

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
- The runner pods run a privileged dind (Docker-in-Docker) container for
  Docker builds — privileged pods can affect the node they're scheduled on,
  so don't casually point untrusted workflows at this scale set later.

`emcniece/moneymaker` (the other scale set — see "Add another repo's runner
scale set" below) is private, so a fork PR isn't possible and a PR in
general can only come from someone already granted repo access. The same
push-only mitigation is still applied to `moneymaker-arc-runners` anyway —
cheap to keep, and it stops mattering only if the repo's access list is
fully trusted forever, which isn't a bet worth making for a privileged dind
container.

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

# 1.5. DNS fix for the controller pod — see "DNS: the lab.emc2.build ndots
#      hijack" below. The controller chart has no values field for
#      dnsConfig, so this is a direct patch, NOT captured by the values
#      file — re-run it after every `helm upgrade` of the arc release
#      (it patches the live Deployment; a Helm upgrade re-renders the
#      full spec and drops it).
kubectl -n arc-systems patch deployment arc-gha-rs-controller --type=merge -p \
  '{"spec":{"template":{"spec":{"dnsConfig":{"nameservers":["8.8.8.8","1.1.1.1"],"options":[{"name":"ndots","value":"2"}]}}}}}'
kubectl -n arc-systems rollout status deployment/arc-gha-rs-controller

# 2. GitHub credential — created directly, never written to a file or git.
#    Paste your PAT when prompted; it never appears in shell history this way.
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
read -rsp 'GitHub PAT: ' GH_PAT && echo
kubectl create secret generic glyphdex-arc-github-secret \
  --namespace arc-runners \
  --from-literal=github_token="$GH_PAT"
unset GH_PAT

# 3. Shared pnpm-store + Playwright-cache PVCs — see "Caching" below for why
#    these are shared and the Docker cache isn't.
kubectl apply -f infra/actions-runner-controller/pnpm-store-pvc.yaml
kubectl apply -f infra/actions-runner-controller/playwright-cache-pvc.yaml

# 3.5. Docker Hub pull-through cache (registry mirror) — see "Caching" below.
kubectl apply -f infra/actions-runner-controller/registry-mirror.yaml
kubectl -n arc-runners rollout status deployment/glyphdex-arc-registry-mirror

# 4. Runner scale set (one per repo)
helm upgrade --install glyphdex-runners \
  --namespace arc-runners \
  -f infra/actions-runner-controller/runner-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$CHART_VERSION" --wait
```

## DNS: the lab.emc2.build ndots hijack

Hit live during the first install (2026-09-14): the controller and listener
pods' calls to `api.github.com` came back with a **Traefik** certificate
instead of GitHub's. Root cause is the same one already documented in
`apps/outline` and `apps/planka`: the node search domain includes
`lab.emc2.build`, which has a wildcard DNS record. With the default
`ndots:5`, a short external name like `api.github.com` (2 dots) gets tried
as `api.github.com.lab.emc2.build` *first* — which the wildcard record
answers, sending the request into the cluster's own ingress instead of the
real internet host. Confirmed the bare name resolves correctly on its own
(`kubectl run --rm -it --image=busybox:1.36 -- nslookup api.github.com`
returns GitHub's real IP) — this is purely the ndots search-list expansion
picking a wrong answer *before* the absolute name is ever tried.

Fix is a low `ndots` value (a name with at least that many dots resolves
absolute first), applied to every pod that talks to the GitHub API. Started
at `ndots:2` (apps/outline's / apps/planka's value); raised to `ndots:1`
(2026-09-14) after finding it wasn't low enough here — a bare `github.com`
(1 dot, from a plain `git clone`/checkout URL, not just `api.github.com`)
still hit the hijack under `ndots:2`. `ndots:1` means only a fully bare
single-label name (no dot at all) still goes through the search list, which
nothing this scale set does:

- **Controller** — no `dnsConfig` field in the chart's values schema, so
  it's a direct `kubectl patch` (see step 1.5 above). Must be re-applied
  after any `helm upgrade` of the `arc` release.
- **Listener pod** and **runner/dind pod** — `dnsConfig` set directly in
  `runner-values.yaml` (`listenerTemplate.spec.dnsConfig` /
  `template.spec.dnsConfig`), so these survive a normal `helm upgrade` of
  `glyphdex-runners`.

## Caching

The registry-based Docker layer cache (`cache-from`/`cache-to:
type=registry` in `release.yml`, chosen over `type=gha` for reasons in that
workflow's own history) plus one persistent volume:

### Docker layer cache: tried a node-local hostPath, reverted

Tried 2026-09-14: a node-local `hostPath` (`/var/lib/arc-docker-cache`)
mounted at `/var/lib/docker` in the `dind` container, deliberately *not* a
shared PVC — the reasoning at the time was that two `dockerd` processes
pointed at the same data root concurrently is unsupported by Docker, but a
second one starting against an already-locked path would just fail to
acquire the lock cleanly (job retries) rather than actually corrupting
anything. **That assumption was wrong in a way that mattered**: confirmed
live that containerd's boltdb metadata store doesn't fail fast on a lock
conflict — it blocks for ~15s ("waiting for response from boltdb open")
and then the whole `dind` sidecar fails to start, taking the runner pod
down with it. At `maxRunners: 8` across only 3 untainted nodes, concurrent
pods land on the same node constantly, so this took down most of a batch
at once (`kubectl -n arc-runners get pods` showed 6+ pods stuck
`Init:x/2`/`Error` simultaneously). **Reverted** — `dind` is back to the
chart's default ephemeral storage (plain `emptyDir`). If this gets
revisited, it needs either a genuinely per-runner-pod volume (no reuse
across pods at all, so no benefit) or a way to guarantee at most one dind
per node at a time (defeats concurrency) — the registry cache is the
supported mechanism for this and is the whole point of a "reduce GitHub
Actions minutes" project not needing a second, riskier caching layer badly
enough to be worth re-attempting soon.

- **`pnpm-store`** (PVC `glyphdex-arc-pnpm-store`, applied separately —
  see `pnpm-store-pvc.yaml` and the Install section) — CephFS
  `ReadWriteMany`, mounted at `/mnt/pnpm-store` in the `runner` container.
  Safe to share concurrently, unlike the Docker cache, because pnpm's
  store is content-addressed with its own file locking around writes —
  that's the whole point of pnpm's store design. `ci.yml`'s `node` job
  points pnpm's `store-dir` there on the self-hosted path
  (`pnpm config set store-dir /mnt/pnpm-store`, gated on
  `github.event_name == 'push'` since the PVC only exists on this scale
  set, not on `ubuntu-latest`).
- A `fix-pnpm-store-perms` initContainer (`busybox`, `chmod -R 0777`)
  runs before the `runner` container starts — a fresh/first-touch CephFS
  mount is root-owned by default, and the `runner` container isn't root.
- **`playwright-cache`** (PVC `glyphdex-arc-playwright-cache`, applied
  separately — see `playwright-cache-pvc.yaml`) — same CephFS
  `ReadWriteMany` pattern as `pnpm-store`, mounted at
  `/mnt/playwright-cache`. Safe to share for the same reason: Playwright
  writes each browser version to its own immutable, version-named
  subdirectory and skips the download entirely when that directory already
  exists — no shared mutable state a concurrent writer could corrupt.
  `ci.yml`'s `node` job points `PLAYWRIGHT_BROWSERS_PATH` there on the
  self-hosted path, the same way it points pnpm's `store-dir` at
  `pnpm-store`. A `fix-playwright-cache-perms` initContainer does the same
  CephFS ownership fix as `fix-pnpm-store-perms`.
- **Docker Hub pull-through cache** (`registry-mirror.yaml`: a `registry:2`
  Deployment + Service + a plain `local-path` PVC, one replica) — each
  ephemeral dind sidecar otherwise starts with a cold image cache and
  re-pulls the same images (`pgvector/pgvector:pg16` for the testcontainers
  DB suites, `prom/prometheus` for the `alerts` job) from Docker Hub on
  every single run. dind's `dockerd` is pointed at it with
  `--registry-mirror=http://glyphdex-arc-registry-mirror.arc-runners.svc.cluster.local:5000`
  (+ `--insecure-registry` for the same host, since the mirror is plain
  HTTP — internal cluster traffic only). This is **not** the shared-data-root
  risk described above: it's a separate, single-writer proxy service dind
  talks to over the network, not a second `dockerd` sharing dind's own
  `/var/lib/docker`. A `registry:2` proxy is built for concurrent reads, so
  this is safe at `maxRunners: 8` the way the reverted hostPath cache
  wasn't. One replica is fine — it's a cache, not a source of truth; losing
  the pod just means the next pull re-populates it from Docker Hub.

**Why this isn't just `containerMode: dind`** — the chart's own shorthand
(`containerMode: { type: "dind" }`) generates its own fixed `volumes` /
`initContainers` internally and silently ignores anything added under
those same keys in `template.spec` (only `template.spec.containers`,
merged by container name, is actually honored on top of it). Found this
the hard way: the (now-reverted) `docker-cache`/`pnpm-store` additions
rendered fine into the `AutoscalingRunnerSet` object itself (so `helm get
values` / `-o yaml` on it looked correct) but never made it into the
`EphemeralRunnerSet` the controller actually builds pods from.
`runner-values.yaml` now spells out the full dind pod spec by hand instead
(copied verbatim from what `containerMode: dind` used to generate, plus
`pnpm-store`) — see the comments in that file if the upstream chart
changes its dind-mode defaults and this needs re-syncing.

## Point Glyphdex's workflows at it

Already done for `emcniece/Glyphdex` — `.github/workflows/release.yml`
(all push-triggered) and `.github/workflows/ci.yml`
(`runs-on: ${{ github.event_name == 'push' && 'glyphdex-arc-runners' ||
'ubuntu-latest' }}`, since that workflow also triggers on `pull_request` —
see the Security note above for why that one needs the conditional instead
of switching outright). For a workflow that's always push-only, the plain
version is enough:

```diff
- runs-on: ubuntu-latest
+ runs-on: glyphdex-arc-runners
```

## Add another repo's runner scale set (moneymaker)

Second Helm release on the same controller, following the "repo-scoped, not
org-scoped" rule in Architecture above. `emcniece/moneymaker` is private
(unlike Glyphdex — see the Security note), which lowers the untrusted-PR
risk somewhat, but the same mitigation is applied anyway: only
`push`-triggered jobs get `runs-on: moneymaker-arc-runners`;
`pull_request`-triggered ones stay conditional the same way Glyphdex's
`ci.yml` does.

```sh
export KUBECONFIG=~/.kube/config-homelab
CHART_VERSION=0.14.2   # match whatever's installed for the arc controller

# 1. GitHub credential for this repo — a fine-grained PAT scoped to
#    "Only select repositories" → emcniece/moneymaker, Administration:
#    read and write. Create at
#    https://github.com/settings/personal-access-tokens/new
#    Paste when prompted; it never touches shell history or git this way.
read -rsp 'GitHub PAT (moneymaker): ' GH_PAT && echo
kubectl create secret generic moneymaker-arc-github-secret \
  --namespace arc-runners \
  --from-literal=github_token="$GH_PAT"
unset GH_PAT

# 2. Runner scale set
helm upgrade --install moneymaker-runners \
  --namespace arc-runners \
  -f infra/actions-runner-controller/runner-values-moneymaker.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$CHART_VERSION" --wait
```

No second controller, no second `pnpm-store`/`playwright-cache`/DNS-patch
step — those are cluster- or Glyphdex-specific and are either shared
(controller, registry mirror) or simply not needed (moneymaker has no
Node/Playwright workloads). `runner-values-moneymaker.yaml`'s own comments
cover what's trimmed and why.

Verify the same way as the Glyphdex scale set (substitute
`moneymaker-arc-runners` for `glyphdex-arc-runners` and
`moneymaker-runners` for `glyphdex-runners` in the Verify/Troubleshooting
commands below) — both scale sets show up side by side under
`kubectl -n arc-runners get autoscalingrunnersets` and in each repo's own
Settings → Actions → Runners page.

## Verify

```sh
kubectl -n arc-systems get pods                 # controller + listener pod, both Running
kubectl -n arc-runners get pods                  # 0 runner pods at idle (minRunners: 0) — expected
kubectl -n arc-runners get autoscalingrunnersets  # the scale set object, should be healthy
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener --tail=20
  # should show "Getting next message" — it's connected and polling GitHub
# push to main / trigger a workflow that uses runs-on: glyphdex-arc-runners, then:
kubectl -n arc-runners get pods --watch           # a runner pod should appear within ~10-30s
```

Note the listener pod runs in `arc-systems` (the controller's namespace),
not `arc-runners` — only the ephemeral runner/dind pods run in `arc-runners`.

The scale set should also show as an available runner group under Glyphdex's
repo Settings → Actions → Runners on GitHub.

## Troubleshooting

- **Controller/listener logs show a TLS cert error mentioning `*.traefik.*`
  when calling `api.github.com`**: the ndots DNS hijack above — check the
  fix is actually applied (`kubectl -n arc-systems get deploy
  arc-gha-rs-controller -o jsonpath='{.spec.template.spec.dnsConfig}'`
  should show the patch; it's dropped by every `helm upgrade` of the
  controller).
- **Listener pod stuck `Terminating` with `FailedMount` events referencing a
  Secret/ServiceAccount that "not found"**: hit this once after a
  `runner-values.yaml` change forced the listener to recreate — the
  controller's cleanup deleted the listener's ServiceAccount/config Secret
  before the old pod's volumes finished unmounting, deadlocking the
  termination (pod can't finish tearing down → controller won't remove the
  finalizer → but it already deleted the SA/Secret the pod needs). Break it
  with a force-delete, which lets the controller recreate everything clean:
  `kubectl -n arc-systems delete pod <listener-pod> --grace-period=0 --force`.
- **No runner pod appears on a triggered job**: check the controller logs
  (`kubectl -n arc-systems logs deploy/arc-gha-rs-controller`) and the
  listener pod's logs (`kubectl -n arc-systems logs -l
  app.kubernetes.io/component=runner-scale-set-listener`) — a bad PAT or
  wrong `githubConfigUrl` shows up there first.
- **Job starts but the Docker build step fails**: dind sidecar didn't come up
  — check `kubectl -n arc-runners describe pod <runner-pod>` for a blocked
  privileged-pod admission (PodSecurity policy) or resource pressure on the
  node it landed on.
- **Runner pod evicted / OOMKilled mid-build**: raise
  `template.spec.containers[0].resources` in `runner-values.yaml` — the
  extractor image (torch) and the multi-arch node images are the heaviest
  builds.
- **A `runner-values.yaml` change (new volume, resources, etc.) doesn't
  show up on new runner pods**, even though `helm upgrade` succeeded and
  `kubectl -n arc-runners get autoscalingrunnerset ... -o yaml` shows the
  change correctly: the controller only rolls a new `EphemeralRunnerSet`
  when its computed spec hash changes *and* the scale set isn't currently
  busy — while runners are actively running jobs, a spec-only change can
  sit un-rolled for a while. Check the `EphemeralRunnerSet`'s age
  (`kubectl -n arc-runners get ephemeralrunnerset -o
  jsonpath='{.items[0].metadata.creationTimestamp}'`) against your `helm
  upgrade` time; if it's stale, either wait for the in-flight jobs to
  finish (it rolls over on its own once idle — this is what happened
  2026-09-14, no manual fix needed) or, if nothing is running,
  `kubectl -n arc-runners delete ephemeralrunnerset --all` to force an
  immediate recreation from the current `AutoscalingRunnerSet` spec.
  **Never delete it while a runner pod from it is `Running`** — that pod is
  owned by the `EphemeralRunnerSet` and deleting the parent can cascade.

## Uninstall

```sh
helm -n arc-runners uninstall glyphdex-runners
kubectl -n arc-runners delete secret glyphdex-arc-github-secret
# moneymaker-runners is a separate release — uninstall independently,
# doesn't require also removing glyphdex-runners:
helm -n arc-runners uninstall moneymaker-runners
kubectl -n arc-runners delete secret moneymaker-arc-github-secret
# Only tear down the controller once every scale set release is gone —
# it's shared.
helm -n arc-systems uninstall arc
```

Revert any `runs-on: glyphdex-arc-runners` / `runs-on: moneymaker-arc-runners`
back to `ubuntu-latest` in the respective repo's workflows first, or pushes
will queue with no runner to pick them up.

## References

- <https://github.com/actions/actions-runner-controller>
- <https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/deploy-runner-scale-sets-with-actions-runner-controller>
