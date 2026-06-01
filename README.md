# EoB (Mantis Tawon) install on an F5 XC CE site

Installs `tawon-operator` v3.0.0-rc4 onto an F5 XC Customer Edge site (e.g. `srikan-tf-test-0`)
**as a peer of the F5 stack** — Vega, vpm, voucherd, cri-o, kubelet — rather than as a
tenant workload. Every component runs on the host network and integrates with the existing
host services (cri-o image storage, systemd, the host's containers/ config, the master-0
intra-VPC fabric). The Mantis-supplied chart is loaded as-is; F5-stack integration points
(image registry mirror, port assignment, DNS, agent admission-time mutation) are layered
around it.

Tested against site `srikan-tf-test-0` in tenant `platform-svc-nbryikfr` (staging) on
2026-05-29 with k8s `v1.34.2-ves`, CRI-O 1.34.2, podman 5.6.0, helm 3.16.4.

If you're running on a non-XC k8s cluster, use the upstream Mantis install instead — none of
this document applies.

---

## Why this procedure exists (read once)

The F5 XC CE site has a deliberate split between **tenant-workload k8s** (`vK8s`, driven
from the F5 XC console — auto-provisions namespaces/VNs/pull secrets/ingress) and the
**underlying site k8s** that runs the F5 stack itself. EoB doesn't fit the tenant model:
it ships an agent DaemonSet that needs to observe traffic on the host, and a streamstore
that needs to outlive any single tenant. So it installs at the **site infrastructure layer**,
alongside the F5-stack components.

That positioning shapes every design choice in this document. The five integration points
to understand before reading the procedure:

1. **Pod networking.** Vega CNI allocates pod-network sandboxes only for namespaces backed by
   a Virtual Network, and VN provisioning is cloud-pushed — there's no local API to register
   our namespace. As infrastructure, EoB doesn't need pod networking: every component runs
   `hostNetwork: true`, same pattern as `ves-system`. Vega is bypassed for our workloads.
2. **Port assignment.** `voucherd` owns TCP `:8443` on every node. The chart's `kube-rbac-proxy`
   listener moves to `:18443` (set in `values-override.yaml` + `patches/01-operator-deploy.yaml`).
   The operator's manager probe moves to `:8181` so it stays out of the agent's way. Agent
   pods themselves get **per-directive probe/metrics ports** assigned at admission time by
   the `eob-mutate` webhook (probe in `:18081..:19080`, metrics in `:19990..:20989`, deterministic
   from directive name). That's what lets two ClusterDirectives co-exist on the same nodes
   without colliding on the default `:8081` / `:9990` — see [step 8](#8-install-the-agent-pod-mutating-webhook-unblocks-clusterdirectives).
3. **vpm-managed iptables.** The `vpm-segment-inbound` rules only match `-i vhost-seg+` (Vega's
   tenant overlay), so they don't filter host-side traffic on `vhost0` where the k8s node IP
   lives. Master-to-master apiserver/kubelet/etcd traffic and any host-side service bound to
   the node IP are not gated by them. The AWS Security Group is the actual barrier for
   anything reaching a master from outside the VPC — see [Exposing the dashboard](#exposing-the-dashboard).
4. **Image storage.** Rootless `podman` (xcuser) populates xcuser's storage; cri-o reads from
   rootful storage. The site's image source for `quay.io/mantisnet/*` is a `registry:2`
   container hosted on master-0 (`172.31.44.247:5000`) and consumed by every node's cri-o
   via a registries.conf.d mirror — see
   [Multi-node images](#multi-node-images--in-cluster-registry-cluster-infrastructure).
   `load.sh` uses `sudo` to populate root storage; pushes to the local registry go from
   there.
5. **Cluster DNS.** XC sites use a tenant-specific suffix like
   `<site>.<tenant>.tenant.local`, not `cluster.local`. The Tawon operator's StreamReconciler
   *and* the dashboard's pktsapi (packet viewer / JetStream consumer path) both hardcode
   `.cluster.local` (the `KUBERNETES_CLUSTER_DOMAIN` env var is read on some controllers
   but not these two). We patch around this with a `hostAliases` entry on the operator pod
   *and* the dashboard pod, each mapping the hardcoded FQDN to the NATS ClusterIP. Two
   separate patches — hostAliases is per-pod. See
   [Discover the cluster DNS suffix](#discover-the-cluster-dns-suffix) and step 6.

---

## Prerequisites

> ⚠️ This README is the **conceptual reference** (the *why* of every
> decision). The **step-by-step operational walkthrough** with
> verification gates between phases lives in
> [`RUNBOOK.md`](./RUNBOOK.md). If you're installing from scratch,
> read RUNBOOK end-to-end first.

On master-0:

- SSH access as `xcuser` (key `~/.ssh/id_ed25519_xc`) — see memory `reference_xc_node_access`
- `sudo` to root works for `xcuser`
- `podman`, `helm`, `kubectl` on PATH

Cluster-side gates (`install.sh` Phase 0 auto-asserts these, but you
can pre-flight them manually too):

- **Default StorageClass must be `hostpath`** — the `standard` SC
  declares the in-tree aws-ebs provisioner that k8s 1.27+ removed, so
  PVCs against it hang forever.
- **Master nodes must carry `node-role.kubernetes.io/master`** — XC
  nodes only have `kubernetes.io/role=ves-master` by default, and
  Tawon's agent DS nodeAffinity requires the canonical label.
- **`tawon-config` CM's `namespacedDirective.nodeRoles`** must include
  `master` (default is `worker` only — XC sites have no workers).

Off-cluster:

- `eob-pull-key.json` — a Kubernetes Secret manifest with a quay.io dockerconfigjson
  containing valid credentials for `quay.io/mantisnet/*` (request via Thiago/Nicolas/Lowell)
- (Optional, only for browser access to the dashboard) AWS SG change — see [Exposing the dashboard](#exposing-the-dashboard)

---

## Procedure

All commands run on **master-0** as `xcuser`. Where `sudo` is required it's shown explicitly.

### 1. Configure quay auth (rootless AND rootful)

The pull-key secret you got is a Kubernetes Secret manifest containing a base64'd
`.dockerconfigjson`. Decode it and write the JSON to both auth stores so xcuser
podman *and* root podman/cri-o can authenticate.

```bash
# Extract the base64 .dockerconfigjson from the Secret YAML you were given.
# (the value of data..dockerconfigjson; example below uses the literal value)
DOCKERCONFIG_B64='<paste base64 value from Secret>'

# xcuser podman
mkdir -p ~/.config/containers
echo "$DOCKERCONFIG_B64" | base64 -d > ~/.config/containers/auth.json
chmod 600 ~/.config/containers/auth.json

# root podman + cri-o
sudo mkdir -p /root/.config/containers
echo "$DOCKERCONFIG_B64" | base64 -d | sudo tee /root/.config/containers/auth.json > /dev/null
sudo chmod 600 /root/.config/containers/auth.json
```

### 2. Pull the rc4 release package and extract

```bash
mkdir -p ~/eob && cd ~/eob

# Pull the package image (auth from step 1)
podman pull quay.io/mantisnet/eob-package:v3.0.0-rc4

# Extract the tarball from inside the image
CID=$(podman create quay.io/mantisnet/eob-package:v3.0.0-rc4)
podman cp ${CID}:/eob-release-package-3.0.0-rc4.tar.gz .
podman rm ${CID}

tar -xzf eob-release-package-3.0.0-rc4.tar.gz
cd release-package-3.0.0-rc4
```

### 3. Load images with **sudo**

> **Critical gotcha:** `./load.sh --runtime podman` (without sudo) loads into xcuser's
> rootless podman storage, which is *not visible* to cri-o on this RHEL. The pods will
> fail `ImagePullBackOff` even though `podman images` shows them. Always use sudo.

```bash
sudo RUNTIME=podman ./load.sh --runtime podman

# Verify cri-o can see them:
sudo crictl images | grep "v3.0.0-rc4"
```

You should see 8 images with `v3.0.0-rc4` (or `v0.13.0` for kube-rbac-proxy / `2.10.4-alpine` for nats).

> **Multi-node note:** `load.sh` populates master-0 only. Distribution to master-1/2 is
> handled by the in-cluster registry — see
> [Multi-node images — in-cluster registry](#multi-node-images--in-cluster-registry-cluster-infrastructure)
> below. On a fresh site, do the registry steps after step 3 and before applying any
> ClusterDirective.

### 4. Discover the cluster DNS suffix

This site's k8s DNS suffix is **not** `cluster.local`. You need the actual suffix for the
hostAliases workaround in step 6. Discover it from the master FQDN:

```bash
# Master FQDN looks like: master-0.<site>.<tenant>.tenant.<region>.volterra.us
# but the k8s DNS suffix is just <site>.<tenant>.tenant.local
sudo grep '^search' /etc/resolv.conf || cat /etc/vpm/fqdn

# Or pull it out of a running pod's resolv.conf — first run a probe pod in ves-system
# (which has Vega VN), then inspect:
POD=$(kubectl -n ves-system get pods -l app=argo -o name | head -1)
kubectl -n ves-system get $POD -o jsonpath='{.spec.dnsConfig}' 2>/dev/null
# Or use the search domain of any sandbox under /run/containers/storage:
sudo find /run/containers/storage -name resolv.conf -exec grep -h '^search' {} \; \
  | head -1 | tr ' ' '\n' | grep '\.svc\.' | head -1 | sed 's/^svc\.//'
```

For tenant `platform-svc-nbryikfr` / site `srikan-tf-test-0`, the suffix is:

```
srikan-tf-test-0.platform-svc-nbryikfr.tenant.local
```

Save it for later:

```bash
export XC_DNS_SUFFIX=srikan-tf-test-0.platform-svc-nbryikfr.tenant.local
```

### 5. Run the Helm install with overrides

Copy `values-override.yaml` from this bundle to master-0, then:

```bash
cd ~/eob/release-package-3.0.0-rc4
./install.sh --chart-version 3.0.0-rc4 --namespace operators -f /path/to/values-override.yaml
```

This sets:
- `kube-rbac-proxy` listen address `0.0.0.0:18443` (avoids `voucherd` on 8443)
- Operator default jetstream image to a tag ref (the chart default is a stale digest)

### 6. Apply the post-install patches

These are needed because the chart doesn't expose `hostNetwork` or `nodeSelector`, and the
operator generates child resources (Dashboard, StreamStore) with defaults that don't fit
this environment.

```bash
# Operator deployment
kubectl apply -f patches/01-operator-deploy.yaml

# Restart operator so the new env vars take effect AND child CRs get created with the right defaults
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=0
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=1

# Wait for operator to recreate child CRs
sleep 20

# Dashboard CR (disable oauth)
kubectl apply -f patches/02-dashboard-cr.yaml

# Dashboard Deployment (hostNetwork, master-0, IfNotPresent)
kubectl -n tawon-operator patch deploy tawon-dashboard --patch-file patches/03-dashboard-deploy-patch.yaml

# StreamStore CR (hostpath storage)
kubectl apply -f patches/04-streamstore-cr.yaml

# StreamStore StatefulSet — delete + re-patch (the operator regenerates the sts on CR change
# and our patches need to be reapplied each time, OR you can patch sts and just delete the pod)
kubectl -n tawon-operator patch sts tawon-streamstore --patch-file patches/05-streamstore-sts-patch.yaml

# Force re-create pod + PVC against new spec
kubectl -n tawon-operator delete pvc -l app=tawon-streamstore --wait=false
kubectl -n tawon-operator delete pod tawon-streamstore-0 --grace-period=0 --force --wait=false

# Fix the NATS image (chart default is a stale sha256 digest)
kubectl -n tawon-operator set image sts/tawon-streamstore \
  tawon-streamstore-d2f18e=quay.io/mantisnet/nats:2.10.4-alpine

# DNS workaround for Stream→NATS: the operator hardcodes *.cluster.local in the
# StreamReconciler. Wait for streamstore to come up, then add a hostAliases
# entry on the operator pod mapping the hardcoded FQDN to a stable IP.
#
# Use the streamstore Pod's hostIP, NOT the Service ClusterIP. The ClusterIP
# goes stale on chart re-install (operator hostAliases is never updated with the
# new value), and cross-node Service routing is broken on XC sites anyway.
# Since patches/05 pins the StatefulSet to master-0, the pod hostIP is stable.
kubectl -n tawon-operator wait --for=condition=Ready pod tawon-streamstore-0 --timeout=120s

NATS_IP=$(kubectl -n tawon-operator get pod tawon-streamstore-0 -o jsonpath='{.status.hostIP}')
echo "NATS endpoint (streamstore pod hostIP): $NATS_IP"

kubectl -n operators patch deploy tawon-operator-controller-manager --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{
        \"hostAliases\":[{
          \"ip\":\"${NATS_IP}\",
          \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",\"nats\"]
        }]
      }}}}"

# Same DNS workaround for the dashboard pod: it also runs on hostNetwork and defaults
# its NATS subscription to nats://nats:4222. Without hostAliases the UI shows zero
# streams even when streams are healthy in NATS. Mirror the operator patch.
kubectl -n tawon-operator patch deploy tawon-dashboard --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{
        \"hostAliases\":[{
          \"ip\":\"${NATS_IP}\",
          \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",\"nats\"]
        }]
      }}}}"

# Set KUBERNETES_CLUSTER_DOMAIN env var to the XC suffix (read by some operator
# code paths even though it doesn't help the Stream path — set it for correctness)
kubectl -n operators set env deploy/tawon-operator-controller-manager \
  -c manager KUBERNETES_CLUSTER_DOMAIN="${XC_DNS_SUFFIX}"

# Restart operator (scale 0/1 to avoid the rolling-update port-collision dance)
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=0
sleep 6
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=1
```

### 7. Verify

```bash
kubectl -n operators get pods
# Expect: tawon-operator-controller-manager-...   2/2 Running

kubectl -n tawon-operator get pods
# Expect:
#   tawon-dashboard-...            1/1 Running
#   tawon-streamstore-0            1/1 Running

# Sanity-check listeners on master-0
sudo ss -tlnp | grep -E ":8789|:4222|:18443"

# Stream must be READY=True before any ClusterDirective can deploy
kubectl -n tawon-operator get streamstores
kubectl -n tawon-operator get streams
# If the Stream stays READY=False, the hostAliases workaround above is missing/wrong.
# Tail the operator log and look for:
#   "Reconciler error","controller":"stream",...
#   "connect to the StreamStore: dial tcp: lookup ... .cluster.local ... no such host"
# That string == hostAliases not applied or wrong NATS_IP.

# If StreamStore stays "Ready=False / reason=Creating" forever AND its STS reports
# readyReplicas==1, the STS may be missing its ownerReferences back to the StreamStore
# CR (cause unclear — observed once during a patch/re-apply sequence in step 6). The
# streamstore controller will idempotently re-log "creating network policy" / "created
# Statefulset" on every reconcile pass without ever advancing Ready. Verify and fix:
#   kubectl -n tawon-operator get sts tawon-streamstore -o jsonpath='{.metadata.ownerReferences}'
# If empty, re-attach the ownerRef:
#   SS_UID=$(kubectl -n tawon-operator get streamstore tawon-streamstore -o jsonpath='{.metadata.uid}')
#   kubectl -n tawon-operator patch sts tawon-streamstore --type=merge -p \
#     "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"tawon.mantisnet.com/v1alpha1\",\"kind\":\"StreamStore\",\"name\":\"tawon-streamstore\",\"uid\":\"${SS_UID}\",\"controller\":true,\"blockOwnerDeletion\":true}]}}"
# Within ~seconds the StreamStore condition flips to Ready=True ("StatefulSet is ready").
```

### 8. Install the agent-pod mutating webhook (unblocks ClusterDirectives)

When you apply a `ClusterDirective`, the operator spawns an agent DaemonSet
in `tawon-operator`, one pod per node. The operator generates this DS without
`hostNetwork: true` and reverts external patches — so without an admission-time
intercept, the agent pods fail Vega VN allocation. The bundle ships a small
mutating webhook that injects `hostNetwork` + `hostAliases` for the NATS DNS
workaround + per-directive probe/metrics ports for multi-directive coexistence.
**See `webhook/README.md` for the full mutation list, ports, and tunables.**

```bash
cd eob-xc-install/webhook
./install.sh
```

This generates a self-signed TLS cert, installs `/usr/local/bin/eob-mutate.py`
+ `eob-mutate.service` on master-0, and applies a `MutatingWebhookConfiguration`
scoped to `namespace=tawon-operator` + label `app.kubernetes.io/name=tawon-directive`.

The webhook listens on `0.0.0.0:9443` on master-0. No firewall change is
required: `vpm-segment-inbound` only filters `vhost-seg+` interfaces (tenant
overlay), not the node IP on `vhost0`, and the AWS Security Group between
master EC2 instances permits arbitrary intra-cluster TCP.

> **v1 scaffolding.** The webhook currently runs as a single systemd unit on
> master-0 — the apiserver on every master successfully calls it via the node
> IP, but it's a single point of failure for admission. With the in-cluster
> registry now distributing images across all three nodes (see
> [Multi-node images](#multi-node-images--in-cluster-registry-cluster-infrastructure)),
> the natural next step is converting `eob-mutate` into a hostNetwork DaemonSet
> (or 3 sibling systemd units) so any node's apiserver can hit a local
> instance. Tracked in [Known issues / TODO](#known-issues--todo).

### 9. Apply a ClusterDirective (smoke test)

Once the Stream is `Ready: True` and the webhook is installed, apply a
ClusterDirective and watch the agent DS come up. Successful state:

```
$ kubectl get clusterdirectives
NAME          READY   NODES READY   NODES DESIRED
<your-name>   True    1             3                  # 1/3 = master-0 only; see below
```

**With the in-cluster registry in place** (see
[Multi-node images — in-cluster registry](#multi-node-images--in-cluster-registry-cluster-infrastructure)),
the agent DS will reach 3/3 — cri-o on master-1/2 pulls
`quay.io/mantisnet/tawon:v3.0.0-rc4-ubi` from `172.31.44.247:5000` automatically. If you
skipped the registry setup and only loaded on master-0, you'll see 1/3 — master-0's pod
reaches Running while the other two sit in `ImagePullBackOff` (no auth/connectivity to
quay.io from master-1/2).

**Multiple directives.** As long as the webhook is the version that does
per-directive port remap, you can apply more than one ClusterDirective and
have them all run on every node. Without the remap, only the first one
schedules; subsequent ones sit Pending with `FailedScheduling: didn't have
free ports for the requested pod ports` (every agent wants `:8081` and
`:9990`). To confirm the live webhook does the remap:

```bash
kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-directive \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].ports[*].hostPort}{"\n"}{end}'
# Per-directive pods should report ports in 18081-19080 / 19990-20989, NOT 8081/9990.
```

**Directives self-stop.** `spec.duration` (default `5m`) + `spec.stopAt` will
mark the directive `DirectiveStopped` and remove the agent DS at that time. For
a persistent install, omit both or set `duration: 8760h` (one year).

---

## Exposing the dashboard

The dashboard pod runs with `hostNetwork`, so `sengat` is listening on `master-0:8789`
directly. Reaching it from a browser depends entirely on the AWS Security Group attached
to master-0's EC2 instance — the on-node `vpm-segment-inbound` chain only filters
`vhost-seg+` (Vega tenant overlay) traffic, not packets arriving on the public/private
NIC interface that hosts the node IP.

### Canonical path: AWS SG change

Treat the dashboard as a site-infrastructure UI like any other operator console (Prometheus,
Grafana, etc.). Ask the XC tenant admin to open inbound TCP **8789** (and optionally
**18443** for operator metrics, **8222** for NATS UI) in the AWS security group attached
to the master EC2 instances. Source = your client CIDR (or `0.0.0.0/0` if access is gated
elsewhere).

No vpm/iptables change is required — the firewall-request template in
`admin-firewall-request.md` is scoped accordingly.

### Lab/debug path: SSH local port-forward

Useful before the SG change is in place, or for one-off debugging from a workstation:

```bash
ssh -i ~/.ssh/id_ed25519_xc \
  -L 8789:127.0.0.1:8789 \
  -L 18443:127.0.0.1:18443 \
  -L 8222:127.0.0.1:8222 \
  xcuser@3.147.217.91 -N
```

Then browse to `http://localhost:8789`.

| Local URL | What it is |
|---|---|
| `http://localhost:8789` | Tawon Dashboard (sengat UI) |
| `https://localhost:18443/metrics` | Operator Prometheus metrics |
| `http://localhost:8222` | NATS monitoring page |

---

## Site integration reference (one-line each)

Each line is a property of the F5 XC CE platform that we integrate with — they're the
design contract for any infrastructure running at this layer, not things to "work around."
Distinct from upstream Mantis bugs (separate list below).

### XC platform integration points
- **Pod networking via hostNetwork.** Vega CNI allocates pod-network sandboxes only for namespaces backed by a Virtual Network (cloud-pushed by `vegacfgd`). Site-infrastructure components (ves-system, EoB) run `hostNetwork: true` and bypass Vega entirely.
- **`voucher` mutating webhook signs tenant pods** with `ves.io/pod-id`+`ves.io/mutation-hmac`; site-infrastructure namespaces label `disablePikuWebhook=true` to skip it. The EoB chart inherits that pattern via the `tawon-operator` namespace.
- **vpm-managed iptables.** `vpm-segment-inbound` chain matches `-i vhost-seg+` only — Vega's tenant overlay, not the node IP on `vhost0`. Master-master traffic and host-side services bound to the node IP are not gated; the AWS Security Group is.
- **vpm reconciles `/etc/vpm/`, parts of `/etc/containers/`, iptables.** `registries.conf.d/` has been untouched for the lifetime of this site, but no formal guarantee — keep an eye on the `099-eob-mirror.conf` mtime over time.
- **Rootless podman ≠ rootful cri-o storage.** Always `sudo ./load.sh` so the loaded images land where cri-o reads them.
- **Quay egress.** The docker daemon proxy 503s for `quay.io`; site-installed `podman` reaches quay directly with `~/.config/containers/auth.json`. Once images are mirrored on master-0:5000, this only matters when pulling new upstream releases.
- **Cluster DNS suffix is `<site>.<tenant>.tenant.local`**, not `cluster.local`. Discover with `cat /etc/vpm/fqdn` or `grep ^search /etc/resolv.conf`.
- **Storage classes.** AWS-EBS-backed `standard` doesn't provision PVs for non-tenant namespaces. Site-infrastructure stateful workloads use `hostpath` (host-local), pinning the StatefulSet to wherever the PV is created.
- **Master-0 hosts cluster-local services** (image registry, eob-mutate webhook today). Master IPs: `172.31.44.247` (master-0), `172.31.39.17` (master-1), `172.31.33.234` (master-2).

### Upstream Mantis (rc4) bugs at install time
Two are handled silently by this bundle and don't need action; the rest are
documented in [Known issues / TODO](#known-issues--todo) with their workarounds.

- **DirectiveBinding CRD** — rc4 ships with the matching CRD set, so no extra `kubectl apply` from the operator bundle is needed. (rc6-only problem.)
- **NATS image pinned by stale sha256 digest** in `tawon-operator-3.0.0-rc4.tgz` `values.yaml` — overridden via `TAWON_OPERATOR_DEFAULT_JETSTREAM_IMAGE` env in `values-override.yaml`.

For the rest (StreamReconciler + dashboard pktsapi `.cluster.local` hardcodes,
agent hostNetwork knob missing, agent probe/metrics ports not configurable,
dashboard duplicate port name, Dashboard CR nodeSelector ignored, StatefulSet
PVC template mutability), see the punch list below.

---

## Multi-node images — in-cluster registry (cluster infrastructure)

Treat the mantisnet image set as **cluster-local infrastructure**, not as something to
re-pull from quay.io on every node. `master-0` hosts a `registry:2` container on the host
network at `:5000`, all 8 rc4 images are pushed to it, and every node's cri-o has a mirror
config that resolves `quay.io/mantisnet/*` → `172.31.44.247:5000/mantisnet/*`. From the
chart's point of view nothing changes — image refs in manifests stay as `quay.io/mantisnet/…`,
but pulls land on master-0 over the VPC instead of going off-site.

### Standing it up

On **master-0** (as `xcuser`, with sudo):

1. Write a quadlet for the registry so it survives reboots:

   ```bash
   sudo tee /etc/containers/systemd/eob-registry.container >/dev/null <<'EOF'
   [Unit]
   Description=EoB image registry (master-0)
   After=network-online.target
   Wants=network-online.target

   [Container]
   Image=docker.io/library/registry:2
   ContainerName=eob-registry
   Network=host
   Volume=/var/lib/eob-registry/data:/var/lib/registry:Z
   Environment=REGISTRY_HTTP_ADDR=0.0.0.0:5000

   [Service]
   Restart=always
   TimeoutStartSec=120

   [Install]
   WantedBy=multi-user.target default.target
   EOF

   sudo mkdir -p /var/lib/eob-registry/data
   sudo systemctl daemon-reload
   sudo systemctl start eob-registry.service
   curl -sS -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5000/v2/   # expect 200
   ```

2. Tag and push the 8 rc4 images already loaded in rootful podman storage:

   ```bash
   REG=172.31.44.247:5000
   for IMG in \
       tawon:v3.0.0-rc4-ubi \
       tawon-operator:v3.0.0-rc4 \
       tawon-operator-bundle:v3.0.0-rc4 \
       tawonctl:v3.0.0-rc4 \
       sengat:v3.0.0-rc4 \
       diagnose:v3.0.0-rc4 \
       nats:2.10.4-alpine \
       kube-rbac-proxy:v0.13.0 ; do
     sudo podman tag "quay.io/mantisnet/${IMG}" "${REG}/mantisnet/${IMG}"
     sudo podman push --tls-verify=false "${REG}/mantisnet/${IMG}"
   done
   curl -sS http://127.0.0.1:5000/v2/_catalog
   ```

3. Land the mirror config on **every** node (`master-0`, `master-1`, `master-2`):

   ```toml
   # /etc/containers/registries.conf.d/099-eob-mirror.conf
   [[registry]]
   prefix = "quay.io/mantisnet"
   location = "quay.io/mantisnet"

   [[registry.mirror]]
   location = "172.31.44.247:5000/mantisnet"
   insecure = true
   ```

   On master-0, write it directly + `sudo systemctl restart crio`.

   On master-1/master-2 — no SSH (each node has independent `authorized_keys`). Land via
   a privileged Pod scheduled with `nodeName: master-N`, which chroots into the host's `/`
   and runs the write + `systemctl restart crio`. Template in
   `eob-xc-install/node-fix-pod.yaml.template`; render with `sed s/NODENAME/master-1/g`
   and `kubectl apply`. The template uses `gcr.download.volterra.us/volterraio/coredns@sha256:ae15f69b…`
   (already cached on every node) so it never has to pull through Vega.

### Validating

Registry logs are the source of truth — `sudo journalctl -u eob-registry.service` should
show `GET /v2/mantisnet/…/blobs/…` from each node's internal IP after a pull:

| node | IP |
|---|---|
| master-0 | `172.31.44.247` |
| master-1 | `172.31.39.17` |
| master-2 | `172.31.33.234` |

A fresh `crictl pull quay.io/mantisnet/tawon-operator:v3.0.0-rc4` from a Pod scheduled on
master-1 should land in the cache without going to quay.io.

### Why this is "infrastructure" not a workaround

- The registry is the single source of truth for `mantisnet/*` images on this site. Manifests
  keep their `quay.io/mantisnet/*` refs — mirror config is invisible to workloads.
- Quay credentials are no longer required on master-1/master-2 (only master-0, to pull new
  upstream images into the registry).
- The operator nodeSelector pinning everything to master-0 (`patches/01-operator-deploy.yaml`)
  exists only because of the historical "images only on master-0" constraint. With the
  mirror live, this pin can be dropped — operator/dashboard/streamstore can run on any node.
- Same applies to the eob-mutate webhook: today a single-pointed systemd unit on master-0;
  with images everywhere, it can become a DaemonSet (or 3 systemd units) for HA.

### Caveats

- `/etc/containers/registries.conf.d/` has been untouched by vpm for the lifetime of this
  site (`mtime` matches the original cloud-init), so the mirror conf is likely safe from
  reconciliation. If vpm starts clobbering it, add a tiny systemd watchdog that restores
  the file, or push the conf into whatever path XC's node provisioning blesses for
  tenant-bespoke configuration (an open question for the XC team).
- The registry runs HTTP only; cri-o uses `insecure = true` in the mirror block. Fine for
  intra-VPC traffic on the cluster's private network. Don't expose `:5000` to the AWS SG.
- Storage is on master-0's `/var` (`/var/lib/eob-registry/data`). 31 GB free at install
  time; rc4 image set is ~3.5 GB total. Plenty of headroom.

---

## Uninstall

```bash
# Delete child resources first so finalizers process
kubectl -n tawon-operator delete dashboards,streamstores,directives,clusterdirectives --all --wait=false

# Uninstall helm release
helm uninstall tawon-operator -n operators

# CRDs (cluster-scoped, helm won't touch them on uninstall)
kubectl delete crd clusterdirectives.tawon.mantisnet.com directives.tawon.mantisnet.com \
  dashboards.tawon.mantisnet.com streams.tawon.mantisnet.com streamstores.tawon.mantisnet.com \
  topologyaggregators.tawon.mantisnet.com

# Namespaces
kubectl delete ns operators tawon-operator
```

---

## Known issues / TODO

For broader production-readiness recommendations (HA, observability,
operational concerns, upstream asks), see `HOSTING.md` alongside this file.
This section tracks the discrete punch list.

### Site-infrastructure follow-ups (within our scope)
- [x] ~~**Multi-node images.**~~ — solved via the in-cluster `registry:2` on master-0 +
      `registries.conf.d/099-eob-mirror.conf` on all nodes. Follow-ups below.
- [x] ~~**Dashboard packet viewer broken with `.cluster.local` lookup failure.**~~
      Same root cause as the operator's StreamReconciler bug — the dashboard's
      pktsapi (JetStream consumer path) also hardcodes the streamstore FQDN.
      Fixed in step 6 with a second `hostAliases` patch on the dashboard Deployment.
- [x] ~~**Multi-directive coexistence impossible on hostNetwork.**~~ — fixed in
      `webhook/server.py` by per-directive probe/metrics port remap at admission
      time. Probe ∈ `18081..19080`, metrics ∈ `19990..20989`, deterministic per
      DaemonSet name. Verified two ClusterDirectives running concurrently on all
      3 nodes.
- [ ] **Drop the `nodeSelector: kubernetes.io/hostname: master-0`** from
      `patches/01-operator-deploy.yaml` and `patches/03-dashboard-deploy-patch.yaml`.
      Those pins existed only because images were master-0-only; with the registry mirror
      live, operator/dashboard/streamstore can run on any node. The streamstore stays pinned
      via its `hostpath` PV.
- [ ] **Convert `eob-mutate` into a hostNetwork DaemonSet (or 3 sibling systemd units).**
      Currently runs as a single systemd unit on master-0; that's a single point of failure
      for admission with `failurePolicy: Fail` (correct setting — but means master-0 down
      = no new agent pods cluster-wide). With images now distributed, the DS can pull on
      every node. Cert/CA handling stays the same (self-signed CA bundled in
      `MutatingWebhookConfiguration`). Highest-impact remaining item — see HOSTING.md §1.
- [ ] **Webhook health probe consumer.** `server.py` exposes `GET /healthz` but
      nothing reads it. Add a node-level systemd timer or kubelet probe so we get
      paged before the next admission call discovers the webhook is wedged.
      See HOSTING.md §2.
- [ ] **Registry config-source audit for vpm reconciliation.**
      Confirm `/etc/containers/registries.conf.d/099-eob-mirror.conf` survives across a
      reboot and any vpm reconcile cycle. If vpm reverts it, add a tiny systemd watchdog
      that restores the file from `/etc/eob/` (or wherever XC's blessed tenant-config path
      lives — open question for the XC team). See HOSTING.md §4.
- [ ] **Registry durability/HA.** Single `registry:2` on master-0; loss of master-0
      disk = no node can pull `mantisnet/*`. Either make it HA or make it cheap to
      rebuild from the release tarball via a 24h skopeo sync timer. See HOSTING.md §3.
- [ ] **StreamStore data durability.** Single-replica NATS JetStream on a hostpath
      PV on master-0. Decide whether captured/payload streams need to survive
      master-0 reboots; if so, NATS JS clustering across all three masters is the
      path. See HOSTING.md §5.

### Site-platform follow-ups (require XC team)
- [ ] **`vpm-segment-allowSsh/Dns/Webui` toggles in `/etc/vpm/config.yaml`** look related
      to allow-port management on the `vhost-seg+` (tenant-overlay) side. They aren't
      relevant for master-master traffic or browser-to-node-IP traffic — the AWS SG
      is the only gate there. See `admin-firewall-request.md` for the dashboard exposure ask.
- [ ] **Blessed path for tenant-bespoke node configuration.**
      We assume `registries.conf.d/` is durable based on mtime evidence. If XC has a
      sanctioned mechanism for site-installed config files (so they survive vpm reconcile
      with a documented contract), use that instead.
- [ ] **Vega VN provisioning for the `tawon-operator` namespace.** The deepest fix.
      If XC adds a tenant-provisioning path for operator-installed namespaces, we can
      drop hostNetwork on the EoB control plane entirely and retire the webhook's
      hostNetwork mutation. Long-running ask; doesn't block items above. See HOSTING.md §8.

### Upstream Mantis (rc4) bugs to track
- [x] ~~**Agent DaemonSet cannot run.**~~ — addressed at the site infrastructure layer
      by the `eob-mutate` admission webhook. The operator generates the DS *without*
      `hostNetwork: true` and reverts external `kubectl patch` attempts. The webhook
      intercepts pod creates with label `app.kubernetes.io/name=tawon-directive` and
      injects `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, and the
      `hostAliases` entry for `nats`. The mutation happens before spec persists, so
      the operator never reconciles it back. **Upstream fix:** Mantis adds a
      hostNetwork knob to the agent DS template; then the webhook can be removed
      (`webhook/uninstall.sh`).
- [ ] **`KUBERNETES_CLUSTER_DOMAIN` env not honored in StreamReconciler.**
      Set elsewhere, ignored on the Stream→NATS path which hardcodes `.cluster.local`.
      Workaround: hostAliases patch in step 6.
- [ ] **Dashboard pktsapi hardcodes `.cluster.local`** for the JetStream consumer URL —
      same root cause as the StreamReconciler bug, separate code path on the dashboard
      pod. Workaround: second hostAliases patch on the dashboard Deployment (step 6).
- [ ] **Agent probe + metrics ports not configurable via the chart or ClusterDirective spec.**
      The binary supports `--probes.addr` / `--metrics.addr` (env `TAWON_PROBES_ADDR` /
      `TAWON_METRICS_ADDR`), but neither is reachable from the spec. With every agent
      DS on hostNetwork, this forces our per-directive port-remap workaround in the
      webhook. **Upstream fix:** add `agent.probesAddr` / `agent.metricsAddr` ClusterDirective
      spec fields; then the webhook can stop allocating ports.
- [ ] **Dashboard service generation emits duplicate port name** when `oauth.enabled: false`.
      Logged as `Service "tawon-dashboard" is invalid: spec.ports[1].name: Duplicate value: "app"`.
      Doesn't block the dashboard pod from running, but the Dashboard CR stays Ready=False.
- [ ] **`spec.pod.nodeSelector` on the Dashboard CR doesn't propagate** to the
      auto-generated Deployment. Patch the Deployment directly instead.
- [ ] **PVCs from a StatefulSet volumeClaimTemplate aren't updated on template change.**
      Captured in `04-streamstore-cr.yaml` + the PVC delete in step 6.
