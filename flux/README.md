# flux/

The `GitRepository` and the `Kustomization`s that drive this cluster.

## What is NOT here: the controllers themselves

There is no `gotk-components.yaml`. Flux was installed out of band, so
`source-controller`, `kustomize-controller` and `helm-controller` are **not managed by
this repository** — nothing you write here will change their Deployments.

That matters when the cluster is unwell, because their defaults are wrong for this
host: each ships with `limits: {cpu: 1, memory: 1Gi}`, which on a **1 vCPU / 4 GB**
node is four cores and four gigabytes of limits on a machine that has one and four.

### Measured, 2026-09-09

Real usage, not limits:

| Controller | CPU | Memory | Limit it was given |
|---|---|---|---|
| `source-controller` | 2m | 139Mi | 1000m / 1Gi |
| `kustomize-controller` | 4m | 37Mi | 1000m / 1Gi |
| `helm-controller` | 1m | 22Mi | 1000m / 1Gi |
| `source-watcher` | 2m | 16Mi | 1000m / 1Gi |

So the limits were never what the controllers *use* — they are what the controllers
are *allowed* to take during a spike, and on one core one controller spiking is the
whole machine. Capping them is insurance, not a cure.

### Capping them, imperatively

Until the components are adopted into Git, this is a one-off. Nothing reverts it,
because Flux does not own these Deployments:

```bash
for c in source-controller kustomize-controller helm-controller; do
  kubectl -n flux-system set resources deploy/$c \
    --limits=cpu=300m,memory=384Mi --requests=cpu=50m,memory=64Mi
done
```

384Mi is ~2.5× what `source-controller` actually uses, which is the one that needs
headroom — it holds the git artifact. Set it lower and you trade restarts-from-CPU
for restarts-from-OOM, which is a worse trade.

### `source-watcher` is not part of Flux

`ghcr.io/fluxcd/source-watcher` is the **example controller from the "write your own
Flux controller" tutorial**. It watches `GitRepository` events and logs them. It does
nothing for this cluster, and it had accumulated 135 restarts by 2026-09-09:

```bash
kubectl -n flux-system delete deploy/source-watcher
```

### Doing it properly, later

The durable fix is the standard bootstrap layout: commit `gotk-components.yaml` and a
`kustomization.yaml` carrying the resource patches, then let a Kustomization sync
`flux-system`. That pins the Flux version in Git — which is the point, and also the
reason not to do it in the middle of an incident: if the committed version differs
from what is installed, Flux upgrades or downgrades itself on the next reconcile.

## Why the intervals are wide

Every `Kustomization` here ran at `interval: 1m` with `timeout: 5m`. On a host with no
CPU to spare, a reconcile that takes longer than a minute overlaps the next one and
they queue — which is exactly how `flux-system` ended up stuck reporting
*"Reconciliation in progress"* while the node was thrashing.

| | interval | wait |
|---|---|---|
| `gitrepository` | 5m | — |
| `flux-system`, `infrastructure` | 10m | `true` |
| `tools` | 10m | `false` |
| `qa`, `dev`, `prod` | 5m | `false` |

`wait` is off wherever nothing depends on ordering. Nothing in this repository uses
`dependsOn`, so on those Kustomizations `wait: true` bought no sequencing at all — it
only made the controller poll every applied object for readiness on every pass. It
stays on for `flux-system` and `infrastructure`, which apply the CRDs and the
databases that everything else assumes exist.

**Wider intervals are not slower deploys.** A push that has to land now:

```bash
flux reconcile source git gitops
flux reconcile kustomization qa --with-source
```

## The host

1 vCPU / 4 GB, shared with a Docker Compose production stack — see
`astra/docs/03-infra-e-deploy.md §6`. On 2026-09-09 the box was at 195 MB available
with **zero swap**, `kswapd0` holding 13% of the core, and a load average of 28.

Worth keeping in view when reading any of the above: all the pods in this cluster
together were using **737 MiB and 45m of CPU** at that moment. The Kubernetes side is
not what fills this machine.
