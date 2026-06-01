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

## Phase 2 — eob-mutate webhook (port remap)

This is the **existing Python webhook** in `webhook/`. It handles
per-directive port remapping (agent probes/metrics) so concurrent
ClusterDirectives don't collide on the same hostPort. It is NOT the
same thing as `tawon-pod-injector` (Phase 4 below).

```bash
cd ~/eob-xc-install/webhook
./install.sh
```

**Gate:**

```bash
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep eob-mutate
# expect 1 MutatingWebhookConfiguration named eob-mutate
```

---

## Phase 3 — Repair operator + dashboard hostAliases

⚠️ **The IP that `install.sh` baked into operator + dashboard hostAliases
(the streamstore Service ClusterIP) goes stale the moment the Service
is recreated.** This is the largest single source of brittleness on
this site. If you ever see the operator log
`dial tcp <some-IP>:4222: i/o timeout` or the dashboard packet viewer
error "load nats jetstream stream: create consumer: context deadline
exceeded", this is what's wrong.

**Fix:** point hostAliases at the streamstore Pod's host IP (stable as
long as the pod stays pinned to master-0 per patches/05), bypassing the
Service entirely. Cross-node Service routing is also broken on this
site, so the host-IP path is more reliable anyway.

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
```

---

## Phase 4 — `tawon-pod-injector` (admission webhook)

This is the **new** Go webhook that injects `hostNetwork: true` and
operator-stale hostAliases corrections onto Tawon-spawned pods at pod
admission. Lives in a sibling repo (`mimetrix/tawon-pod-injector`).

Why it's separate from Phase 2's `eob-mutate`: that one handles port
remapping (a single operator concern); this one handles network mode
+ DNS overrides (XC-CNI concerns). They could be merged but live
separately today.

```bash
# 1. Build + push the image
cd ~/tawon-pod-injector
podman build -t 172.31.44.247:5000/mantisnet/tawon-pod-injector:dev .
podman push --tls-verify=false 172.31.44.247:5000/mantisnet/tawon-pod-injector:dev

# 2. Generate cert + render manifest
./deploy/certs/gen.sh > /tmp/certs.env
. /tmp/certs.env
python3 -c "
import os
with open('deploy/k8s/manifest.template.yaml') as f: t = f.read()
for v in ['TLS_CRT','TLS_KEY','CA_BUNDLE']:
    t = t.replace('\${'+v+'}', os.environ[v])
print(t)
" > /tmp/tawon-pod-injector.yaml

# 3. Apply
kubectl apply -f /tmp/tawon-pod-injector.yaml
```

**Gate:**

```bash
kubectl -n tawon-operator get pod -l app.kubernetes.io/name=tawon-pod-injector
# expect 1 pod 1/1 Running

kubectl -n tawon-operator logs -l app.kubernetes.io/name=tawon-pod-injector
# expect: "HTTPS listener starting" — no errors
```

⚠️ The webhook hardcodes `StreamStoreHostIP` in
`internal/inject/inject.go`. If streamstore ever moves to a different
master, this constant has to be updated and the image rebuilt. Phase 6
(hardening) covers making this dynamic.

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
# If ContainerCreating with Vega CNI error → Phase 4 (webhook) not working.

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

Agent pods need the same hostAliases the operator has. If you see this
after Phase 4 (webhook is deployed), the webhook isn't catching agent
admissions — check:

```bash
kubectl -n tawon-operator get mutatingwebhookconfiguration tawon-pod-injector
# expect 1 entry with matching namespaceSelector + objectSelector

kubectl -n tawon-operator logs -l app.kubernetes.io/name=tawon-pod-injector
# expect "patched pod" entries for each admitted Tawon pod
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

- **TLS for eob-mcp + tawon-pod-injector in production.** Both
  components support TLS (flag-gated for eob-mcp, mandatory for the
  webhook), but cert provisioning is left to the operator. cert-manager
  is the recommended path; this runbook doesn't cover its setup.

- **Multi-site / fleet.** Each XC site runs an independent stack with
  its own eob-mcp + tawon-pod-injector. The aggregator that fans out
  across sites is a separate project (see eob-mcp `docs/ARCHITECTURE.md`).

- **Upstream fixes.** The brittleness this runbook works around comes
  from upstream gaps:
    - Tawon CRDs don't expose `hostNetwork` / `hostAliases` fields
    - Operator hardcodes `cluster.local`
    - Operator hostAliases IP is install-time, not reconciled
  These should be tickets against Mantis, not workarounds maintained
  forever. Until then, this runbook is the operational reality.
