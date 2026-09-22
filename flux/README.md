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

> ✅ **Applied 2026-09-15**, together with the `source-watcher` deletion below. What it
> moved, measured on the node:
>
> | | Before | After |
> |---|---|---|
> | CPU limits | 5300m (530%) | 2200m (220%) |
> | Memory limits | 5418Mi (138%) | **2474Mi (63%)** |
>
> Memory limits stopped being overcommitted, which is the half that matters: at 138% the
> kernel could kill a process at any moment, and that is where `coredns`' 100 restarts and
> `traefik`'s 107 came from.
>
> The largest single CPU limit left is `astra-api` at 750m on a one-core node. That one is
> deliberate — `astra/docs/03-infra-e-deploy.md §6` sizes it — and it is the workload the
> cluster exists to run.

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
Flux controller" tutorial**. It watches `GitRepository` objects, downloads the artifact
when the revision changes, and logs what it found. It reconciles nothing, deploys
nothing, and nothing in this cluster depends on it. 135 restarts by 2026-09-09; 149 by
2026-09-15.

**It was applied by hand**, which is why nothing in Git mentions it — the Deployment
carries `kubectl.kubernetes.io/last-applied-configuration` from 2026-07-23 and none of
the `kustomize.toolkit.fluxcd.io/*` labels that would mean Flux owns it. So `kubectl
delete` is the removal, and nothing brings it back.

Two details found on 2026-09-15 that make it worse than "idle":

- `priorityClassName: system-cluster-critical`. Under memory pressure the kubelet
  protects this **ahead of** real workloads. A tutorial example holds the highest
  eviction protection on the box.
- `--events-addr=http://notification-controller.flux-system.svc.cluster.local./`, and
  **there is no `notification-controller` Deployment** — only an orphan Service with no
  endpoints behind it. Every event it emits fails to send.

```bash
kubectl -n flux-system delete deployment/source-watcher service/source-watcher serviceaccount/source-watcher
```

> Other orphans from the original install are still there — `service/notification-controller`,
> `service/webhook-receiver`, `serviceaccount/image-automation-controller`,
> `serviceaccount/image-reflector-controller` — all without Deployments. They cost no CPU
> and no memory, so they are tidying, not relief.

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

### 2026-09-15 — what the starvation actually broke

None of the above had been applied, and the box was in the same state:

```
loadavg 3.73 1.19 0.74     on one core
MemAvailable  392 MB       of 4009 MB
SwapTotal     0
Committed_AS  8.4 GB       against a 2 GB CommitLimit
```

Restart counts had kept climbing: `coredns` 100, `traefik` 107, `helm-controller` 135,
`source-watcher` 149. The node itself went `NotReady` and came back at 19:34 that day.

**The new part is that this stopped being noise and started breaking a feature.** Two
failures in `astra-api`, both downstream of the same starvation:

```
HikariPool-1 - Thread starvation or clock leap detected (housekeeper delta=54s114ms)
HikariPool-1 - Thread starvation or clock leap detected (housekeeper delta=1m39s845ms)
HikariPool-1 - Connection is not available, request timed out after 421980ms (total=0, active=0, idle=0, waiting=0)
```

1. **The notification outbox stopped.** `OutboxSweeper` runs every 20s and could not open
   a transaction — seven minutes waiting for a connection from an empty pool. No push
   notification can leave this cluster while that is true.

2. **The event chat's WebSocket never connected**, and the server's own stats said why:

   ```
   WebSocketSession[0 current, 5 total, 0 closed abnormally (2 transport error)],
   stompSubProtocol[processed CONNECT(0)-CONNECTED(0)-DISCONNECT(0)]
   ```

   Five handshakes **succeeded** — so DNS, TLS, Traefik and the STOMP subprotocol are all
   fine — and **zero CONNECT frames were ever processed**. A JVM that does not run for 54
   seconds does not read the frame the client sent on open. The socket dies, and the phone
   reports `1006 Software caused connection abort`, which reads exactly like a network
   fault and is not one.

   That cost three rounds of client-side diagnosis — DNS, proxies blocking the upgrade,
   the STOMP library — while `WebSocketMessageBrokerStats` had been printing the answer
   into this log every thirty minutes the whole time.

**Order of work, cheapest first.** The first two are the documented ones above; only the
last is a cure:

| | Why |
|---|---|
| `delete deploy/source-watcher` | A tutorial example. 149 restarts, 1 CPU / 1 Gi of limits, does nothing here |
| Cap the three real controllers | Insurance against one spike owning the only core |
| **Give the host swap** | Zero swap at 392 MB available is why things are OOM-killed instead of merely slowed. A host change, not a cluster one |
| Move the Compose stack off, or resize the box | The pods are not what fills this machine. Everything above is palliative |
