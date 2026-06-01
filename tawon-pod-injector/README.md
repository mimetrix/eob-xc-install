# tawon-pod-injector

A tiny mutating admission webhook that injects `hostNetwork: true` and
`dnsPolicy: ClusterFirstWithHostNet` into Tawon-managed pods on F5 XC
Customer Edge sites.

## Why

On XC CE sites the Vega CNI rejects pods in the `tawon-operator`
namespace with `Error in getting VN for namespace`. Tawon's CRDs
(`StreamStore`, `Dashboard`, `ClusterDirective`) do **not** expose a
`hostNetwork` field, so the operator-rendered StatefulSets and
DaemonSets always get the default (`hostNetwork: false`), and pods
fail sandbox creation forever.

External `kubectl patch` on the StatefulSet/DaemonSet works briefly
but gets reverted by the operator's reconcile loop on its next
startup. The only reliable bypass is a mutating webhook that adds the
field at pod admission — operator reconciles can't undo what's not in
the StatefulSet spec at all.

This is the option memory `project_eob_agent_ds_unpatchable.md` (#3)
recommends, structurally implemented as a separate small service per
the `eob-mcp` architecture principle ("do one thing well").

## What it does

For every `CREATE` Pod request in the `tawon-operator` namespace,
inspects the pod's `app.kubernetes.io/name` label. If the label is

  - `tawon-streamstore-*`  (any chart-generated suffix), or
  - `tawon-directive`      (per-directive agent DaemonSets), or
  - `tawon-dashboard`

…the webhook returns a JSONPatch that adds:

  - `spec.hostNetwork: true`
  - `spec.dnsPolicy: ClusterFirstWithHostNet`

Everything else gets a no-op `allowed: true` response.

## Build + deploy

```bash
# 1. Build image (on master-0, where the in-cluster registry is reachable)
podman build -t 172.31.44.247:5000/mantisnet/tawon-pod-injector:dev .
podman push --tls-verify=false 172.31.44.247:5000/mantisnet/tawon-pod-injector:dev

# 2. Generate self-signed TLS cert (server cert == CA, simple dev setup)
./deploy/certs/gen.sh > /tmp/certs.env
. /tmp/certs.env

# 3. Render the manifest with the cert baked in
envsubst '${TLS_CRT} ${TLS_KEY} ${CA_BUNDLE}' \
  < deploy/k8s/manifest.template.yaml \
  > /tmp/tawon-pod-injector.yaml

# 4. Apply
kubectl apply -f /tmp/tawon-pod-injector.yaml

# 5. Watch the webhook come up
kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-pod-injector
kubectl -n tawon-operator logs -l app.kubernetes.io/name=tawon-pod-injector
```

## Verify

After the webhook is running, every future Tawon pod will be
auto-patched. To test:

```bash
# Delete the streamstore pod; the operator recreates it; the webhook
# mutates the new pod; it gets hostNetwork=true.
kubectl -n tawon-operator delete pod tawon-streamstore-0
kubectl -n tawon-operator get pod tawon-streamstore-0 -o jsonpath='{.spec.hostNetwork}'
# expect: true
```

## Failure mode

`failurePolicy: Ignore` — if the webhook is down, pod creation
proceeds without mutation. This means the cluster stays usable even
when the injector is unhealthy; the trade-off is that Tawon pods
created during an injector outage will hit the Vega CNI block as
before. Production deployments should probably set this to `Fail` and
run multiple webhook replicas.

## Architecture

```
~150 LOC business logic, ~120 LOC server wiring, distroless static image.

cmd/injector/main.go           HTTPS server, /mutate handler, /healthz
internal/inject/inject.go      Match(pod) + Patch(pod) → JSONPatch
internal/inject/inject_test.go behavior tests, no Kubernetes required
deploy/certs/gen.sh            self-signed cert generator
deploy/k8s/manifest.template.yaml  SA, Secret, Deployment, Service, MWC
```

## Not in scope

- **Per-pod customization beyond hostNetwork.** If different Tawon
  components ever need different network modes, fork the Match logic.
  Today they all need the same thing on this site.
- **Cert rotation.** Self-signed cert with 10y lifetime. For prod use
  cert-manager + `cert-manager.io/inject-ca-from` annotation on the
  MutatingWebhookConfiguration.
- **Multi-cluster federation.** This is a per-cluster sidecar service.
  One per XC site that needs it; no inter-cluster anything.
