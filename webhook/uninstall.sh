#!/usr/bin/env bash
# Remove the EoB mutating admission webhook from master-0 and the cluster.
set -euo pipefail

log() { echo "[webhook-uninstall] $*" >&2; }

log "Removing MutatingWebhookConfiguration"
kubectl delete mutatingwebhookconfiguration eob-mutate --ignore-not-found

log "Stopping + disabling systemd unit"
sudo systemctl disable --now eob-mutate.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/eob-mutate.service
sudo systemctl daemon-reload

log "Removing files"
sudo rm -rf /etc/eob-mutate /usr/local/bin/eob-mutate.py

log "Done. Note: existing agent pods retain their mutations until they're recreated."
log "To force a fresh cycle (which will then NOT get the hostNetwork mutation):"
echo "  kubectl -n tawon-operator delete pods -l app.kubernetes.io/name=tawon-directive --grace-period=0 --force"
