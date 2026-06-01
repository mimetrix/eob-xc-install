# EoB on F5 XC — install + bring-up runbook

This is the **step-by-step operator-facing** procedure to take a fresh
F5 XC CE site to a working Mantis EoB stack with packet capture flowing
end-to-end. It's the executable companion to `README.md` (which
explains *why* every step is there).

If you only want to read one document, read this. If you hit something
the runbook doesn't explain, fall through to README.

**Tested against:** site `srikan-tf-test-0` on 2026-06-01 with
`tawon-operator-3.0.0-rc4`, k8s `v1.34.2-ves`, kernel
`5.14.0-611.47.1.el9_7.x86_64`.

> ⚠️ Order matters. Several steps create state that subsequent steps
> mutate. Skipping a verification gate ("expect X before continuing")
> is the #1 way this ends in 4 hours of debugging.

---

## Phase 0 — Prerequisites

### 0.1 Cluster shape

```bash
kubectl get nodes -o wide
# expect: 3 nodes, all Ready, role ves-master, k8s 1.34.x
```

### 0.2 Network access

```bash
# Quay reachability from master-0 (release-package images are pulled here)
ssh xcuser@<site-public-ip> "podman login quay.io -u mantisnet+lmt -p <robot-token>"
# (per memory: project_eob_package.md — robot account needs Read perm on
# mantisnet/eob-package granted in quay UI before first pull)
```

### 0.3 In-cluster image registry

A `registry:2` quadlet must be running on master-0 at
`172.31.44.247:5000` (per memory: `project_eob_inclusterregistry.md`),
and all 3 nodes must have `registries.conf.d` mirroring
`quay.io/mantisnet/*` to it. Verify:

```bash
ssh xcuser@<site> "curl -s http://172.31.44.247:5000/v2/_catalog"
# expect: {"repositories":[...]} non-empty
```

### 0.4 Storage

```bash
kubectl get sc
# Verify `hostpath` exists (kubernetes.io/host-path provisioner) AND is the cluster default.
# If `standard` (aws-ebs) is the default, the streamstore PVC will hang forever — k8s 1.27+
# removed the in-tree AWS provisioner. Fix:
kubectl patch sc standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch sc hostpath -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
# Verify:
kubectl get sc | grep '(default)'
# Expect:   hostpath  ...  (default)
```

**Gate:** `kubectl get sc` shows exactly one `(default)` and it's `hostpath`.

### 0.5 Node labels

The Tawon agent DaemonSet has nodeAffinity requiring
`node-role.kubernetes.io/master` or `node-role.kubernetes.io/worker`.
XC nodes only carry `kubernetes.io/role=ves-master` by default —
without the canonical label, agent pods never schedule.

```bash
for n in master-0 master-1 master-2; do
  kubectl label node "$n" node-role.kubernetes.io/master= --overwrite
done
# Verify:
kubectl get nodes -L node-role.kubernetes.io/master
# expect column populated for all 3
```

**Gate:** all masters carry the label.

---

## Phase 1 — install.sh

```bash
ssh xcuser@<site>
cd ~/eob-xc-install
./install.sh
```

`install.sh` does everything documented in README §1–10:

- Loads release-package images into rootful podman
- `helm install` with `values-override.yaml`
- Applies `patches/01-operator-deploy.yaml` (hostNetwork, ports, master-0 pin)
- Scale-restarts operator
- Patches Dashboard CR + Deployment
- Patches StreamStore CR + StatefulSet
- Forces a fresh PVC under `hostpath`
- **Sets operator + dashboard hostAliases to the streamstore Service ClusterIP** (this becomes stale; see Phase 3)
- Detects + sets `KUBERNETES_CLUSTER_DOMAIN` env

**Gates after install.sh:**

```bash
kubectl -n operators get pods    # operator 2/2 Running
kubectl -n tawon-operator get pods
# expect:
#   tawon-dashboard-*         1/1  Running   (on master-0)
#   tawon-streamstore-0       1/1  Running   (on master-0)

kubectl -n tawon-operator get streams
# (empty until a ClusterDirective is applied)
```

If streamstore is **0/1 ContainerCreating** with
`MountVolume.SetUp failed for volume "data": failed to provision volume`
→ Phase 0.4 was missed. Fix the StorageClass default and run:

```bash
kubectl -n tawon-operator delete pvc -l app=tawon-streamstore --wait=false
kubectl -n tawon-operator delete pod tawon-streamstore-0 --grace-period=0 --force
# StatefulSet recreates pod with a new PVC under the new default
```

---

## Phase 2 — eob-mutate webhook (one webhook, three concerns)

The Python webhook in `webhook/` is the single admission-time mutation
point for every Tawon-spawned pod. It does three things at once:

1. **hostNetwork bypass** — sets `hostNetwork: true` +
   `dnsPolicy: ClusterFirstWithHostNet` so the pod skips Vega CNI.
2. **NATS DNS workaround** — adds a `hostAliases` entry mapping the
   streamstore FQDN + the short name `nats` to a reachable IP.
3. **Per-directive port remap** — gives each agent DaemonSet unique
   probe + metrics hostPorts so multiple ClusterDirectives can coexist
   on the same hostNetwork node.

Runs as a **systemd service on master-0** (not as a k8s pod, to avoid
the chicken-and-egg of needing a pod that itself can't get
networking).

```bash
cd ~/eob-xc-install/webhook
./install.sh
```

The installer reads the streamstore Pod's hostIP at install time and
bakes it into the webhook's `NATS_IP` env (`/etc/eob-mutate/env`).
That value is the only piece of state that goes stale — see Phase 3
for when + how to refresh it.

**Gate:**

```bash
kubectl get mutatingwebhookconfiguration eob-mutate
sudo systemctl is-active eob-mutate.service
# expect: 1 MutatingWebhookConfiguration named eob-mutate; service "active"
```

---

## Phase 3 — Refresh stale hostAliases IPs

Three places carry a cached IP for the streamstore endpoint:

1. **Operator pod's `hostAliases`** (set by `install.sh`)
2. **Dashboard pod's `hostAliases`** (set by `install.sh`)
3. **eob-mutate's `NATS_IP` env** (set by `webhook/install.sh`, used to
   stamp the same hostAliases entry into agent pods at admission)

Latest install.sh + webhook/install.sh both use the streamstore **Pod's
hostIP** (stable as long as the StatefulSet stays pinned to master-0
per `patches/05-streamstore-sts-patch.yaml`), so a fresh install gets
this right. But if anything restarts the streamstore on a different
node OR a chart re-install creates a new Service, all three need to
be refreshed.

Symptoms when one of these is wrong:

| What you see | Which IP is stale |
|---|---|
| Operator log: `dial tcp <ip>:4222: i/o timeout` | operator hostAliases |
| Dashboard UI: "load nats jetstream stream: create consumer: context deadline exceeded" | dashboard hostAliases |
| Agent pod log: `publish payload: not connected` | eob-mutate NATS_IP |

**Fix all three at once:**

```bash
STREAMSTORE_HOST=$(kubectl -n tawon-operator get pod tawon-streamstore-0 \
  -o jsonpath='{.status.hostIP}')
echo "$STREAMSTORE_HOST"

# Operator
kubectl -n operators patch deploy tawon-operator-controller-manager --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",
        \"value\":[{\"ip\":\"$STREAMSTORE_HOST\",
                    \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",\"nats\"]}]}]"

# Dashboard
kubectl -n tawon-operator patch deploy tawon-dashboard --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/hostAliases\",
        \"value\":[{\"ip\":\"$STREAMSTORE_HOST\",
                    \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",
                                   \"tawon-streamstore-d2f18e.tawon-operator.svc\",
                                   \"tawon-streamstore-d2f18e\",
                                   \"nats\"]}]}]"

# Refresh eob-mutate's NATS_IP env (used for AGENT pod hostAliases stamp)
sudo sed -i.bak "s|^NATS_IP=.*|NATS_IP=$STREAMSTORE_HOST|" /etc/eob-mutate/env
sudo systemctl restart eob-mutate.service

# Roll both deployments (scale 0/1 to clear hostPort collision)
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=0
kubectl -n tawon-operator scale deploy tawon-dashboard --replicas=0
sleep 6
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=1
kubectl -n tawon-operator scale deploy tawon-dashboard --replicas=1
```

**Gate:**

```bash
sleep 30
kubectl -n operators get pod -l app.kubernetes.io/name=tawon-operator \
  -o jsonpath='{.items[0].spec.hostAliases[0].ip}{"\n"}'
# expect: <STREAMSTORE_HOST value>

sudo systemctl status eob-mutate.service --no-pager | head -3
# expect: active (running) since <very recently>

# When new agent pods get admitted, eob-mutate should now stamp the
# correct IP into their hostAliases — verify by re-applying any
# ClusterDirective and checking one of its DS pods.
```

---

## Phase 5 — First ClusterDirective (smoke test)

This proves end-to-end capture works. Adjust `condition` to match a
process actually present on your nodes.

```bash
kubectl apply -f - <<EOF
apiVersion: tawon.mantisnet.com/v1alpha1
kind: ClusterDirective
metadata:
  name: capture-coredns-udp53
spec:
  duration: 30m
  condition:
    equal:
      field: process.name
      value: coredns
  kernelHeaders:
    strategy: Host          # ← critical: avoids pulling kernel-headers image from quay
  streams:
    - name: coredns-udp53
      maxage: 1h0m0s
      maxmsgs: 100000
      retentionPolicy: Delete
  tasks:
    - task: capture
      config:
        filter: "udp port 53"
    - task: publish
      config:
        name: coredns-udp53
        type: stream
EOF
```

**Gate cascade (each must pass before continuing):**

```bash
# 1. Stream becomes Ready (operator can reach streamstore)
kubectl -n tawon-operator get stream coredns-udp53 \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# expect: True (within ~30s)
# If False with "Unable to connect to the StreamStore" → re-check Phase 3.

# 2. DaemonSet exists with desired=3
kubectl -n tawon-operator get ds tawon-directive-capture-coredns-udp53
# expect: DESIRED=3, READY=3 (within 30-60s)
# If DESIRED=0 → Phase 0.5 (node label) was missed.

# 3. Agent pods Running
kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-directive
# expect: 3 pods 1/1 Running
# If Init:ErrImagePull → kernelHeaders.strategy wasn't "Host".
# If ContainerCreating with Vega CNI error → Phase 2 (eob-mutate webhook) not firing.

# 4. Stream messages accumulating
kubectl -n tawon-operator get stream coredns-udp53
# MSGS column should be growing
```

If you have an MCP client connected to eob-mcp, the same check via:

```bash
grpcurl -plaintext localhost:19443 \
  -d '{"name":"coredns-udp53-tawon-operator"}' \
  eob.v1.EoBService/StreamStats
```

---

## Phase 6 — Dashboard access (tunnel from your workstation)

The dashboard binds to `:8789` on master-0's host interface
(hostNetwork). Cross-node Service routing is broken (Phase 3 covers
why); use the host IP path directly.

If you've deployed the `xc-tunnels.sh` + launchd unit from
[`eob-mcp/scripts/dev/`](../eob-mcp/scripts/dev/README.md), you already
have:

```
localhost:8789  →  master-0:8789  (dashboard)
localhost:18443 →  Service:8443   (eob-mcp HTTP/MCP)
localhost:19443 →  Service:9443   (eob-mcp gRPC)
```

Otherwise, ad-hoc:

```bash
ssh -i ~/.ssh/id_ed25519_xc -N -L 8789:172.31.44.247:8789 xcuser@<site> &
```

Then `http://localhost:8789` — the packet viewer should load and the
captured DNS stream should be visible in the UI's stream picker.

---

## Failure modes + recovery

### Streamstore stuck Pending

Either Phase 0.4 (default SC) or Phase 1 (the install.sh PVC recycle)
was skipped or didn't take. Recovery:

```bash
kubectl -n tawon-operator delete pod tawon-streamstore-0 --wait=false
kubectl -n tawon-operator delete pvc -l app=tawon-streamstore --wait=false
# StatefulSet recreates both; the new PVC binds under the (correct) default SC
```

### Operator stuck "Unable to connect to the StreamStore"

Phase 3 hostAliases is wrong (most common: it's still pointing at the
install-time Service ClusterIP after the Service was recreated). Re-do
Phase 3.

### Agent pods CrashLoopBackOff with "publish payload: not connected"

Agent pods need a `hostAliases` entry stamped by eob-mutate that
points at the current streamstore Pod hostIP. Symptoms means either
the webhook isn't firing, OR it has the wrong cached IP. Check:

```bash
kubectl get mutatingwebhookconfiguration eob-mutate
# expect 1 entry; verify the caBundle and clientConfig URL still point at master-0:9443

sudo journalctl -u eob-mutate.service --since "5 min ago" | tail -10
# expect: "POST /mutate?timeout=5s HTTP/1.1" 200 lines for each new agent pod admitted

sudo cat /etc/eob-mutate/env
# expect: NATS_IP=<current streamstore Pod hostIP>
# If this is stale → fix per Phase 3 (sed + systemctl restart eob-mutate)
```

### Dashboard "create consumer: context deadline exceeded"

Dashboard's hostAliases is stale (same root cause as the operator
flavor). Re-do Phase 3, dashboard section.

### Everything was working yesterday, now it's broken

The most likely cause is: something restarted and the operator's
hostAliases is still the install-time Service ClusterIP, which has
since changed. Run:

```bash
# What hostAliases does the operator currently have?
kubectl -n operators get pod -l app.kubernetes.io/name=tawon-operator \
  -o jsonpath='{.items[0].spec.hostAliases}{"\n"}'

# What's the actual streamstore pod host IP today?
kubectl -n tawon-operator get pod tawon-streamstore-0 \
  -o jsonpath='hostIP={.status.hostIP}{"\n"}'

# If those don't match, Phase 3 is the fix.
```

---

## What's NOT in this runbook (deliberately)

- **CI / automated reproduction.** Today this is a manual procedure.
  Phase 6 of the project roadmap is wrapping these steps in an
  installer that watches state and re-asserts invariants. Not done.

- **TLS for eob-mcp + eob-mutate in production.** Both
  components support TLS (flag-gated for eob-mcp, mandatory for the
  webhook), but cert provisioning is left to the operator. cert-manager
  is the recommended path; this runbook doesn't cover its setup.
  eob-mutate currently uses a self-signed cert generated by
  `webhook/install.sh` with a 10y lifetime — fine for dev sites, swap
  for cert-manager in any environment that does real cert rotation.

- **Multi-site / fleet.** Each XC site runs an independent stack
  with its own eob-mcp + eob-mutate. The aggregator that fans out
  across sites is a separate project (see eob-mcp `docs/ARCHITECTURE.md`).

- **Upstream fixes.** The brittleness this runbook works around comes
  from upstream gaps:
    - Tawon CRDs don't expose `hostNetwork` / `hostAliases` fields
    - Operator hardcodes `cluster.local`
    - Operator hostAliases IP is install-time, not reconciled
  These should be tickets against Mantis, not workarounds maintained
  forever. Until then, this runbook is the operational reality.
