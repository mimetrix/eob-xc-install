#!/usr/bin/env bash
#
# install.sh — Reproducible end-to-end EoB rc4 install on an F5 XC CE site.
#
# Assumptions:
#   - Run on master-0 as a user who can sudo (typically xcuser).
#   - This script lives in a directory alongside README.md, values-override.yaml,
#     and patches/. Run from that directory.
#   - The release-package tarball has already been extracted at
#     ~/eob/release-package-3.0.0-rc4/ (or pass --pkg-dir).
#   - Quay auth is configured at BOTH ~/.config/containers/auth.json and
#     /root/.config/containers/auth.json (see README step 1).
#
# Usage:
#   ./install.sh [--pkg-dir <path>] [--skip-load] [--skip-helm]
#
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${HOME}/eob/release-package-3.0.0-rc4"
SKIP_LOAD=0
SKIP_HELM=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg-dir)      PKG_DIR="$2"; shift 2 ;;
    --skip-load)    SKIP_LOAD=1; shift ;;
    --skip-helm)    SKIP_HELM=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -2
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { echo "[install] $*" >&2; }

[[ -d "$PKG_DIR" ]] || { echo "ERROR: pkg dir $PKG_DIR not found" >&2; exit 1; }
[[ -f "$BUNDLE_DIR/values-override.yaml" ]] || { echo "ERROR: values-override.yaml missing" >&2; exit 1; }

# 0. Pre-install gates — cluster prerequisites this script depends on.
#    These were discovered the hard way during a marathon 2026-06-01 debug
#    session; each one would silently break the install if skipped.
log "Phase 0: pre-install gates"

# 0.1 Default StorageClass MUST be hostpath, not standard. The cluster's
#     `standard` SC declares the in-tree kubernetes.io/aws-ebs provisioner
#     which was removed in k8s 1.27 — PVCs against it hang forever.
DEFAULT_SC=$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')
if [[ "$DEFAULT_SC" != "hostpath" ]]; then
  log "  flipping default StorageClass: ${DEFAULT_SC:-<none>} -> hostpath"
  if [[ -n "$DEFAULT_SC" ]]; then
    kubectl patch sc "$DEFAULT_SC" \
      -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
      > /dev/null
  fi
  kubectl patch sc hostpath \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
    > /dev/null
else
  log "  hostpath already default"
fi

# 0.2 Master node-role labels. The Tawon agent DaemonSet has nodeAffinity
#     requiring `node-role.kubernetes.io/master` (or worker). XC nodes only
#     carry `kubernetes.io/role=ves-master` by default, so the DS never
#     schedules a single pod without this.
for n in $(kubectl get nodes -l 'kubernetes.io/role=ves-master' -o name 2>/dev/null); do
  kubectl label "$n" node-role.kubernetes.io/master= --overwrite > /dev/null
done
log "  master nodes labeled with node-role.kubernetes.io/master"

# 1. Load images (rootful — critical so cri-o sees them)
if [[ "$SKIP_LOAD" -eq 0 ]]; then
  log "Loading rc4 images into rootful podman / cri-o (sudo)"
  (cd "$PKG_DIR" && sudo RUNTIME=podman ./load.sh --runtime podman) > /dev/null
  log "Images loaded. Verifying with crictl..."
  sudo crictl images | grep "v3.0.0-rc4" | wc -l | xargs -I{} echo "[install] crictl sees {} rc4 images"
fi

# 2. Helm install via the release-package install.sh
if [[ "$SKIP_HELM" -eq 0 ]]; then
  log "Running release-package install.sh with values override"
  (cd "$PKG_DIR" && ./install.sh \
    --chart-version 3.0.0-rc4 \
    --namespace operators \
    -f "$BUNDLE_DIR/values-override.yaml")
fi

# 3. Patch operator Deployment
log "Patching operator Deployment (hostNetwork, nodeSelector, ports, pullPolicy)"
kubectl apply -f "$BUNDLE_DIR/patches/01-operator-deploy.yaml"

# 3.5. tawon-config CM tweak — namespacedDirective.nodeRoles defaults to
#      `worker`, but XC sites have no dedicated workers (everything's a
#      master). Without this, namespaced Directives produce a DS with
#      `desiredNumberScheduled: 0` even when a DirectiveBinding picks a
#      master explicitly. The operator restart in Phase 4 picks this up.
if kubectl -n operators get cm tawon-config -o jsonpath='{.data.config}' 2>/dev/null \
   | grep -q '^  nodeRoles: worker$'; then
  log "Phase 3.5: tawon-config namespacedDirective.nodeRoles -> master,worker"
  kubectl -n operators get cm tawon-config -o jsonpath='{.data.config}' > /tmp/tawon-config.before
  sed 's|^  nodeRoles: worker$|  nodeRoles: master,worker|' /tmp/tawon-config.before > /tmp/tawon-config.after
  kubectl -n operators create cm tawon-config --from-file=config=/tmp/tawon-config.after \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  log "  CM updated (operator restart in Phase 4 will pick it up)"
fi

# 4. Restart operator to apply env vars AND let it create child CRs from scratch
log "Restarting operator (scale 0/1) so child CRs are created with the right defaults"
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=0 > /dev/null
sleep 8
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=1 > /dev/null

# Wait for operator to be Ready
log "Waiting up to 120s for operator pod 2/2 Ready"
kubectl -n operators wait --for=condition=Ready pod \
  -l control-plane=controller-manager --timeout=120s

# 5. Wait for operator to create the child CRs
log "Waiting up to 60s for operator-spawned Dashboard + StreamStore CRs"
for _ in $(seq 1 30); do
  if kubectl -n tawon-operator get dashboard tawon-dashboard >/dev/null 2>&1 \
     && kubectl -n tawon-operator get streamstore tawon-streamstore >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# 6. Patch Dashboard CR (disable oauth) and Deployment (hostNetwork etc.)
log "Patching Dashboard CR (oauth off)"
kubectl apply -f "$BUNDLE_DIR/patches/02-dashboard-cr.yaml"

log "Waiting for operator to materialize Dashboard Deployment"
for _ in $(seq 1 30); do
  if kubectl -n tawon-operator get deploy tawon-dashboard >/dev/null 2>&1; then break; fi
  sleep 2
done

log "Patching Dashboard Deployment"
kubectl -n tawon-operator patch deploy tawon-dashboard \
  --patch-file "$BUNDLE_DIR/patches/03-dashboard-deploy-patch.yaml"

# 7. Patch StreamStore CR (hostpath) and StatefulSet (hostNetwork etc.)
log "Patching StreamStore CR (storageClassName=hostpath)"
kubectl apply -f "$BUNDLE_DIR/patches/04-streamstore-cr.yaml"

log "Waiting for operator to materialize StreamStore StatefulSet"
for _ in $(seq 1 30); do
  if kubectl -n tawon-operator get sts tawon-streamstore >/dev/null 2>&1; then break; fi
  sleep 2
done

log "Patching StreamStore StatefulSet"
kubectl -n tawon-operator patch sts tawon-streamstore \
  --patch-file "$BUNDLE_DIR/patches/05-streamstore-sts-patch.yaml"

# 8. Force a fresh PVC under the new storageClassName, plus fix NATS image to tag ref
log "Re-creating StreamStore PVC under hostpath and overriding NATS image"
kubectl -n tawon-operator delete pvc -l app=tawon-streamstore --wait=false || true
kubectl -n tawon-operator delete pod tawon-streamstore-0 \
  --grace-period=0 --force --wait=false 2>/dev/null || true
kubectl -n tawon-operator set image sts/tawon-streamstore \
  tawon-streamstore-d2f18e=quay.io/mantisnet/nats:2.10.4-alpine

# 9. Wait for NATS pod, then add hostAliases on operator pointing the hardcoded
# *.cluster.local FQDN at the NATS ClusterIP. The operator's StreamReconciler
# hardcodes .cluster.local — KUBERNETES_CLUSTER_DOMAIN env is NOT honored there.
log "Waiting for StreamStore pod Ready (needed to get NATS ClusterIP)"
kubectl -n tawon-operator wait --for=condition=Ready pod tawon-streamstore-0 \
  --timeout=180s || true

# Use the streamstore POD's hostIP (stable, master-master traffic works),
# NOT the Service ClusterIP. Two reasons:
#   1. The ClusterIP changes if the Service is recreated, leaving operator
#      hostAliases stale (we hit this multiple times during the 2026-06-01
#      debug session).
#   2. Cross-node Service routing is broken on this XC site — kube-proxy
#      programs the iptables rules but they don't deliver. Host-to-host
#      traffic on the vpm-segment-inbound interface works fine.
# Since patches/05 pins the streamstore StatefulSet to master-0, this is
# stable as long as that pin holds.
NATS_IP=$(kubectl -n tawon-operator get pod tawon-streamstore-0 \
  -o jsonpath='{.status.hostIP}')
[[ -n "$NATS_IP" ]] || { echo "ERROR: streamstore pod hostIP not available; can't apply hostAliases" >&2; exit 1; }
log "NATS endpoint (streamstore pod hostIP): $NATS_IP"

# Discover the cluster DNS suffix (for the KUBERNETES_CLUSTER_DOMAIN env hygiene)
XC_DNS_SUFFIX=$(sudo find /run/containers/storage -name resolv.conf -exec grep -h '^search' {} \; 2>/dev/null \
  | head -1 | tr ' ' '\n' | grep '^svc\.' | head -1 | sed 's/^svc\.//')
log "XC DNS suffix: ${XC_DNS_SUFFIX:-<unknown — KUBERNETES_CLUSTER_DOMAIN will stay at chart default>}"

log "Patching operator with hostAliases + KUBERNETES_CLUSTER_DOMAIN"
kubectl -n operators patch deploy tawon-operator-controller-manager --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{
        \"hostAliases\":[{
          \"ip\":\"${NATS_IP}\",
          \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",\"nats\"]
        }]
      }}}}"

# Dashboard's packet viewer (pktsapi) opens a JetStream consumer against the same
# hardcoded .cluster.local NATS FQDN; without hostAliases it times out with
# "load nats jetstream stream: create consumer: context deadline exceeded".
log "Patching dashboard with hostAliases (NATS FQDN → ClusterIP)"
kubectl -n tawon-operator patch deploy tawon-dashboard --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{
        \"hostAliases\":[{
          \"ip\":\"${NATS_IP}\",
          \"hostnames\":[\"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local\",\"nats\"]
        }]
      }}}}"

if [[ -n "$XC_DNS_SUFFIX" ]]; then
  kubectl -n operators set env deploy/tawon-operator-controller-manager \
    -c manager KUBERNETES_CLUSTER_DOMAIN="${XC_DNS_SUFFIX}"
fi

# Force restart via scale 0/1 (rolling update fails on hostPort collision since both
# pods would want 18443 on master-0).
log "Restarting operator (scale 0/1) to apply hostAliases + env"
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=0
sleep 6
kubectl -n operators scale deploy tawon-operator-controller-manager --replicas=1

# 10. Verify
log "Waiting up to 120s for operator Ready after final patch"
kubectl -n operators wait --for=condition=Ready pod \
  -l control-plane=controller-manager --timeout=120s || true
log "Waiting up to 120s for dashboard pod Ready"
kubectl -n tawon-operator wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=tawon-dashboard --timeout=120s || true

# 11. Mutating admission webhooks. TWO webhooks live alongside this install,
# each owns a different concern; both must run for the EoB stack to be usable:
#
#   webhook/                 (eob-mutate, Python) — per-directive port remap
#                            so multiple ClusterDirectives can coexist on
#                            the same hostNetwork node.
#
#   tawon-pod-injector/      (Go, sibling repo at mimetrix/tawon-pod-injector)
#                            — injects hostNetwork=true and corrects the
#                            operator-stamped stale-IP hostAliases on every
#                            Tawon-managed pod at admission.
#
# Without #1, multi-directive setups collide. Without #2, agent pods can't
# bind their host ports (Vega CNI block) and can't reach the streamstore.
log "Phase 11: install eob-mutate webhook (port remapping)"
if [[ -x "$BUNDLE_DIR/webhook/install.sh" ]]; then
  (cd "$BUNDLE_DIR/webhook" && ./install.sh) || log "  warning: eob-mutate install returned non-zero"
else
  log "  webhook/install.sh not executable; skipped"
fi

log "Phase 11.5: install tawon-pod-injector webhook (hostNetwork + hostAliases injection)"
TPI_DIR="${TPI_DIR:-${HOME}/tawon-pod-injector}"
if [[ -d "$TPI_DIR" ]]; then
  log "  found $TPI_DIR — see its README for the build + deploy commands"
  log "  (this script does NOT invoke it automatically since it requires"
  log "  podman build + cert gen + envsubst; do it once manually per site)"
else
  log "  $TPI_DIR not found — clone mimetrix/tawon-pod-injector and follow"
  log "  RUNBOOK.md Phase 4. Without this, agent pods will hit the Vega CNI"
  log "  block AND publish 'not connected' against stale operator hostAliases."
fi

echo
echo "[install] Final state:"
kubectl -n operators get pods
kubectl -n tawon-operator get pods
echo
echo "[install] Stream readiness check (must be Ready=True before ClusterDirectives work):"
kubectl -n tawon-operator get streams 2>/dev/null || echo "  (no Streams yet — apply a ClusterDirective first)"
echo
echo "[install] Done. To access the dashboard, run from your workstation:"
echo "  ssh -i ~/.ssh/id_ed25519_xc -L 8789:127.0.0.1:8789 xcuser@3.147.217.91 -N"
echo "  Then browse to http://localhost:8789"
echo
echo "For permanent external access, ask the XC tenant admin to open inbound TCP 8789"
echo "in the AWS security group attached to the master EC2 instances. No vpm/iptables"
echo "change is needed — vpm-segment-inbound only filters the vhost-seg+ overlay."
echo "See admin-firewall-request.md for the request template."
echo
echo "When you apply a ClusterDirective: OMIT spec.duration / spec.stopAt or set"
echo "duration: 8760h, otherwise the operator will mark it DirectiveStopped after that time."
echo
echo "Note: with the in-cluster registry mirror live on all 3 nodes, the agent DaemonSet"
echo "should reach Ready cluster-wide. If master-1/master-2 sit in ImagePullBackOff,"
echo "the mirror conf is missing on those nodes — see README 'Multi-node images'."
