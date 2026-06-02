# Request: treat Mantis EoB / Tawon as F5 XC site infrastructure

A request to position the Mantis EoB stack (Tawon operator, dashboard,
streamstore, per-directive agent DaemonSets, and our local glue) as a
site-infrastructure component on F5 XC Customer Edge sites — at the same
layer as `vpm`, `voucher`, `cri-o`, the kubelet, and the rest of the
`ves-system` stack — rather than as a tenant workload deployed by users
into a customer namespace.

This is not a request for source code or repository ownership. It's a
request for **integration contracts and lifecycle treatment** so EoB
can run as durable infrastructure rather than as a stack of workarounds
on top of the tenant-workload abstraction.

---

## TL;DR

Today EoB on XC works, but only because we layer four pieces of local
glue on top of the platform:

1. `eob-mutate` mutating admission webhook (systemd on master-0) — turns
   off the proprietary CNI per pod
2. `eob-registry` in-cluster `registry:2` (systemd on master-0) — host
   the EoB images locally
3. `registries.conf.d/099-eob-mirror.conf` on each node — mirror config
4. Post-render `kubectl patch` for operator, dashboard, streamstore —
   network and port fixes

None of the four are HA. Two are single-master-pinned. The mutating
webhook is the most load-bearing — with `failurePolicy: Fail`, when it's
down no new agent pods can be scheduled cluster-wide.

These workarounds are not pathologies of EoB. They're the symptom of
applying tenant-workload abstractions to what is functionally a piece of
site infrastructure: a per-site, host-aware observation plane that
needs to live on the node, observe host traffic, and survive reboots and
node maintenance — exactly the same operational profile as F5's own
voucher / vpm stack.

We'd like to either (a) get EoB recognized as a co-installed
site-infrastructure component on XC CE sites, with the integration
contracts that makes possible, or (b) get a small number of explicit
integration points that let us run it durably as a tenant install
without the brittle glue.

---

## What "site infrastructure" means concretely

By "site infrastructure" we mean components that share the operational
profile of `ves-system` / `voucher` / `vpm` / `cri-o` on an XC CE site,
specifically:

| Property | F5 ves-system | Mantis EoB today | Mantis EoB as infra |
|---|---|---|---|
| Pre-installed at site bootstrap | yes | no — installed post-bootstrap | yes (or as a documented post-bootstrap step) |
| Lives on every master / node (as appropriate) | yes (DS / per-node systemd) | partially (one master systemd, ad-hoc rest) | yes |
| HA across masters | yes | no | yes |
| Survives reboots and node maintenance | yes | partial | yes |
| Has a documented contract with the platform (Vega VN, registries.conf.d, etc.) | yes | no — integrated through gaps | yes |
| Owned by an operations team, not a tenant | F5 | unclear | F5 + Mantis joint, or platform team |
| Observability into site Prometheus | yes | no — not wired | yes |
| Lifecycle tied to the site, not a customer app | yes | no — installed by users | yes |

The work between columns 3 and 4 is mostly negotiation and packaging,
not engineering. The engineering investments (HA webhook, durable
registry, observability wiring) are tractable and listed in
[HOSTING.md](HOSTING.md). What blocks the infra framing today is a
small number of platform-level decisions, listed below.

---

## What we're asking for

Roughly in order of decreasing impact:

### 1. A blessed integration path for `hostNetwork` (or equivalent)

The deepest source of brittleness today. Mantis EoB agents need to
observe host traffic — that's their job — and the chart's expectation
is that the agent runs on hostNetwork. On XC, hostNetwork is also the
only way to bypass the Vega CNI for components in non-`ves-system`
namespaces.

We have two paths and would welcome either:

- **Provision a Vega VN for an operator-installed namespace.** A way to
  ask the platform "this namespace is site infrastructure, please bind a
  VN to it" — equivalent to what happens for `ves-system` today, but
  exposed to non-F5 operators via a tenant- or site-admin API. With
  that, EoB can drop `hostNetwork` for the control-plane pods (operator,
  dashboard, streamstore) and keep hostNetwork *only* on the agent DS
  for its actual purpose (host traffic observation).
- **A documented platform contract for `hostNetwork: true` in a defined
  namespace.** If "we're an infrastructure component running on
  hostNetwork in `tawon-operator`" is acceptable from the platform's
  perspective, document that and we'll retire the admission webhook in
  favor of declaring it at chart-install time.

Either retires the mutating admission webhook (today's biggest SPOF).

### 2. A stable, documented contract for `/etc/containers/registries.conf.d/`

We have circumstantial evidence (`mtime` unchanged for the lifetime of
the site) that `vpm` does not reconcile files under
`/etc/containers/registries.conf.d/`, but this is not a documented
contract. We'd like:

- An explicit answer from the XC platform team: is
  `/etc/containers/registries.conf.d/` reserved for tenant- /
  operator-installed configuration?
- If yes: add a one-line note to the CE site administration doc, and
  this becomes a permanent integration point.
- If no, or if the contract is different: tell us the blessed path
  and we'll move there.

This is a 30-minute decision on the platform side that retires a
durability risk in our install.

### 3. Acknowledgment that operator-installed systemd units / quadlets
   are a supported integration pattern

We currently run:
- `eob-mutate.service` — Python admission webhook
- `eob-registry.container` — quadlet for `registry:2`

Plus we plan to move both to per-master replicas (DaemonSet or sibling
systemd — see HOSTING.md). We'd like an explicit "yes, this is a
supported operator-install pattern" so we can stop second-guessing
whether vpm or a later XC version will reconcile these away.

The voucherd / vpm / cri-o systemd stack already exists. We're asking
for our units to live next to them, with the same expectations.

### 4. Observability wiring — let our metrics into the site's Prometheus

The XC site already runs a Prometheus in `monitoring`. Today EoB pods
expose Prom metrics endpoints (operator, streamstore, agent — each on
hostNetwork ports). We don't have a documented path for getting these
scraped by the site Prom without either copying the entire scrape
config out and managing it ourselves, or asking F5 to do it for us.

We'd welcome either:
- A documented `ServiceMonitor`-style or scrape-config extension point
  for site-infrastructure components.
- A platform team-owned scrape-target list that we can append to as
  part of the EoB install.

This is the difference between "we run packet capture" and "we run
packet capture with alerting." Today we have the former.

### 5. Lifecycle coordination

The least urgent ask, but the one that completes the picture. Today an
XC site upgrade is opaque to EoB; an EoB upgrade is opaque to the XC
platform. Both can break the other.

Concretely we'd like a way to declare:
- "These hostpaths are owned by EoB" (so vpm or a node refresh doesn't
  reclaim them).
- "EoB is installed on this site" (so a CE upgrade flow can check
  whether any of its actions affect our install).

Not a blocker today, but worth noting before this work goes to multiple
sites and we hit a coordination failure at scale.

---

## What we offer in return

The framing isn't "F5 should make platform changes for one customer."
The framing is "EoB is a generally-useful site-infrastructure
capability that gives every XC CE site eBPF-based packet capture and L7
attribution, and the integration path benefits the whole product." That
includes:

- **Generally-useful observation plane.** eBPF capture + L7 + process
  attribution + structured DNS extraction are useful for any XC site
  doing security or networking troubleshooting. The MCP / gRPC
  federation interface in [`eob-mcp`](../eob-mcp) makes this consumable
  by LLM agents and federation aggregators alike.
- **Co-development and bug fixing on the Mantis side.** The
  [`UPSTREAM-FIXES.md`](UPSTREAM-FIXES.md) doc lists eleven concrete
  Mantis-Tawon fixes we'd like to drive together with the Mantis team
  — each of which retires a piece of our local glue. We're committed
  to that upstream work.
- **Multi-site rollout discipline.** Today's install is reproducible
  via `install.sh` + RUNBOOK.md. As we expand to multiple sites, the
  install becomes a forcing function for cleaner integration with the
  XC platform, not a perpetuating workaround pattern.

---

## What success looks like

Six months from now, on a fresh XC CE site, the EoB install looks like:

```
$ helm install eob mimetrix/eob --version <stable>
$ kubectl wait --for=condition=Available --timeout=300s deploy --all -n tawon-operator
```

No mutating admission webhook. No systemd glue. No post-render patches.
No hostAliases workarounds. The local glue currently in
`eob-xc-install` is empty or retired entirely. The agent DS runs on
hostNetwork because it needs to, not because we forced it via webhook;
everything else runs on pod networking via a properly-provisioned
Vega VN.

That's the destination. Today's install gets us there in production on
one site; the workarounds documented in this repo are the bridge until
the platform and operator changes land.

---

## Related documents

- [README.md](README.md) — the install bundle
- [RUNBOOK.md](RUNBOOK.md) — operational walkthrough
- [HOSTING.md](HOSTING.md) — production readiness scorecard
- [UPSTREAM-FIXES.md](UPSTREAM-FIXES.md) — Mantis-side fixes
- [admin-firewall-request.md](admin-firewall-request.md) — example
  of the kind of platform-team interaction we have today

---

## Specific people to align with

(filled in once we know the right names)

- **F5 XC platform team:** owner of the Vega VN / `registries.conf.d` /
  `vpm` reconcile contracts.
- **F5 XC CE site team:** owner of the bootstrap / lifecycle.
- **Mantis Tawon team:** owner of the chart, operator, and CRDs.
- **F5 + Mantis partnership:** owner of the framing decision (is EoB a
  product or a feature?).
