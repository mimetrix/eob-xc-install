# An eBPF-based defense plane for F5 XC sites

A proposal for an eBPF-native security capability that runs on every F5
XC site type — Customer Edge, Regional Edge, Controller — as **a new
co-installed eBPF component**, alongside but distinct from the existing
EoB observation stack. Synthesizes enforcement (XDP/TC/cgroup-bpf/LSM)
and deception (observation-side polymorphism, RACE-style) on its own
agent runtime, ties them together with Moving Target Defense primitives,
and federates across the fleet through the existing `eob-mcp` gRPC
surface.

**Important framing up front:** this is **not an extension of EoB.**
EoB is an SRE / observability tool with its own mission, lifecycle, and
operational profile — it stays unchanged and remains always-installed.
The defense component proposed here is a **separate eBPF agent** with
its own DaemonSet, its own CRDs, its own trust chain, and its own
always-on lifecycle. The two coexist on the same nodes, share some
infrastructure (the kernel runtime, the federation surface, the install
bundle), and feed each other (defense uses EoB's pipeline as a sensor
exit), but they are not the same component. §2 enumerates the boundary;
§4.4 makes the operational separation concrete.

Companion to:
- [`INFRASTRUCTURE-POSITIONING.md`](INFRASTRUCTURE-POSITIONING.md) — why
  this stack belongs at the site-infrastructure layer
- [`EBPF-PROTECTION-DESIGN.md`](EBPF-PROTECTION-DESIGN.md) — the
  enforcement plane in detail (the earlier design memo this supersedes
  by widening to include observation + deception)
- [`UPSTREAM-FIXES.md`](UPSTREAM-FIXES.md) — Mantis-side fixes that
  retire the local glue we currently carry
- [`../eob-mcp/docs/MOTIVATION.md`](../eob-mcp/docs/MOTIVATION.md) — the
  VZW (AI-driven ops) and ATT (multi-site federation) customer anchors
  that scope the federation requirements
- *RACE Framework v0.5* (Eugene Starin, April 2026) — the
  observation-side-polymorphism approach this design adopts as its
  deception plane

---

## TL;DR

**Two co-installed eBPF components — EoB (observation, unchanged) and
the F5 Defense Agent (new, always-on, enforcement + deception) —
federated by `eob-mcp`.**

```
                  ┌─────────────────────────────────────┐
                  │     Fleet aggregator (per VZW/ATT)  │
                  │     gRPC + MCP via eob-mcp          │
                  └────────────────┬────────────────────┘
                                   │ ClusterRef-tagged streams
                                   ▼
       ┌──────────────────  one XC site, every node  ──────────────────┐
       │                                                               │
       │   ┌─────────────────────┐         ┌─────────────────────┐     │
       │   │   EoB agent DS      │         │ F5 Defense Agent DS │     │
       │   │   (Mantis Tawon)    │         │       (NEW)         │     │
       │   │   SRE / observation │         │  always-on firewall │     │
       │   │                     │         │                     │     │
       │   │   capture           │         │  ENFORCEMENT plane: │     │
       │   │   payload           │         │   XDP drop          │     │
       │   │   dns decode        │         │   TC rate-limit     │     │
       │   │   investigation-    │         │   cgroup-bpf        │     │
       │   │   driven (start/    │         │   LSM allow-list    │     │
       │   │   stop-windowed)    │         │                     │     │
       │   │                     │         │  DECEPTION plane:   │     │
       │   │                     │         │   /proc poly        │     │
       │   │                     │         │   crash poly        │     │
       │   │                     │         │   banner poly       │     │
       │   │                     │         │   error-code norm   │     │
       │   │                     │         │                     │     │
       │   │   Mantis-owned      │         │   F5-owned          │     │
       │   │   lifecycle         │         │   lifecycle         │     │
       │   └─────────┬───────────┘         └──────────┬──────────┘     │
       │             │                                │                │
       │             └────────────┬───────────────────┘                │
       │                          ▼                                    │
       │            shared (kernel + federation + bundle)              │
       │  ┌──────────────────────────────────────────────────────┐     │
       │  │ • Kernel eBPF runtime (kernel 5.14, RHEL 9, per node)│     │
       │  │ • NATS JetStream (separate subject namespaces)       │     │
       │  │ • eob-mcp gRPC + MCP federation surface              │     │
       │  │ • eob-xc-install bundle deploys both                 │     │
       │  │ • Trust anchor: F5 voucher webhook + LKIM/SeaBee     │     │
       │  └──────────────────────────────────────────────────────┘     │
       └───────────────────────────────────────────────────────────────┘
```

The two are deliberately separate components because their missions
diverge:

| Property | EoB | Defense Agent |
|---|---|---|
| Mission | SRE observability for investigations | Always-on security mitigation |
| Lifecycle | Per-directive `startAt`/`stopAt` windowed | Always running once installed |
| Failure mode | "We miss some packets" — acceptable | "We drop legitimate traffic" OR "we admit bad traffic" — both serious |
| Operator | Mantis-owned (Tawon operator) | F5-owned (new operator) |
| CRDs | `ClusterDirective` / `Directive` family | `ProtectionPolicy` / `DeceptionPolicy` / `WorkloadProfile` |
| Privilege | Privileged for eBPF capture | Privileged for eBPF + may need LSM-bpf load |
| Trust chain | Inherits Mantis chart signing | F5 voucher signing root |

What they share (and why this still composes as one design):

- **One eBPF runtime** — kernel hooks are visible to both agents; they
  attach independently and don't interfere.
- **One federation surface** — `eob-mcp`'s gRPC + MCP front doors
  expose both agents' state. EoB streams go through `stream_*` RPCs;
  defense agent events go through `EventStream` and a new
  `defense_*` RPC family if needed.
- **One install bundle** — `eob-xc-install` ships installers for both;
  the operator team installs them together.
- **One trust anchor** — F5 voucher signing root covers both, with
  separate signing keys per component if granularity is needed.
- **MTD primitives applied across both** — port/identifier rotation
  for surfaces that can move; observation polymorphism for the
  defense agent on surfaces that can't.

The single largest claim: **EoB stays as the SRE plane that's there
no matter what; the F5 Defense Agent is the new, always-on mitigation
component built specifically for the AI-era threat model.** It is not
a refactor of EoB and it is not a competing platform; it is a new
eBPF-native firewall designed from the start to coexist with EoB on
every F5 XC site.

---

## 1. Threat landscape per edge type

The three F5 XC edge types have meaningfully different threat profiles
and therefore different eBPF-plane configurations. The same architecture
ships everywhere; only the per-plane policy varies.

### 1.1 Customer Edge (CE) — multi-tenant kernel

The CE is where everything we've been building runs today. The threat
shape:

- **Tenants share a kernel.** Vega CNI gates L3 between tenant
  namespaces; nothing inside k8s gates L4+ between pods that share a
  node, nothing inside a tenant gates intra-pod kernel access (audit
  posture: zero NetworkPolicies cluster-wide, no PodSecurityStandards
  enforcement).
- **Platform infra coexists with tenants on the same boxes** —
  voucherd, vpm, vegacfgd, FRR, IPsec, envoy. A tenant-workload
  compromise that reaches even `/proc` reveals platform internals.
- **The dominant attack pattern is AI-accelerated reconnaissance against
  the platform underneath the tenant workload** — fingerprinting,
  asset mapping, configuration inference. CVE-2026-4747-class kernel
  exploits then chain into platform compromise.

### 1.2 Regional Edge (RE) — peering-volume traffic

The RE handles north-south traffic at WAN scale. The threat shape:

- **High-volume reconnaissance is cheap.** Internet-side adversaries
  scan continuously; behind any small fraction of those scans is an
  AI that can reason about responses at machine speed.
- **DDoS and scraping are perpetual.** Rate-limiting in userspace
  burns cores.
- **Control-plane targets matter most.** BGP peers, configuration
  APIs, voucher-signed identity issuance — anything that lets an
  attacker influence routing or inject signed mutations is a
  high-value target.

### 1.3 Controller / Control plane — high-trust, low-tolerance

The XC control plane is the deepest trust zone. The threat shape:

- **Insider risk + credential theft dominate.** External reconnaissance
  is gated heavily; the relevant attacker is one who has already
  reached the control plane via some other path.
- **Lateral movement inside control pods would be catastrophic** — the
  control plane signs everyone's voucher HMACs and ships policy to
  every CE/RE.
- **Compliance and audit posture demand defense-in-depth even where
  external probing is unlikely.** "Trust but verify" is the wrong
  posture; "verify continuously, deny by default" is right.

---

## 2. Two components

### 2.1 EoB — stays as-is, SRE / observability

EoB is the **SRE / observability layer that's already there and stays
there.** Its mission is "help operators investigate what's happening on
this site." That mission is well-served by:

- Time-bounded ClusterDirectives (start/stop windowed)
- Investigation-shaped CRD CRUD (apply a capture, run for 15 minutes,
  consume the stream, stop)
- The Tawon operator's lifecycle (chart-driven, Mantis-owned)
- The existing `payload` / `capture` / `dns` decoder task graph

These properties are wrong for a firewall (no on-call wants their
firewall to expire on a 10-minute window) but exactly right for SRE.
The defense design does **not** modify EoB's CRDs, its operator, its
DaemonSet, its agent runtime, or its lifecycle.

What the defense design does take from EoB:
- **Sensor exit** — when the defense agent's eBPF hooks observe an
  adversarial probe, the corresponding metadata can be published to
  an EoB stream and federated through `eob-mcp.TailStream` /
  `EventStream`. Adding a new `adversarial-probe-detect` decoder task
  to the EoB stack is one tractable shape for this; running the
  defense agent's own JetStream publisher on a `defense.*` subject
  namespace is another. Either way, no EoB code changes, only new
  configuration on the existing pipeline.
- **Federation envelope** — `ClusterRef` on every defense-agent
  response uses exactly the same envelope EoB does, so the fleet
  aggregator sees one consistent identity model for both components.

So when this memo says "the defense plane uses EoB's pipeline as a
sensor exit," what it means concretely: the defense agent publishes
adversarial probe events to NATS (the same JetStream EoB uses), tagged
with the same `ClusterRef`, and consumed by the same `eob-mcp.gRPC`
surface. EoB itself is unaware.

### 2.2 The F5 Defense Agent — new, always-on eBPF firewall

The new component this memo proposes. It is a separate DaemonSet, with
its own operator and CRD set, designed for the always-on mitigation
mission. Internally it carries two planes:

#### 2.2.1 Enforcement plane

The design from [`EBPF-PROTECTION-DESIGN.md`](EBPF-PROTECTION-DESIGN.md):
`ProtectionPolicy` / `PolicyBinding` / `WorkloadProfile` CRDs,
compiled into BPF map state, distributed to per-node defense agents,
XDP/TC/cgroup-bpf/LSM-bpf hooks loaded per-host with fail-closed
defaults. **Adopted as-is** with one revision: it lives inside the
defense agent component, not as a plug-in to EoB.

Key F5 XC integration points carry over:
- TC priority range tenant-allocated, coexisting with Vega CNI's
  positions
- XDP attach on RE NICs requires platform team's blessing (signed
  programs only)
- LSM-bpf on controllers requires audit-mode-first soak, never
  enforce-day-one

#### 2.2.2 Deception plane — RACE on F5 XC

The new plane this memo adds. Adopts RACE wholesale with five F5
XC-specific specializations:

**(a) Trust anchor reuse, not duplication.** RACE's §5.1 deployment
profiles describe a PDP that issues per-session grants. F5 XC already
has a PDP-shaped component: the **voucher webhook** signs every pod's
mutation HMAC and is the existing trust root for `ves-system` identity.
RACE's PDP becomes a *sibling* of voucher, not a replacement — same
signing key root, same identity model, same `disablePikuWebhook`
exemption pattern for control-plane components that need passthrough.
This avoids inventing a new trust framework and ties the deception
plane to F5's existing operational identity.

**(b) Selective coverage that respects platform legibility.** RACE's
§3.3 selectivity argument is sharper on F5 XC than on a generic Linux
box because we have *more* legitimate kernel-surface consumers than
most stacks (voucherd reading `/proc/<pid>`, vpm reading
`/etc/containers/registries.conf.d`, FRR / BGP reading network stack
state). Default category-A coverage on a CE site:

| Channel | Category | Notes |
|---|---|---|
| Tenant pod crash output | A — per-observation random | Hardest signal to leak |
| Tenant pod `/proc/<pid>/maps` | A — per-observation random | Same |
| `kallsyms` from tenant pods | A — per-observation random | (Linux already partial via `kptr_restrict`; we generalize) |
| Service banners egressing tenant namespace | B — per-session consistent fake | Phantom-convergence target |
| Error codes on filesystem paths | B — per-session consistent fake | |
| Container runtime metadata leaked to tenants | A or B | per channel |
| `ves-system` reads of any of the above | C — passthrough | Platform-side legibility preserved |
| voucher webhook reads of mutation HMACs | C — passthrough | Trust root |

Categories (A) and (B) apply *only when the consumer is an
unauthenticated remote observer or an authenticated tenant workload
reading the platform's surface*. The `ves-system` identity model
(already signed via voucher) inherits passthrough by default.

**(c) Federated coherent fiction.** RACE's §3.6 context-engineering
frame plus phantom-convergence (§3.2) becomes especially powerful in a
multi-site setting. When ATT's aggregator coordinates fictional state
across N CE sites, an attacker probing site X and triangulating against
site Y sees a **consistent fictional system** at both. The coherent
fiction is a fleet-wide property, not a per-site property. Aggregator
publishes the fiction parameters via `eob-mcp.BatchApply`; each site's
deception plane consumes them and presents the same fictional banner
strings, the same fictional kernel build, the same fictional service
inventory. Triangulation across sites stops being a leak.

**(d) Sensor-driven adaptive fiction (RACE §8.5) via existing federation.**
RACE's §4.6 dual-nature argument (every polymorphing hook is also a
sensor) maps directly onto EoB's existing observation pipeline. The
adaptive-fiction extension — reading attacker hypothesis trajectory in
real time, tuning fiction to reinforce convergence on decoy resources —
becomes a fleet-wide closed loop:

```
attacker probes site X
    ↓
RACE hook polymorphs the response, emits probe metadata to EoB stream
    ↓
EoB publishes via NATS, aggregator consumes via eob-mcp.TailStream
    ↓
Aggregator's analysis (LLM-driven, per MOTIVATION.md VZW shape) infers
the attacker's converging hypothesis
    ↓
Aggregator updates fiction parameters via eob-mcp.BatchApply across
sites X, Y, Z
    ↓
Next probe at any site reinforces the fiction
```

This is the AI-defender symmetry argument from RACE §1.2 actualized:
**the defender's AI consumes the attacker's probes via EoB; the
defender's AI tunes the deception via `eob-mcp`'s BatchApply**. Both
halves of the loop are LLM-shaped, both live on infrastructure VZW is
already building toward.

**(e) Profile granularity at the tenant namespace.** RACE's two
profiles (default = OS-identity passthrough, strict = zero-trust
per-session) become a per-tenant configuration on the CE. Some tenants
opt into strict for their own namespaces; others accept default. The
platform's `ves-system` namespace is always category-C-on-most-channels
regardless of profile choice (the platform's own legibility is
non-negotiable).

---

## 3. MTD where it actually fits

The defense plane uses Moving Target Defense as a *primitive*, not a
plane unto itself. MTD's classical move — rotate internal state — is
the right tool for some surfaces and not for others. Synthesizing with
the RACE-shaped observation-side polymorphism:

### 3.1 State-side MTD (rotate the real thing)

| Surface | Rotation cadence | Why MTD wins here |
|---|---|---|
| **Per-directive eBPF agent ports** | Per agent identity (already implemented in `eob-mutate`) | Real ports change per directive; observation polymorphism not needed because the consumer is internal-only |
| **mTLS cert rotation** | Hours to days | Real keys change; SPIFFE/short-lived SVIDs canonical |
| **Ephemeral resource identifiers** | Per session | Stream names, JetStream consumer IDs, NATS subjects — rotate so an attacker who learns one can't reuse it |
| **Site-issued audit tokens** | Per request | Audit-trail metadata for the `Actor` field on `EventStream` |

These are surfaces where the *real* value can change without breaking
anything — and where the consumer needs to know the current value
through a trust channel (mTLS, voucher) rather than by direct
observation. Classical MTD.

### 3.2 Observation-side polymorphism (transform what's seen)

| Surface | Why observation polymorphism wins |
|---|---|
| **Kernel addresses in crash output, `/proc`** | Can't rotate without rebooting; observation polymorphism is the only runtime option |
| **Service banners egressing to unauthenticated observers** | Real banners can rotate but breaks operations; fictional banner per session is cheaper |
| **Error code differentiation on filesystem paths** | Real errors are needed by legitimate consumers; fictional/normalized errors for adversarial probing |
| **TCP stack fingerprinting** | Real stack is fixed by kernel build; per-flow polymorphism (TTL, options ordering) is the runtime move |

These are surfaces where the *real* value can't change without breaking
the system, but the observable face *can* be transformed selectively
for unauthenticated consumers. RACE.

### 3.3 Synthesis

The two are complementary, not competing. State-side MTD rotates what
can rotate; observation-side polymorphism transforms what can't. The
defense plane uses both, and **the federated fleet coordinates the
rotation cadence and the fiction parameters together**: when the
aggregator decides "rotate state-side identifiers everywhere AND
present fictional banner Y everywhere," both halves happen in lockstep
via the same `BatchApply` call. The attacker who learns the real
identifier sees it rotate; the attacker who reads the banner sees the
fiction.

---

## 4. F5 XC platform integration

The defense plane runs *inside* F5 XC, not alongside it. Required
integration:

### 4.1 Vega CNI ordering contract

eBPF programs at TC ingress need a stable priority position relative to
Vega's TC chain. Specifically:
- A documented "tenant-installable TC priority range" so our policies
  don't fight Vega's
- XDP attach permission for the deception plane's TCP-stack
  polymorphism programs
- Both depend on platform-team blessing; the engineering is small once
  the contract is documented (see UPSTREAM-FIXES.md for the asks
  framing).

### 4.2 Voucher webhook as PDP sibling

Rather than building a new PDP for the deception plane:
- **Issue defense-plane policies via voucher's signing root.** Every
  `ProtectionPolicy` / `DeceptionPolicy` CR is signed at the platform
  layer before it lands on a CE.
- **Identity grants reuse voucher HMACs.** A consumer that holds a
  valid voucher mutation HMAC is implicitly recognized by the
  deception PDP — no new identity issuance for `ves-system`
  components.
- **`disablePikuWebhook`-style namespace labels** opt namespaces out
  of polymorphism (for `kube-system`, `ves-system`, etc.).

This makes adoption a *configuration* exercise for the F5 platform
team, not a separate identity-system rollout.

### 4.3 LKIM + SeaBee + Invary trust chain

RACE §4.5 already specifies these. F5 XC + RACE specifics:
- LKIM (commercialized as Invary, licensed from NSA) continuously
  attests kernel + loaded eBPF programs are unmodified
- SeaBee enforces only signed eBPF policies load
- Signing root co-resident with voucher signing root (probably on F5's
  HSM infrastructure already)

This closes the "the firewall itself is in the trust path" problem:
- Hardware verifies boot
- LKIM/Invary attest kernel + eBPF runtime
- SeaBee verifies eBPF policy signatures before load
- Voucher signs every policy + mutation
- The defense plane's `ClusterRef`-tagged audit events end up in the
  fleet aggregator with cryptographic provenance from signing root
  through to publication

### 4.4 Coexistence with EoB

The defense agent and the EoB agent are **two separate DaemonSets on
the same nodes**, sharing infrastructure but not implementation:

| Concern | EoB agent | Defense agent | Shared? |
|---|---|---|---|
| DaemonSet | `tawon-directive-*` (one per directive) | one `f5-defense-agent` always running | no — separate DSes |
| Operator | tawon-operator (Mantis) | new F5-owned defense operator | no — separate operators |
| eBPF programs | observation (capture, payload, dns) | enforcement (XDP/TC/cgroup/LSM) + deception (RACE) | no — separate program objects |
| Kernel hooks | shared by kernel, attached independently | shared by kernel, attached independently | yes — kernel runtime |
| CRDs | Tawon's `ClusterDirective` family | `ProtectionPolicy` / `DeceptionPolicy` / `WorkloadProfile` | no — separate API groups |
| NATS subjects | `payload-*`, `capture-*`, `dns-*` | `defense.events`, `defense.audit`, `defense.probes` | yes — same JetStream, different subjects |
| Admission webhook | `eob-mutate` injects hostNetwork + hostAliases | extended to also gate `f5-defense-agent` pods by name prefix | yes — same webhook with broader prefix list |
| Federation | `eob-mcp.stream_*` + `WatchResources` on `tawon.*` | `eob-mcp.EventStream` for audit/probes; `WatchResources` on `protection.*` API group | yes — same `eob-mcp` instance |
| Image registry | `quay.io/mantisnet/*` mirrored locally | new namespace, e.g. `gcr.download.volterra.us/f5xc/defense-agent` | partially — same in-cluster mirror service |
| Install flow | `helm install tawon-operator` | `helm install f5-defense-operator` (new) | both bundled in `eob-xc-install` |

Operationally, **`eob-xc-install` becomes the bundle that installs
both** — EoB first (today's behavior), then the defense agent on top.
A site that runs only EoB today is unaffected; a site that adopts the
defense agent gets both DaemonSets co-resident on every node with no
modification to EoB's behavior.

Why not one agent loading both program sets? Three reasons:

1. **Lifecycle divergence.** EoB's per-directive lifecycle (start/stop
   windows) is wrong for a firewall. Sharing a DaemonSet would force
   one of the two missions into the wrong shape.
2. **Failure isolation.** A bug in the EoB observation pipeline must
   not be able to take down the firewall. Separate DaemonSets, separate
   operators, separate restart blast radii.
3. **Ownership clarity.** EoB is Mantis-owned; the defense agent is
   F5-owned. Separate components let the two ownership boundaries stay
   clean across upgrades, audits, signing, and incident response.

### 4.5 Audit posture closing

The security audit report from our recent scan called out concrete
gaps. The defense plane closes them:

| Audit finding | Defense plane closure |
|---|---|
| **No PodSecurityStandards** | Enforcement plane's LSM-bpf `WorkloadProfile` is a richer alternative; PSA labels still applied for defense-in-depth |
| **No NetworkPolicies** | Enforcement plane's TC + cgroup-bpf hooks enforce per-pod ingress/egress at the kernel layer |
| **No secrets encryption at rest** | Not directly addressed; requires `--encryption-provider-config` on apiserver (orthogonal) |
| **Automount SA tokens default-on** | Enforcement plane LSM hook can deny syscall use of automounted tokens not on the workload's profile |
| **Audit log local-only** | Defense plane's federation pushes audit events to the fleet aggregator — remote sink built in |
| **mTLS cert provisioning** | State-side MTD's cert rotation is part of this design |

---

## 5. Per-edge-type configuration

### 5.1 CE deployment

```
Per node:                            Per tenant namespace:
  3 eBPF program objects loaded         ProtectionPolicy + Binding CRs
  ┌─ observation (EoB existing)        DeceptionPolicy + Binding CRs
  ├─ enforcement (new)                 WorkloadProfile CRs
  └─ deception (new)                   Operator's namespace gets
                                       category-C-on-most-channels
Trust:
  Voucher HMAC for platform identity
  Defense-plane policies signed by voucher signing root
  LKIM/Invary attesting kernel + eBPF programs
```

Default coverage shape: tenant pods get observation polymorphism on
their kernel surface, deception fiction on egress, enforcement on
syscalls violating their profile. Platform pods get pass-through.

### 5.2 RE deployment

```
Per node (typically dedicated NICs):
  XDP-heavy enforcement (DDoS scrubbing, rate-limit, IP-block)
  Observation polymorphism on egress-banner channel
  Lightweight LSM-bpf (fewer workloads to lock down)

Trust:
  Same voucher root; signed XDP programs only
  RE-specific WorkloadProfile (mostly BGP/peering daemons)
```

The deception plane on RE is mostly category-B (per-session
banner/version fakes) — the high-volume probes are mostly fingerprinting
scans, not exploit chains, so phantom convergence on a fictional
network stack is the high-value posture.

### 5.3 Controller deployment

```
Per node:
  LSM-bpf-heavy enforcement (deny by default, allow per WorkloadProfile)
  Observation polymorphism on ALL kernel surfaces (high coverage)
  Audit-mode-first for every new rule

Trust:
  Voucher root + secondary controller-tier sign
  LKIM continuous attestation; eBPF programs verified per load
```

Controller is the highest-trust environment so it gets the deepest
deception coverage — every channel category-A or category-B, no
category-C except for the cryptographic trust roots themselves.

---

## 6. Federation: how the fleet sees the threat

The single largest architectural payoff: **every probe at every site
flows back through `eob-mcp.EventStream` to the fleet aggregator.**

The aggregator, which is consumed by VZW's AI effort on the MCP side
and ATT's federation console on the gRPC side (see
[MOTIVATION.md](../eob-mcp/docs/MOTIVATION.md)), gets:

- A real-time, multi-site adversarial probe stream tagged with
  `ClusterRef` so probes can be merged by site and across sites
- Coherent fictional-system parameters distributed to every site via
  `BatchApply`
- Adaptive fiction tuning via the closed loop in §2.3(d)
- Cross-site triangulation defeat — coherent fiction across sites means
  an attacker probing site X and site Y sees consistent (fictional)
  data
- Threat intelligence accumulation: probe-pattern fingerprints, AI vs
  scanner vs human attack profiles, hypothesis-tree reconstructions
  per site, per region, per time window

This is what the RACE framework calls "Runtime Adversarial Context
Engineering" applied at fleet scale. The context being engineered is
the context the attacker's LLM consumes; the engineering happens at
runtime; the runtime is *every site, coordinated*.

---

## 7. Proof of concept — start where?

Building the entire defense plane is a multi-quarter effort. The
right opening move is RACE's own PoC: **service-banner randomization
on TC egress, deployed on one CE site, with banner choices coordinated
across all three of that site's nodes via the existing eob-mcp
`BatchApply`.**

Scope:
- One TC egress program, attached to all 3 masters of one CE site
- Banner rewriting for SSH version string on outbound responses
- Two modes: per-observation random and per-session consistent-fake
  (the consistent-fake driven by aggregator-published parameters)
- Reuses `eob-mcp.EventStream` to publish every observation of an
  external scan (Nmap, banner-grab) with the response that was
  actually emitted
- Off-the-shelf attacker tools: `nmap -sV`, `nc`, plus optionally an
  internal LLM agent run from a separate machine

Demonstrates end-to-end:
- The MTD primitive (rotating fictional banner)
- The federation envelope (probe + response tagged with site identity)
- The fleet feedback loop (aggregator can change fiction parameters
  on the fly and observe the attacker's reaction)
- Coexistence with EoB (the existing EoB stack runs unchanged
  alongside)

Implementation cost: ~1–2 weeks for one engineer familiar with eBPF
and the existing EoB stack. Demonstrates the full architecture at
one channel; subsequent channels are then engineering, not
architecture.

---

## 8. What this does not solve

Following the same honest scope-bounding pattern as RACE §6.2:

- **Application-layer vulnerabilities.** Deception plane is below the
  application; bugs in tenant apps remain bugs.
- **Compromised platform identity.** If voucher's signing key is
  compromised, the trust root falls. Defense plane inherits that risk.
- **Insider with full XC admin.** Anyone with platform-admin scope
  reaches passthrough by design (category C).
- **Physical access.** Out of scope.
- **Boot-time compromise before LKIM attestation runs.** Same threat
  model as Invary itself.
- **Operational failure.** An administrator who disables the firewall
  to debug a 2-AM crash leaves the system exposed. The default-vs-strict
  profile design from RACE §5.1 is the structural mitigation; the
  cultural mitigation is operational discipline.
- **AI defender getting outmatched by AI attacker.** The closed-loop
  adaptive fiction (§2.3(d)) works only as well as the defender's AI
  can reason. The symmetry problem doesn't go away; it gets rebalanced
  toward defender-side LLM capability investments.

---

## 9. Roadmap

In rough order of value × tractability. The defense agent is
**greenfield code** — a new DaemonSet, new operator, new CRDs, new
image — but it lives on infrastructure (kernel, install bundle, NATS,
`eob-mcp`) that already runs. Each phase below is the defense agent
gaining a capability; EoB is unchanged throughout.

| Phase | Deliverable | Effort | Customer-pull |
|---|---|---:|---|
| **0** | Banner-randomization PoC at one CE site (§7). Single-purpose binary, single TC egress program, no operator yet — bare-minimum proof that the deception primitive works end-to-end and federates back through `eob-mcp` | 1–2 wks | Validates story; demonstrates feasibility |
| **1** | F5 Defense Agent v0: standalone DaemonSet (Go binary loading eBPF programs), `DeceptionPolicy` CRD, voucher signing root integration, install added to `eob-xc-install`. Deception plane only (RACE): `/proc`, crash output, banner egress on CE | 2–3 mo | VZW (richer signal for AI ops, deception participation as a fleet primitive) |
| **2** | F5 Defense Operator v0 + `ProtectionPolicy` / `WorkloadProfile` CRDs from the protection design memo. Adds enforcement plane: XDP/TC/cgroup-bpf, audit-mode-first. CE-first | 3–4 mo | Closes the audit gaps the recent posture scan called out |
| **3** | LSM-bpf integration for enforcement plane; LKIM/SeaBee/Invary trust chain integration; signed-policy load via SeaBee root | 2 mo | Required before controller-tier deployment |
| **4** | Fleet coordination: coherent fiction across sites via `eob-mcp.BatchApply`; aggregator-side fiction-parameter publishing | 1 mo | ATT (federated console sees the fleet as one) |
| **5** | Adaptive fiction closed loop with defender-side LLM (the §6 architecture in full) — aggregator reads attacker hypothesis trajectory in real time, retunes fiction parameters | open-ended | VZW (closes the AI-on-AI loop) |
| **6** | RE deployment shape (XDP-heavy, driver-mode where possible); controller deployment shape (LSM-bpf-heavy, deny-by-default) | 2–4 mo per edge type | Once CE is solid |

The CE-first sequencing is deliberate. The audit posture today (no PSA,
no NetworkPolicy, no secrets encryption) means the defense agent has
the most measurable impact on CE first; the engineering risk is
lowest because the kernel and install infrastructure already work
there (we know exactly what the eBPF runtime looks like, because EoB
runs on it); the customer pull (VZW + ATT) is anchored on CE.

---

## 10. Naming, eventually

This memo deliberately doesn't pick a product name. Internally the
work has been called variously "the protection design," "ACE/RACE,"
"observation-side polymorphism," "MTD-X." Any of these or none could
become the F5-marketed name; the technical architecture is what matters
for the design phase. When marketing names it, the underlying
mechanism is still:

- eBPF on every node, three program objects per agent
- Federated by `eob-mcp` across the fleet
- Trust-anchored on voucher + LKIM + SeaBee
- MTD primitives where the surface can rotate; RACE-shaped
  observation-side polymorphism where it can't
- One canonical contract (the proto) consumed by AI agents (MCP) and
  service consumers (gRPC) alike

---

## Related documents

- [`INFRASTRUCTURE-POSITIONING.md`](INFRASTRUCTURE-POSITIONING.md) —
  why this is site infrastructure, not a tenant workload
- [`EBPF-PROTECTION-DESIGN.md`](EBPF-PROTECTION-DESIGN.md) — the
  enforcement plane in detail (predecessor design memo)
- [`UPSTREAM-FIXES.md`](UPSTREAM-FIXES.md) — Mantis-side fixes that
  retire the local glue we currently carry around the EoB stack
- [`HOSTING.md`](HOSTING.md) — production-readiness scorecard
  for the existing observation plane; same operational maturity
  trajectory applies to the new planes
- [`../eob-mcp/docs/MOTIVATION.md`](../eob-mcp/docs/MOTIVATION.md) —
  the VZW (AI ops) + ATT (federation) customer anchors that shape the
  federation requirements of this design
- *RACE Framework v0.5* (E. Starin, April 2026) — the deception plane
  is adopted wholesale from this paper, with the five F5
  XC-specific specializations in §2.3
