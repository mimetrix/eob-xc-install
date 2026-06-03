# eBPF protection for F5 XC edges — design memo

A cross-cutting design for using eBPF to **protect** an F5 XC edge — its
host plane, its platform services, and the workloads it carries — at all
three edge types (Customer Edge, Regional Edge, Controller). Companion
to [`INFRASTRUCTURE-POSITIONING.md`](INFRASTRUCTURE-POSITIONING.md), which
makes the broader case for treating observability + enforcement
co-installed software as site infrastructure on XC.

This is a design memo, not a runbook. The goal is to align an internal
audience (F5 platform + Mantis + the EoB team) on what an eBPF-based
edge-protection capability looks like, what it shares with the existing
[`eob-xc-install`](README.md) / [`eob-mcp`](../eob-mcp) stack, and what
the platform-level integrations are that we need to build it once and
deploy it at all three edge types.

---

## TL;DR

EoB today gives us a **telemetry plane** at every XC edge — packet
capture, L7 decoding, process attribution, federation to a fleet
console. The plane is in-kernel (eBPF) and we already know how to ship,
operate, and federate it.

A protection plane is the second half of that capability: **the same
kernel hooks, used to enforce**. Drop a packet that matches a
known-bad pattern. Refuse a syscall that violates a workload's
declared profile. Rate-limit an interface under DDoS. Block a process
exec that doesn't match the image's allow-list. These are all
eBPF-native primitives (XDP, TC, cgroup-bpf, LSM-bpf) running in the
same address space as the observation plane and consuming the same
policy distribution channel.

We're proposing one capability with two faces (observe + enforce),
co-installed as edge infrastructure, with edge-type-specific
deployment shapes layered on top of a single shared architecture.

---

## Threat model (what we're protecting against)

Distinct at each edge type, but the eBPF building blocks are the same:

| Edge type | Primary threats | Why eBPF |
|---|---|---|
| **Customer Edge** | Tenant-workload compromise → lateral movement into platform infra (vpm, vegacfgd, voucherd); cross-tenant escape via shared kernel; malicious image pulls; data exfil via ordinary network paths | Tenants share a kernel; in-kernel enforcement is the cheapest barrier between them and the platform plane. Vega L3/L4 isn't enough — need L7 + syscall + filesystem. |
| **Regional Edge** | North-south DDoS, scraping, credential-stuffing against tenant front-ends; route hijack / BGP-adjacent attacks on the control plane; abuse-pattern traffic that's expensive to drop in userspace | RE handles peering volume — only XDP can drop unwanted traffic at line speed without burning a core per Gbps. |
| **Controller / control plane** | Compromised tenant or agent reaching the control APIs; credential exfil from control pods; supply-chain tamper of control-plane binaries; insider lateral movement | High-trust target; eBPF-LSM lets us assert deny-by-default for syscalls / file access / exec inside control-pane pods, with the audit trail going to the existing telemetry plane. |

A common thread: the enforcement point lives **below** whatever the
attacker is operating at. Container escapes happen at the kernel
boundary; an eBPF LSM hook is one of the few enforcement points the
attacker doesn't reach. DDoS happens at the NIC; XDP runs before the
network stack engages.

---

## eBPF primitives by enforcement domain

The capabilities by which we'd compose protection programs:

### Network (L2–L4)

- **XDP** at the NIC: drop / redirect at line speed. Source-IP filters,
  rate-limited reflectors, ECMP-aware DDoS scrubbing. CPU-cheap at the
  cost of being relatively coarse.
- **TC ingress/egress**: shape, classify, mark; richer programmability
  than XDP, slightly more expensive per packet. Right tool for per-pod
  egress quotas, marker-based QoS, cross-tenant rate limiting.
- **cgroup-bpf at the socket layer**: deny `connect()` / `bind()` from
  pods that aren't supposed to talk outside their cluster. Cleaner
  than netfilter — applies at socket open, not per-packet.

### Network (L7 — via L4 + redirect)

- **sockmap / sockops**: hijack `sendmsg` between two pods on the same
  node into a userspace policy engine without going through the
  TCP/IP stack. Pairs well with the existing observation plane: the
  same flow that the EoB agent dissects could be paused inline if it
  matches an enforce-rule.
- **kprobe + bpf_send_signal**: kill a process that produces a
  pattern in its L7 traffic (e.g. credential dumper, known-bad
  C2 protocol).

### Syscall / process / filesystem (eBPF-LSM)

- **bpf_lsm hooks**: `file_open`, `bprm_check_security` (exec),
  `socket_create`, `task_kill`, `inode_permission`, etc. Allow-list
  what a control-plane pod is allowed to do; deny everything else
  with a fail-closed audit event.
- **bpf_overrideret**: synthesize a syscall return without letting the
  call hit the kernel. Useful for "deny this `ptrace` from this pod"
  patterns.
- **fentry/fexit on kernel funcs**: when LSM hooks aren't fine-grained
  enough — e.g. catching an in-progress filesystem walk before the
  open completes.

### Resource / capacity

- **cilium-style hubble counters but for enforcement**: per-pod /
  per-tenant byte counters maintained in eBPF maps, with a hard cap.
  Cross the cap, get rate-limited inline. Backpressure surfaces in the
  observation plane so the fleet console sees who's hot.

### Audit / forensics

- All enforcement events emit a structured record into the same NATS
  JetStream backbone the observation plane uses. **No separate side
  channel** — enforcement and observation flow into the same federated
  stream so a single console sees both.

---

## Architecture: three planes, one set of building blocks

```
+--------------------------------------------------------------------+
| Policy plane (control)                                             |
|   PolicyDirective / PolicyBinding CRDs                             |
|   Compiled into BPF map state by per-node enforcer                 |
|   Distributed by operator over watch + rendered into local files   |
+----------------------------+---------------------------------------+
                             |
                             v
+--------------------------------------------------------------------+
| Enforcement plane (per-node eBPF agent DaemonSet)                  |
|   XDP / TC / cgroup-bpf / LSM-bpf programs loaded per host         |
|   Map state driven by Policy plane; fail-closed defaults           |
|   Hooks share kernel runtime with observation plane                |
+----------------------------+---------------------------------------+
                             |
                             v
+--------------------------------------------------------------------+
| Telemetry plane (existing EoB)                                     |
|   eBPF capture + L7 decode + process attribution                   |
|   Publishes to NATS JetStream                                      |
|   eob-mcp serves federation via MCP + gRPC                         |
+--------------------------------------------------------------------+
```

Three planes, deliberately separated so a failure in one doesn't take
down the others:

- **Policy plane** can lose connectivity to the controller and the
  edge still enforces (locally cached compiled state).
- **Enforcement plane** can lose telemetry export and still drop
  packets (telemetry buffers locally, drains when connectivity
  returns).
- **Telemetry plane** can fail entirely and enforcement keeps
  working — the only loss is observability.

All three share:
- One **eBPF agent runtime** (a single DaemonSet pod per node).
  Loading XDP/TC/LSM programs requires `CAP_BPF` / `CAP_NET_ADMIN`;
  we already have this set up via the EoB agent.
- One **NATS JetStream** backbone for both observation events and
  enforcement-decision events.
- One **federation surface** (`eob-mcp` extended with new RPCs for
  policy state introspection and enforcement-event streams).

---

## Edge-type-specific deployment notes

The architecture is shared; the deployment shape changes per edge type.

### Customer Edge (CE)

Where we have the most existing ground truth — `eob-xc-install` runs
here today. The enforcement agent replaces nothing; it sits next to
the EoB observation agent in the same `tawon-operator` namespace.

- **Hostnetwork required** — same Vega-CNI-rejects-user-namespaces
  problem the observation plane has. The existing `eob-mutate` webhook
  handles this; we'd add the enforcement agent to its name-prefix
  allow-list.
- **Multi-tenant by design** — policy CRs are tenant-scoped, with
  cross-tenant policies (e.g. "tenant A cannot talk to tenant B's
  pods") held by the platform.
- **Co-located with workloads** — enforcement runs on every CE node
  that runs tenant workloads. Fail-closed defaults mean a node that
  loses its policy plane connectivity still enforces yesterday's
  policy.
- **Coexistence with Vega**: Vega CNI sets up multus interfaces in
  the netfilter/TC pipeline. Our XDP attach is at the NIC, before
  netfilter — coexists cleanly. TC programs need explicit ordering
  (attach with `qdisc clsact`, lowest-priority position).

### Regional Edge (RE)

Higher-volume, north-south, fewer pods per node. The enforcement
agent's job here is mostly XDP-shaped — drop bad traffic before it
costs anything to handle.

- **XDP-heavy program mix** — DDoS scrubbing, source-IP rate
  limiters, BGP-aware drop lists. The LSM-bpf side is less
  emphasized — there are fewer workloads to lock down.
- **Driver vs generic XDP** — RE NICs are typically the kind that
  support driver-mode XDP (where the program runs in the NIC driver,
  not after `__netif_receive_skb_core`). Significant perf delta vs.
  generic-XDP; we'd want to verify in the supported HW list.
- **Distinct policy CRs from CE** — different CR set
  (`ScrubbingPolicy`, `BGPProtectionPolicy`) — same CR distribution
  mechanism. Same operator can reconcile both.
- **Tighter perf budget** — RE handles peering volume. Programs need
  to be profiled (`bpftool prog profile`) before deployment. Hard
  limit: cumulative XDP cycles per packet under a stated budget;
  enforced in CI.

### Controller / control plane

Highest-trust environment. The enforcement agent here is mostly
**LSM-bpf** — allow-list what control-plane pods can do, deny by
default.

- **Workload profiles, not network rules** — each control-plane pod
  declares its `WorkloadProfile`: which syscalls, which files, which
  network destinations. Profile compiles to BPF maps; LSM hooks read
  them and enforce.
- **Audit-only mode required first** — flipping to enforce on the
  control plane without a soak period is dangerous. The Policy plane
  needs a per-rule `mode: audit | enforce` knob so we can dry-run
  every rule for some period before flipping to enforce.
- **Failure semantics: alert + audit, never block kernel** — an
  enforcement-program crash on the control plane must not take the
  control plane down. Programs run in their own verifier-cleared
  context; the worst case is "enforcement off, alert raised."

---

## Coexistence with the existing EoB observation plane

The same `eob-xc-install` install bundle would extend, not be
replaced:

- The eob-mutate webhook gates by pod name prefix today
  (`tawon-directive-*`, `tawon-dashboard*`, `tawon-streamstore*`).
  Add `tawon-protect-*` to the prefix list.
- The in-cluster registry would host the protection agent's image
  alongside the observation agent.
- `eob-mcp` would gain three RPCs:
  - `PolicyList` / `PolicyGet` — what's currently enforced
  - `EnforcementEventStream` — live tap into denial events (replaces
    a separate logging path)
  - `WorkloadProfileSchema` — the OpenAPI v3 schema for the
    profile CRs
- Federation envelope (`ClusterRef`) and the gRPC federation surface
  are unchanged — fleet consoles federate both observation and
  enforcement from the same MCP/gRPC origin.

Run-time, the two agents share:
- The same `bpf_map`-based bookkeeping for connection tracking.
- The same NATS JetStream subjects (different subject names for
  enforce events).
- The same kube ServiceAccount and RBAC pattern (just additional
  verbs on the policy CRs).

The deliberate non-shared part is the eBPF program objects themselves.
Observation programs and enforcement programs are independent ELF
objects — a verifier crash in one doesn't unload the other.

---

## Coexistence with F5 XC platform

The same five integration asks from
[`INFRASTRUCTURE-POSITIONING.md`](INFRASTRUCTURE-POSITIONING.md) carry
over, plus three protection-specific ones:

1. **Vega CNI ordering contract**. eBPF programs at TC ingress need
   a stable priority position relative to whatever Vega installs.
   Specifically: a documented "tenant-installable TC priority range"
   so our policies don't fight Vega's.
2. **XDP attach permission**. On RE, the platform owns the NIC. We
   need a documented path for an operator-installed component to
   attach an XDP program to a platform-managed device, with the
   platform team having veto-by-policy (e.g. "we won't accept programs
   larger than N instructions").
3. **LSM-bpf trust** on the controller. Loading LSM-bpf programs
   requires `CAP_SYS_ADMIN`-equivalent privileges and the program is
   in the kernel trust path. Need an explicit acknowledgment that
   F5-signed enforcement programs are part of the control-plane
   trust base.

These aren't "asks for one project" — they're contracts that, once
documented, enable every future tenant-installed protection capability,
not just ours.

---

## Policy model

Mirrors the Tawon ClusterDirective + Directive + DirectiveBinding
pattern intentionally so operators familiar with EoB recognize the
shape:

- **`ProtectionPolicy`** (cluster-scoped): the rule body. A set of
  predicates (match: source, syscall, port, label) and an action
  (deny | drop | rate-limit | audit).
- **`PolicyBinding`** (namespace-scoped): "apply policy X to pods
  matching label selector Y in this namespace."
- **`WorkloadProfile`** (namespace-scoped): declarative
  "what is this workload allowed to do" for LSM-bpf enforcement.
  Compiles to allow-list BPF maps loaded into the enforcement agent.

Versioned with a `policyVersion` field; the agent reconciles policy
state with a generation counter so a partial-failed distribution
doesn't leave the node in an inconsistent state.

**Fail-closed by default.** If the policy distribution fails to
compile or apply, the node falls back to:
- `audit` mode (log + don't enforce) for **new** policies
- **last-known-good** state for existing policies — agent does not
  unload an existing program just because the new one failed to
  compile

---

## Performance budget (rough)

Enforcement must not be a feature flag that operators leave off
because it costs too much. Order-of-magnitude budgets for upper-limit
testing:

| Hook type | Per-packet / per-call budget | Where it applies |
|---|---:|---|
| XDP DDoS drop | < 100 ns / packet | RE, CE inbound |
| TC egress shaping | < 500 ns / packet | CE per-tenant egress |
| cgroup-bpf `connect()` filter | < 1 µs / connection start | CE pod socket creation |
| LSM-bpf `file_open` allow-list | < 2 µs / open | Controller, CE control-plane pods |
| LSM-bpf `bprm_check_security` (exec) | < 5 µs / exec | All edges, defense in depth |

CI gates the above with `bpftool prog profile` runs against synthetic
loads before any policy program lands.

---

## Open questions

1. **Trust model for policy distribution.** The agent must verify a
   policy is signed by an authorized policy author. Two paths:
   X.509 (matches existing F5 PKI on XC sites) or sigstore-style
   signed manifests. Need to pick one before any production deploy.
2. **Hot-reload vs restart.** Today the EoB observation agent restarts
   to pick up new programs. Enforcement needs hot-reload (don't drop
   live enforcement while a new program loads). The eBPF runtime
   supports `bpf_link` swaps; the operator needs to use them.
3. **Cross-cluster federation of policy.** EoB's `eob-mcp` is
   single-site by design (single edge). A protection policy that
   needs to be consistent across many CE sites needs a federation
   path — same shape as the observation aggregator design but with
   policy state going the other direction.
4. **Profile-discovery mode.** For LSM-bpf enforcement, hand-writing
   a workload profile is impractical at scale. We'd want a "learn
   mode" — agent in audit-only mode observes the workload for a
   period, emits a candidate profile, operator reviews and promotes
   to enforce. Existing observation plane already collects most of
   what's needed; mining a profile from it is the missing piece.
5. **Verifier vs program complexity.** The eBPF verifier limit caps
   program complexity. Some enforcement patterns (deep packet
   inspection, complex state machines) may need split-program
   designs with tail calls. Want a design pass on each candidate
   policy class to confirm verifier-feasibility.

---

## What success looks like

12 months from a green-light decision:

- One `eob-xc-install`-style bundle that deploys observation +
  enforcement together at any XC edge type.
- A `ProtectionPolicy` CR catalog with ~10 policies covering DDoS
  scrubbing, tenant egress, cross-tenant pod-to-pod, control-plane
  syscall lockdown, and credential-exfil patterns.
- The fleet console (consumer of `eob-mcp` aggregate) can show
  enforcement decisions in real time, federated across all edges.
- A documented soak procedure: every new policy ships in
  `mode: audit` for N days before flipping to `mode: enforce`.
- Performance: enforcement adds < 2% CPU on a fully-loaded CE node,
  < 1% on RE under peering load.

That's the destination. Today's `eob-xc-install` puts us on the
on-ramp — same eBPF runtime, same operator pattern, same federation
surface. The protection capability is the second half of the same
investment.

---

## Related documents

- [INFRASTRUCTURE-POSITIONING.md](INFRASTRUCTURE-POSITIONING.md) —
  why EoB / this stack should be treated as site infrastructure
- [UPSTREAM-FIXES.md](UPSTREAM-FIXES.md) — Mantis-side fixes that
  reduce the local glue needed to operate either plane
- [HOSTING.md](HOSTING.md) — production-readiness scorecard for the
  observation plane today; most items carry over to protection
- [RUNBOOK.md](RUNBOOK.md) — operational walkthrough; the protection
  agent would add steps to the same procedure
