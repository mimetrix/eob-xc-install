# Hosting EoB as site infrastructure — recommendations

How to take the EoB install on F5 XC CE sites from "demo / pilot on one
staging site" to a position you can run as part of the site infrastructure
on multiple sites without on-call surprises.

This is a planning document, not a runbook. The install runbook lives in
`README.md`; this file is the framing for what to invest in next, and in
what order, so the install converges with the F5 XC site stack rather
than diverging from it.

## TL;DR

We are running the Mantis EoB stack (operator, dashboard, streamstore,
plus a per-directive agent DaemonSet — see [Resource footprint](#resource-footprint)
for actual counts and sizing) inside the F5 XC site-infra layer, on
hostNetwork, without Vega. That works today because of four pieces of
local glue:

1. `eob-mutate` mutating admission webhook (systemd on master-0)
2. `eob-registry` in-cluster `registry:2` (systemd on master-0)
3. registries.conf.d mirror file on each node
4. Post-render kubectl patches for the operator/dashboard/streamstore

None of the four are HA. Two are single-master-pinned (1 and 2). The
mutating webhook is the most load-bearing — it has `failurePolicy: Fail`,
so when it's down, *no new directive agent pods can be scheduled* anywhere
in the cluster.

Before treating this as durable site infrastructure on multiple sites,
the four items above need to become highly-available, and ideally a
couple of them should disappear entirely by getting fixed upstream (in
Mantis or F5 XC).

---

## Current architecture

```
                    apiserver (3 masters)
                          |
                          |  admission call
                          v
            eob-mutate.service (master-0 only)   <-- SPOF #1
                          |
                          |  mutates pod spec
                          v
              tawon-directive agent pod
              (hostNetwork, per-directive ports)
                          |
                          v
        tawon-streamstore (NATS JetStream, 1 replica, hostpath PV on master-0)   <-- SPOF #2
                          ^
                          |
              tawon-dashboard (hostNetwork, master-0 pinned)   <-- SPOF #3
                          ^
                          |
              tawon-operator (operators ns, hostNetwork, master-0 pinned)
                          |
                          v
                    cri-o on each node
                          |
                  pull quay.io/mantisnet/* via mirror
                          v
            eob-registry (registry:2 on master-0)   <-- SPOF #4
                          ^
                          |  every node's
                          |  /etc/containers/registries.conf.d/099-eob-mirror.conf
                          |  (re-applied via host-fix pod)
                          +-- vpm reconcile risk: untested
```

## Resource footprint

Measured on `srikan-tf-test-0` with 2 ClusterDirectives running (one
`capture` + one `payload-process-name` agent DS, 3 nodes each).

### Per-pod

| Pod | Req CPU | Req Mem | Limit CPU | Limit Mem | Actual mem |
|---|---:|---:|---:|---:|---:|
| operator (manager + kube-rbac-proxy) | 505m | 1.06Gi | 1.5 | 2.13Gi | 55Mi |
| dashboard (sengat) | — | — | 4 | 4G | 60Mi |
| streamstore-0 (NATS JetStream) | 250m | 200M | 1 | 1G | 585Mi |
| agent (per directive, per node) | — | — | 1 | 1G | ~130Mi |

The dashboard and agent pods declare no requests — scheduler treats them
as BestEffort. Doesn't matter on a dedicated CE site, would matter on a
shared cluster. Limits are loose: cluster-wide CPU limit ≈ 12.5 cores
and memory limit ≈ 12.9 GiB, against actual usage of ~1.5 GiB.

### Cluster-wide (with N directives)

| | Steady state | Scaling rule |
|---|---|---|
| Pods | 3 + 3N | 3 control-plane + (N directives × 3 nodes) agents |
| Actual memory | ~0.7 GiB + 0.4 GiB × N | streamstore dominates; agents add ~390Mi/directive |
| Streamstore PV growth | bounded by JetStream retention (configurable per Stream CR) | watch on `/var/lib/eob-streamstore` |

### On-disk

| | Footprint | Where |
|---|---:|---|
| In-cluster registry | 1.0 GB (rc4 image set) | master-0 `/var/lib/eob-registry/data` |
| cri-o image cache | ~3.0 GB / node | each node `/var/lib/containers` |
| cri-o image cache (rc4+rc6 staged) | ~6.1 GB | master-0 only (`diagnose` is 2.15 GB × 2 versions) |
| streamstore JetStream PV | grows with capture volume | master-0 hostpath |

`diagnose` is the heavy image at 2.15 GB; pruning unused versions off
master-0 cri-o saves ~3 GB.

---

## Production readiness scorecard

| Area | Status | Risk | Effort to fix |
|---|---|---|---|
| Pod scheduling / Vega bypass | works via webhook | webhook SPOF | M (DS-ify webhook) |
| Multi-directive coexistence | works via per-directive port remap | port-range collisions at scale | S (raise PROBE_PORT_RANGE in webhook env) |
| `.cluster.local` hardcode | works via hostAliases on operator + dashboard | NATS service ClusterIP change | S (re-run install.sh) |
| Image distribution | works via in-cluster registry + mirror conf | registry single-node, mirror file durability | M (HA registry) + S (durability watchdog) |
| Storage (streamstore) | hostpath PV on master-0 | data loss on master-0 disk failure | L (NATS JS clustering) |
| Dashboard exposure | hostNetwork on master-0 | single-node UI | M (Service + per-master DS) |
| Webhook cert rotation | self-signed, 10y | none short-term, hygiene long-term | S (cert-manager or systemd-timer rotate) |
| Upgrade path (rc4 → rc6+) | known issues documented | each upgrade is bespoke | L (track upstream) |
| Observability / metrics | per-pod scrape on hostNetwork, no Prom | no alerting | M (point existing XC Prom at our pods) |
| vpm reconciliation interaction | mtime-unchanged but unverified | silent regression | S (durability test + watchdog) |
| Documentation / runbook | this bundle is the runbook | runbook coverage incomplete | XS (in this PR) |

Legend: S ≈ ≤1 day, M ≈ ≤1 week, L ≈ ≤1 month.

---

## Recommended order of work

Roughly: fix the SPOFs that page on-call (1–3), make the workarounds
durable (4–5), get upstream changes that retire the workarounds (6–8),
and add the visibility everyone forgets until they need it (9–10).

### 1. eob-mutate webhook → 3 replicas (one per master)

The biggest production risk. The webhook is the gate for every new
directive agent pod cluster-wide, and the systemd unit is on master-0.
With `failurePolicy: Fail` (correct setting; `Ignore` would silently
admit pods that then fail Vega), a master-0 outage = no new directives.

Two viable shapes:

- **Hostnet DaemonSet, image-baked Python:** package `server.py` into a
  small UBI image, push to `eob-registry`, deploy as a hostNetwork DS in
  `tawon-operator` namespace (the only namespace currently mutated, but
  the webhook itself runs anywhere as long as it has a route to the
  apiserver). MutatingWebhookConfiguration `clientConfig.service` points
  at a `ClusterIP` Service in front of the DS pods — apiserver does the
  load balancing.
- **3 sibling systemd units:** same `server.py`, `eob-mutate.service`
  on all three masters, MutatingWebhookConfiguration uses
  `clientConfig.url` round-robin via DNS, or three separate
  MutatingWebhookConfigurations each pointed at one master IP.

The DS shape is cleaner. The sibling-systemd shape keeps the
infrastructure-not-tenant framing more honest (matches how voucherd is
deployed). Either is fine; commit to one before scaling beyond a single
site.

### 2. Webhook health probes + journald alerting

Today's webhook has `GET /healthz` but nothing reads it. Add:

- A node-level systemd timer that curls `/healthz` every 30s and fails
  loudly (journald error) if it can't get a 200.
- A unit `OnFailure=` hook that sends a notification through whatever
  XC's site-infra alerting path is.

For the DS-ified version, kubelet probes do this automatically.

### 3. In-cluster registry → HA or replaceable

The `eob-registry` is a single `registry:2` container on master-0 with
`/var/lib/eob-registry/data` on master-0's disk. If master-0's disk
fills or fails, no node can pull `quay.io/mantisnet/*` anymore.

Two options:

- **HA registry:** run `registry:2` on each master, with a shared
  storage backend (hostpath won't do here; needs object storage or NFS).
  Each node's mirror conf points at `localhost:5000` first, with the
  other masters as fallback mirrors. Adds complexity; needs object
  storage decision.
- **Don't make it HA — make it cheap to rebuild:** keep registry on
  master-0, but check the `images.txt` against the live registry every
  24h via a systemd timer + skopeo. If anything is missing, re-push
  from `~/eob/release-package-*/images/`. Master-0 can be re-imaged and
  the registry rebuilt from the release tarball in well under an hour.

The second option is dramatically simpler and probably the right call
unless we hit specific scenarios that demand the first.

### 4. registries.conf.d durability across vpm reconcile + reboot

We have circumstantial evidence (`mtime` unchanged for the life of the
site) that vpm does not reconcile `/etc/containers/registries.conf.d/`,
but no documented contract. For multi-site production:

- Get a written answer from the XC team on whether
  `registries.conf.d/` is reserved for tenant config (best outcome —
  cleanest contract), OR
- Add a systemd path-unit watchdog on each node that restores
  `099-eob-mirror.conf` from `/etc/eob/` if it disappears.

The watchdog is one tiny `.path` unit + a one-line `.service` —
trivial to add and doesn't require XC team buy-in.

### 5. StreamStore data durability

The streamstore runs as a single NATS JetStream replica with a
`hostpath` PV on master-0. JetStream supports clustered streams, which
the Mantis chart can produce (`replicas: 3` on the StreamStore CR), but
each replica would still need a hostpath PV — meaning we'd be pinning
one to each master, with the master IP changing the pod's identity.
That's doable but isn't free:

- Decide whether captured packets / payload streams need to survive a
  master-0 reboot. If they do, this matters; if they don't (capture is
  ephemeral by nature), defer this and instead document the
  expectation.

For a pilot, single-replica is acceptable as long as it's stated. For
multi-site production we should make a deliberate call.

### 6. (Upstream Mantis) Native hostNetwork knob on agent DS

Tracked as part of the rc4 / rc6 backlog. Once Mantis exposes
`spec.daemonSet.hostNetwork` (or equivalent) on the ClusterDirective
CRD, the webhook's `hostNetwork` mutation becomes redundant. We'd keep
the webhook for hostAliases + port remap until 7 lands.

### 7. (Upstream Mantis) `--probes.addr` / `--metrics.addr` exposed as chart values, settable per directive

Today the chart fixes these at the binary defaults (8081 / 9990). The
webhook overrides via env. If Mantis exposes them in the
ClusterDirective spec, the webhook can stop doing port allocation.
For multi-directive concurrent use, the user (or our operator-side
patch) would set unique ports per directive.

### 8. (Upstream F5 XC) Tenant-managed namespace provisioning for site infrastructure

The deepest fix. If F5 XC adds a path to provision a Vega VN for an
operator-installed namespace (akin to how `ves-system` does it via
internal cloud config), we can drop hostNetwork entirely for the EoB
control-plane pods, retire the webhook, and run the agent DS with
hostNetwork *only* for kernel-observation purposes (which is its
upstream design intent — hostNetwork to observe host traffic, not to
work around CNI gaps).

This is a long-running ask and shouldn't block any of items 1–5.

### 9. Observability — pull metrics into the site's existing Prometheus

The site already runs Prometheus in the `monitoring` namespace
(see `kubectl -n monitoring get pods`). EoB pods expose Prom metrics:

- Operator: `https://<master-0>:18443/metrics` (kube-rbac-proxy)
- Streamstore (NATS): `:8222/metrics`
- Agent: per-directive port (`PROBE_PORT_BASE + offset` for probes,
  `METRICS_PORT_BASE + offset` for `/metrics`)

The per-directive port is a wrinkle for Prom service discovery. Two
options:

- Add a custom scrape config using `kubernetes_sd_configs` with role:
  pod + relabel rules that read the `pod.metadata.annotations`. Have
  the webhook annotate each agent pod with
  `prometheus.io/port=<metrics_port>`.
- Annotate the eob-mutate webhook to emit per-directive `ServiceMonitor`
  CRs (if the site's Prom is operator-managed). More moving parts; only
  do this if the site is already using ServiceMonitor pattern.

### 10. Runbook / on-call documentation

For each SPOF and each "this is normal" gotcha we've discovered, write
a short triage runbook in `eob-xc-install/runbooks/` and link from
this doc. Minimum set:

- "Dashboard packet viewer shows error" → check dashboard hostAliases
  vs streamstore ClusterIP (`reference_xc_node_access` memory has the
  pattern)
- "Multi directive fails to schedule with `no free ports`" → check
  PROBE_PORT_RANGE / METRICS_PORT_RANGE haven't been hit; either bump
  the range in `/etc/eob-mutate/env` or stop oldest directive
- "Stream stays Ready=False after install" → re-apply hostAliases on
  operator with current NATS ClusterIP
- "ImagePullBackOff for mantisnet/* on master-N" → verify mirror conf,
  check registry health, check that master-0 hasn't filled disk

---

## What I'd *not* invest in (or invest in last)

A handful of things are tempting but probably don't pay off until
items 1–5 are done:

- **Helm chart for the whole bundle.** We'd be wrapping a Helm chart in
  a Helm chart. The `install.sh` + post-render patches model gives
  cleaner failure modes (one step fails, fix it, rerun); a wrapper
  chart hides the order-sensitivity that is the actual hard part.
- **Operator-style controller for our patches.** Same problem — we'd
  be writing a controller whose only job is to keep applying the same
  three patches the existing post-render does, on a state that the
  Mantis operator is also reconciling. Two controllers fighting.
- **A CRD for "EoB site config."** Premature abstraction. There are
  ~5 site-specific values today; they live fine in
  `values-override.yaml` + the dynamic install.sh discovery.

These all become reasonable *after* items 6–8 land upstream and the
custom integration surface shrinks.

---

## Per-site rollout checklist (today, with the workarounds)

Before installing on a new XC CE site:

- [ ] SSH key + sudo working for `xcuser`
- [ ] Quay credentials for `quay.io/mantisnet/*` available
- [ ] AWS Security Group between masters permits arbitrary TCP (default; verify)
- [ ] If the dashboard needs external access: a separate ask to open inbound TCP
      8789 in the master EC2 SG (template in `admin-firewall-request.md`)
- [ ] Confirm the site's cluster DNS suffix matches the pattern
      `<site>.<tenant>.tenant.local` (it should — this is a platform property)
- [ ] Master-0 has ≥ 25 GB free on `/var` (registry ~1 GB + cri-o cache ~6 GB
      with multiple release versions staged + streamstore JetStream PV grows
      with capture volume + headroom). Other masters need ≥ 10 GB for cri-o cache.
- [ ] None of `:5000`, `:8789`, `:9443`, `:18443` are in use on master-0
      (`sudo ss -tlnp | grep -E ':5000|:8789|:9443|:18443'`)

Post-install verification:

- [ ] `kubectl get clusterdirectives` shows your seed directive
      `READY=True, NODES READY=3/3`
- [ ] Dashboard packet viewer can open a stream without error (UI test)
- [ ] `sudo journalctl -u eob-mutate.service --since '5m ago'` shows
      `200` for every recent mutation
- [ ] `sudo journalctl -u eob-registry.service --since '5m ago'` shows
      pulls from all three master IPs
- [ ] `kubectl get mutatingwebhookconfiguration eob-mutate` exists
      with `failurePolicy: Fail`
- [ ] All three masters have `/etc/containers/registries.conf.d/099-eob-mirror.conf`
      (`kubectl debug node/master-N -- chroot /host ls /etc/containers/registries.conf.d/`)

---

## Open questions (need XC team or Mantis answers)

1. **XC team:** is `/etc/containers/registries.conf.d/` reserved for
   tenant-installed configuration (won't be reconciled by vpm)? If not,
   what's the blessed path?
2. **XC team:** is there a tenant-facing API for provisioning a Vega VN
   for an operator-installed namespace (the long path for retiring our
   webhook)?
3. **Mantis:** plans for exposing `hostNetwork` / `--probes.addr` /
   `--metrics.addr` as chart values or ClusterDirective spec fields?
4. **Mantis:** plans for fixing the StreamReconciler `.cluster.local`
   hardcode (and the dashboard pktsapi hardcode of the same)?
5. **Mantis:** intended deployment model for multi-replica StreamStore
   on Kubernetes — is hostpath + per-master pinning the recommended path,
   or is there a documented PVC strategy that doesn't assume dynamic
   provisioning?
