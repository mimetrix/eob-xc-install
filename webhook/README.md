# EoB mutating admission webhook

## What this is

A small mutating admission webhook that takes a Tawon agent pod admission
request and applies three mutations:

1. **hostNetwork bypass:** `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet`,
   so the pod skips Vega CNI. The Tawon operator generates the agent
   DaemonSet without `hostNetwork` and reverts external `kubectl patch`
   attempts that add it; admission-time mutation is the only place this
   sticks.
2. **NATS DNS workaround:** `hostAliases` entry mapping the streamstore
   FQDN (the operator hardcodes `tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local`,
   regardless of the site's actual cluster DNS suffix) and the short name
   `nats` to the streamstore Service ClusterIP. Without this the agent's
   NATS client gets NXDOMAIN and the directive sits Ready=False.
3. **Per-directive probe + metrics ports:** unique `containerPort` /
   `hostPort` values for the named ports `http-probes` and `http-metrics`,
   plus matching `TAWON_PROBES_ADDR` / `TAWON_METRICS_ADDR` env vars. Ports
   are SHA1-derived from the agent DaemonSet name so the same directive
   always gets the same ports across pod restarts. Without this, every
   agent on every directive binds `:8081`/`:9990` and the second
   ClusterDirective sits Pending with "no free ports for the requested
   pod ports" on every node.

All three are workarounds for Mantis-side gaps; once upstream fixes land
(hostNetwork knob on the agent DS, configurable probe/metrics addrs, env
honored for the streamstore FQDN), the webhook can be retired entirely —
see `../HOSTING.md` for the roadmap.

The webhook only matches pods with label `app.kubernetes.io/name=tawon-directive`
in namespace `tawon-operator`. Nothing else is affected.

## How it's deployed

The webhook server runs as a **systemd service on master-0**, not as a k8s pod.
That avoids the chicken-and-egg of trying to deploy a pod that itself can't run
because of the same Vega CNI issue, and sidesteps the need for an additional
container image. The server is ~120 lines of pure-stdlib Python listening on
TCP `:9443` by default. The port is configurable via `WEBHOOK_PORT=<n>`.

## Networking

The node's `vpm-segment-inbound` iptables chain only filters traffic on
`vhost-seg+` interfaces (Vega's tenant overlay). The k8s node IP lives on
`vhost0`, so master-to-master apiserver→webhook traffic isn't gated by it.
No firewall change is required. The AWS Security Group between the masters
already permits arbitrary TCP (verified by inspecting the wide spread of
established master-master TCP connections on ephemeral high ports).

`install.sh` checks that the chosen port is free on master-0 and otherwise
proceeds without an admin ask.

## Install

```bash
cd eob-xc-install/webhook
./install.sh
```

This will:
1. Discover the master-0 InternalIP and the NATS service ClusterIP.
2. Generate a self-signed TLS cert in `/etc/eob-mutate/`.
3. Drop `server.py` to `/usr/local/bin/eob-mutate.py`.
4. Write `/etc/eob-mutate/env` with discovered values.
5. Install + start `eob-mutate.service`.
6. `kubectl apply` a `MutatingWebhookConfiguration` pointing at
   `https://<master-0 ip>:9443/mutate` with the CA bundle inline.

## Verify

After install, force fresh agent pods and inspect:

```bash
kubectl -n tawon-operator delete pods -l app.kubernetes.io/name=tawon-directive --grace-period=0 --force
sleep 5
kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-directive \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}hostNetwork={.spec.hostNetwork}{"\t"}probe={.spec.containers[?(@.name=="tawon-directive")].ports[?(@.name=="http-probes")].hostPort}{"\t"}metrics={.spec.containers[?(@.name=="tawon-directive")].ports[?(@.name=="http-metrics")].hostPort}{"\n"}{end}'
```

Expected output (per pod, probe port in 18081..19080 and metrics port in 19990..20989):

```
tawon-directive-<directive>-<pod>: hostNetwork=true probe=18234  metrics=20143
...
```

To confirm two ClusterDirectives can co-exist on the same nodes, apply
both and verify:

```bash
kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-directive -o wide
# Expect 2 * <#nodes> pods, all Running, none Pending.
```

If `hostNetwork` is empty, check:

```bash
sudo journalctl -u eob-mutate.service -n 50
kubectl get mutatingwebhookconfiguration eob-mutate -o yaml
```

If both pods of competing directives schedule on the same node but the
later one is in CrashLoopBackOff with `bind: address already in use`,
the live webhook is an older version that doesn't do per-directive port
remap. Redeploy `server.py` and `sudo systemctl restart eob-mutate.service`.

## Per-directive port remap behavior

The port assignment is deterministic per DaemonSet name (the owner of
the admitted pod). Two pod-replacements of the same directive get the
same port; two different directives get different ports.

Tunables (set in `/etc/eob-mutate/env`, then `sudo systemctl restart eob-mutate.service`):

| Env var | Default | Meaning |
|---|---|---|
| `PROBE_PORT_BASE` | `18081` | First port of probe range |
| `PROBE_PORT_RANGE` | `1000` | Size of probe range (ports `[BASE, BASE+RANGE)`) |
| `METRICS_PORT_BASE` | `19990` | First port of metrics range |
| `METRICS_PORT_RANGE` | `1000` | Size of metrics range |

Defaults give 1000 directive slots before the birthday-paradox collision
probability gets uncomfortable; in practice you'll be limited by node
resources well before then. If you start running > ~20 directives
concurrently in one cluster, raise both `*_RANGE` values to 10000.

The remap does NOT touch:

- `probe.httpGet.port` references in liveness/readiness/startup — those
  reference the named containerPort (`http-probes`) and auto-track.
- The Prom metrics scrape config — Prometheus will need to discover the
  per-directive port. See `HOSTING.md` §9 for the suggested pattern.

## Caveats

- **master-1 / master-2 still lack the agent image.** Without the in-cluster
  registry mirror, the agent DS will spawn pods cluster-wide and only master-0
  will reach Running — master-1/2 will sit in `ImagePullBackOff` because the
  image hasn't been loaded into their cri-o caches. The webhook does *not*
  try to pin to master-0 via a `nodeSelector` injection — doing so would
  interact weirdly with the DaemonSet controller (it'd refuse to spawn
  replicas for unselected nodes). Address master-1/2 with the in-cluster
  registry — see `../README.md` Multi-node images section.
- **The webhook re-reads the NATS ClusterIP at install time only.** If the
  StreamStore Service is deleted and recreated with a different ClusterIP,
  re-run `install.sh` (or just update `NATS_IP=` in `/etc/eob-mutate/env`
  and `sudo systemctl restart eob-mutate.service`).
- **Self-signed cert valid for 10 years**, no rotation. Fine for staging.
- **Single point of failure on master-0**: if the systemd unit crashes,
  pod admission for `tawon-directive`-labeled pods fails (`failurePolicy: Fail`).
  `journalctl -u eob-mutate.service` for triage. If you need to remove the
  webhook in a hurry: `kubectl delete mutatingwebhookconfiguration eob-mutate`.
  Production fix: convert to 3-replica DS or 3 sibling systemd units.
  See `../HOSTING.md` §1.

## Uninstall

When the XC admin provisions a real Vega VN binding for the `tawon-operator`
namespace, this webhook becomes unnecessary (and harmful — it'd force
hostNetwork when not needed). Remove with:

```bash
cd eob-xc-install/webhook
./uninstall.sh
```

Then force a fresh agent pod cycle so the new pods spawn without the mutation:

```bash
kubectl -n tawon-operator delete pods -l app.kubernetes.io/name=tawon-directive --grace-period=0 --force
```

## Files

| File | Purpose |
|---|---|
| `server.py` | Python admission webhook (stdlib only) |
| `eob-mutate.service` | systemd unit |
| `mutating-webhook-config.yaml.tmpl` | `MutatingWebhookConfiguration` with `__HOST_IP__` / `__CA_B64__` placeholders |
| `install.sh` | Discovers IPs, generates cert, installs systemd, applies webhook config |
| `uninstall.sh` | Reverses everything |
