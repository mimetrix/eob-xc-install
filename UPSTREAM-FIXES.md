# Upstream Mantis Tawon EoB — requested fixes

A consolidated list of bugs and chart/operator gaps we've hit while running
Mantis EoB (Tawon operator + dashboard + streamstore + per-directive agent
DaemonSets) on F5 XC Customer Edge sites, and the shape of the fix we'd
like upstream so we can retire the local workarounds in
[`eob-xc-install`](README.md).

Each item is reproducible on stock k8s in some cases, and only on XC sites
in others. We've tagged each item accordingly. The XC-only items still
warrant upstream fixes — the issue is in Tawon, the symptom is exposed by
running on a real-world site profile.

Tested with `tawon-operator-3.0.0-rc4` and `tawon-operator-3.0.0-rc6`.

---

## 1. `cluster.local` hardcoded in operator + dashboard

**Surface:** XC-only, but symptom is environment-agnostic.

The operator's `StreamReconciler` and the dashboard's `pktsapi` (JetStream
consumer path) both build NATS endpoints by string-concatenating the
streamstore service name with `.tawon-operator.svc.cluster.local`.
XC cluster DNS uses a tenant-specific suffix (e.g.
`<site>.<tenant>.tenant.local`), so the resulting FQDN returns NXDOMAIN
and Stream reconciliation fails. The packet viewer in the dashboard shows
`pktsapi: tawon stream load failed / load nats jetstream stream: create
consumer: context deadline exceeded`.

We've also seen `KUBERNETES_CLUSTER_DOMAIN` env honored in some
controllers but not in `StreamReconciler` — that env var should not be
relied on as a workaround.

**Requested fix:** Either (a) read the cluster domain from each pod's
`/etc/resolv.conf` `search` line at startup and use it consistently, or
(b) accept the cluster domain as a single chart value
(`global.clusterDomain`) and thread it through everywhere the operator
and dashboard build FQDNs.

**Today's workaround:** `hostAliases` injection on both the operator and
dashboard pods, pointing the hardcoded `cluster.local` FQDN at the
streamstore Service ClusterIP. The dashboard's hostAliases was not
obvious — symptom (packet viewer error) doesn't mention DNS.

---

## 2. `removeExistingResourcesOnInit: true` is destructive on every restart

**Surface:** environment-agnostic. Anyone running Tawon in production
needs this flipped.

The chart default for `removeExistingResourcesOnInit` is `true`. The
operator interprets this as "on every startup, wipe every Dashboard,
StreamStore, ClusterDirective, Directive, Stream, Job, and PVC in the
target namespace before reconciling." This fires on every pod
replacement — rollouts, node drains, OOM kills, manual pod deletion —
not just CM-change-triggered restarts.

One operator pod replacement = full stack wipe. The combination with the
fact that the operator only reads the CM at startup (see #3) means a
single innocuous CM edit can take down the install.

**Requested fix:** Flip the chart default to `false`. Anyone who actually
wants the destructive behavior can opt in explicitly.

**Today's workaround:** We override `removeExistingResourcesOnInit: false`
in `values-override.yaml` for every fresh install, and our `install.sh`
will not proceed until this value is confirmed in the live ConfigMap.

---

## 3. Operator reads ConfigMap only at startup; templates CRs only on first creation

**Surface:** environment-agnostic.

Two related papercuts in the operator's reconcile loop:

- The operator does not `watch` its `tawon-config` ConfigMap. Editing the
  CM has no effect until the pod restarts.
- The operator templates `Dashboard`, `StreamStore`, and ClusterDirective
  CRs from the CM only on first creation. If a CR already exists,
  restarting the operator with a new CM does not update the CR; the CR
  remains as it was.

The reconciliation asymmetry between StreamStore (only re-templated on
create) and the agent DS (re-templated continuously, overrides external
patches — see #5) is confusing and undocumented.

**Requested fix:** Two options, in order of preference:

1. Watch the ConfigMap and reconcile on change.
2. At minimum, document the current behavior. The current behavior is
   surprising for users who treat the CM as a live source of truth.

For the CR-template asymmetry: pick one model (always re-template, or
never re-template) and apply consistently across StreamStore / Dashboard /
ClusterDirective. We'd prefer "always re-template from CM" matching how
the agent DS works.

---

## 4. ClusterRole missing `resourcequotas` verbs

**Surface:** environment-agnostic. Hits anyone with
`removeExistingResourcesOnInit: true`.

`tawon-operator-manager-role` in the rc4 chart does not grant any verbs
on the core `resourcequotas` resource. On startup, the cleanup phase
tries to list and delete ResourceQuotas in the target namespace:

```
error listing resource quotas: resourcequotas is forbidden:
User "system:serviceaccount:operators:tawon-operator-controller-manager"
cannot list resource "resourcequotas" in API group ""
```

`main.go:390` exits 1 → manager container in `CrashLoopBackOff`. The
`kube-rbac-proxy` sidecar stays `Ready=true`, masking the failure in
`kubectl get pod` output — only `containerStatuses[].ready` reveals it.

**Requested fix:** Add `get,list,watch,create,update,patch,delete` on
`resourcequotas` to the manager ClusterRole.

**Today's workaround:** Flipping #2 sidesteps it (cleanup phase is
skipped entirely). The bug is still latent for anyone who keeps the
destructive init.

---

## 5. Agent DaemonSet has no `hostNetwork` knob and operator reverts external patches

**Surface:** XC-required, but useful broadly.

When a `ClusterDirective` is applied, the operator spawns a DaemonSet
named `tawon-directive-<name>` without `hostNetwork: true`. We've verified
empirically that external `kubectl patch` adding hostNetwork is reverted
by the operator within seconds.

On XC, the agent DS can't use pod networking because the proprietary
Vega CNI rejects pods in user-created namespaces. With no hostNetwork
knob and pod-network blocked, the agent literally cannot run.

The operator's other pods (operator itself, dashboard, streamstore) are
patched directly today without reconciliation — only the agent DS is
operator-owned.

**Requested fix:** Add `spec.daemonSet.hostNetwork` (and `dnsPolicy`) to
the `ClusterDirective` and `Directive` CRD schemas. Default `false`. When
set, threaded through to the templated DS.

This is the highest-impact single fix — the local mutating admission
webhook in `eob-xc-install` exists primarily for this.

**Today's workaround:** [`eob-mutate`](webhook/) systemd webhook on
master-0 with `failurePolicy: Fail`. Single point of failure for every
new agent pod cluster-wide.

---

## 6. Agent `--probes.addr` / `--metrics.addr` not configurable

**Surface:** environment-agnostic when hostNetwork is in use.

The agent binary fixes its probe port at `:8081` and metrics at `:9990`.
The ClusterDirective spec doesn't expose `--probes.addr` or
`--metrics.addr`.

On pod networking this doesn't matter (each agent has its own pod IP).
On hostNetwork, every directive's agent on a node tries to bind the same
:8081 and :9990. The second-applied ClusterDirective sits Pending with
`FailedScheduling: didn't have free ports for the requested pod ports`.

This compounds with #5 — XC sites need hostNetwork and immediately hit
multi-directive port collisions.

**Requested fix:** Expose `probesAddr` / `metricsAddr` as fields on
`ClusterDirective.spec` (or via the chart `values` as defaults the
operator threads into the DS template's env). The operator could even
auto-assign deterministic offsets per directive — that's effectively what
our webhook does today.

**Today's workaround:** `eob-mutate` webhook hashes the DS name and
assigns probe ∈ `[18081, 19081)`, metrics ∈ `[19990, 20990)` with
matching `TAWON_PROBES_ADDR` / `TAWON_METRICS_ADDR` env injection. Probe
`httpGet.port` uses a named port (`http-probes`) so kubelet auto-tracks.

---

## 7. Operator manager and agent both bind `:8081` under hostNetwork

**Surface:** XC-required; affects anyone running operator + agent on the
same node with hostNetwork.

Related to #6. The operator's `controller-manager` binds `:8081` for
health probes. The agent binds the same `:8081` for its own probes. Both
on hostNetwork = collision. Operator wins (it starts first); agent's
probe server fails to bind; kubelet liveness/readiness probes return
connection-refused; agent enters a 30-second restart loop. Between
restarts the agent IS publishing data, but with periodic gaps and
`READY=False, NODES READY=0/1` on the directive.

**Requested fix:** Move the operator's manager probe port to a
non-conflicting value (e.g. `:8181`) in the chart's deployment template.
Alternatively, fix #6 — once probe ports are configurable per directive,
the agent moves and the operator's `:8081` stays valid.

**Today's workaround:** `patches/01-operator-deploy.yaml` rewrites the
operator's `--health-probe-bind-address` to `:8181` (and matches the
liveness/readiness ports). Rolling update has a gotcha (the unused
`webhook-server` `containerPort: 9443` on the operator behaves like a
hostPort and blocks co-scheduled replicas — needs `strategy: Recreate`).

---

## 8. DirectiveBinding CRD missing from chart (rc6)

**Surface:** environment-agnostic. Hits anyone installing rc6 from
the .tgz alone.

`tawon-operator-3.0.0-rc6.tgz` ships 6 CRDs (`clusterdirective`,
`dashboard`, `directive`, `stream`, `streamstore`, `topologyaggregator`).
The operator code at runtime expects a 7th — `DirectiveBinding.tawon.
mantisnet.com/v1alpha1`. Without it the manager crash-loops:

```
if kind is a CRD, it should be installed before calling Start
no matches for kind "DirectiveBinding"
failed to wait for directive caches to sync
```

The full CRD set lives in `tawon-operator-bundle:v3.0.0-rc6` at
`/manifests/tawon.mantisnet.com_directivebindings.yaml` — so it exists,
just isn't shipped in the chart.

**Requested fix:** Add the DirectiveBinding CRD to the chart's
`crds/` directory before the next release tag.

**Today's workaround:** Our `install.sh` extracts the CRD from the
bundle image via rootless podman and applies it before `helm install`.

---

## 9. StreamStore service name suffix leaks into operator-set NATS URL

**Surface:** environment-agnostic, but noticeable on XC.

The chart generates the StreamStore Service name with a stable but
chart-instance-specific suffix (e.g. `tawon-streamstore-d2f18e`). The
operator hardcodes this name into the agent's NATS URL, overriding
whatever `messaging.nats.url` the user sets on the Directive. The suffix
makes the FQDN unstable across reinstalls and unpredictable from outside
the chart.

On XC this couples to #1 — we need the exact FQDN to put into the
`hostAliases` workaround, and the suffix can change between installs.

**Requested fix:** Stabilize the StreamStore Service name (drop the
suffix, or expose it as an explicit chart value), OR honor the
`messaging.nats.url` on the Directive CR rather than overriding it.

**Today's workaround:** `webhook/install.sh` discovers the streamstore
Service name at install time and injects the matching FQDN into the
webhook's `hostAliases` configuration. Brittle to reinstalls.

---

## 10. Operator-set NATS URL ignores `messaging.nats.url` on Directive

**Surface:** environment-agnostic; related to #9.

The agent's NATS URL in its rendered Pod env is set by the operator from
the StreamStore Service FQDN, not from the `messaging.nats.url` field in
the ClusterDirective / Directive spec. This means there is no way to
direct the agent at an externally-managed NATS server from the CR — the
field is silently overridden.

**Requested fix:** Treat the CR field as authoritative if set;
fall back to the chart-managed StreamStore otherwise.

This is a soft ask — our installs do use the chart-managed StreamStore.
But the override behavior is surprising and made the dashboard
hostAliases issue (#1) harder to debug.

---

## 11. Dashboard CRD has no `hostNetwork` field; chart value undocumented

**Surface:** XC-required for the dashboard packet viewer to work
(needs the streamstore Pod's hostIP via hostAliases plus hostNetwork to
bypass Vega).

The `Dashboard` CRD doesn't expose `hostNetwork`. `kubectl patch deploy`
on the rendered Deployment sticks (no spec-drift reconcile from the
operator — different from agent DS behavior, see #3 / #5), but is
ergonomically a wart.

**Requested fix:** Add `spec.hostNetwork` (and `dnsPolicy`) to the
`Dashboard` CRD. Same treatment as #5.

---

## Summary — fix order we'd like upstream

By impact on the XC integration:

| Order | Item | Impact |
|---:|---|---|
| 1 | #5 (agent hostNetwork knob) | retires the mutating webhook for ~80% of cases |
| 2 | #6 (configurable probe/metrics addr) | retires the per-directive port hash in webhook |
| 3 | #1 (cluster domain not hardcoded) | retires hostAliases injection on operator + dashboard |
| 4 | #2 (`removeExistingResourcesOnInit: false` default) | prevents accidental wipes; bug-class fix |
| 5 | #4 (resourcequotas RBAC) | resolves a CrashLoopBackOff that's hard to spot |
| 6 | #7 (operator probe port) | resolves a flap that's been masked too long |
| 7 | #3 (CM watch / consistent CR templating) | ergonomic |
| 8 | #11 (Dashboard hostNetwork knob) | ergonomic |
| 9 | #8 (rc6 missing CRD) | one-line packaging fix |
| 10 | #9, #10 (NATS URL handling) | retires brittle install-time discovery |

Items 1, 2, 3 together would retire the entire `eob-mutate` webhook on
XC sites — the largest single piece of local glue today.
