#!/usr/bin/env bash
# Tear down everything install.sh put in place.
# Does NOT remove images from cri-o or delete the release-package tarball.
set -euo pipefail

log() { echo "[uninstall] $*" >&2; }

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Removing mutating webhook (if installed)"
[[ -x "$BUNDLE_DIR/webhook/uninstall.sh" ]] && "$BUNDLE_DIR/webhook/uninstall.sh" || true

log "Deleting child CRs first so finalizers process"
kubectl -n tawon-operator delete \
  directives,clusterdirectives,streams,dashboards,streamstores --all --wait=false 2>/dev/null || true

log "Helm uninstall"
helm uninstall tawon-operator -n operators 2>/dev/null || true

log "Deleting Tawon CRDs"
kubectl delete crd \
  clusterdirectives.tawon.mantisnet.com \
  directives.tawon.mantisnet.com \
  directivebindings.tawon.mantisnet.com \
  dashboards.tawon.mantisnet.com \
  streams.tawon.mantisnet.com \
  streamstores.tawon.mantisnet.com \
  topologyaggregators.tawon.mantisnet.com 2>/dev/null || true

log "Deleting PVCs"
kubectl -n tawon-operator delete pvc --all --wait=false 2>/dev/null || true

log "Deleting namespaces"
kubectl delete ns operators tawon-operator --wait=false 2>/dev/null || true

log "Done."
