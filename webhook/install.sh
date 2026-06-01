#!/usr/bin/env bash
#
# install.sh — Deploy the EoB mutating admission webhook on master-0.
#
# Generates a self-signed TLS cert, installs the Python webhook server as a
# systemd service, and applies a MutatingWebhookConfiguration that targets
# pods in the `tawon-operator` namespace with label
# `app.kubernetes.io/name=tawon-directive`.
#
# Run as a sudo-capable user on master-0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${WEBHOOK_PORT:-9443}"

log() { echo "[webhook-install] $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Sanity check: chosen port must be free on master-0. The XC `vpm-segment-inbound`
# iptables chain only filters traffic on `vhost-seg+` (Vega tenant overlay) interfaces;
# the k8s node IP lives on `vhost0`, so master-to-master traffic is not gated by it.
log "Checking port $PORT availability"
if sudo ss -tln 2>/dev/null | awk '{print $4}' | grep -E ":${PORT}\$" >/dev/null; then
  fail "Port $PORT is already in use. Set WEBHOOK_PORT=<free port> and retry."
fi

# 1) Discover master-0 internal IP (what the apiserver will dial).
HOST_IP=$(kubectl get node master-0 \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
[[ -n "$HOST_IP" ]] || { echo "ERROR: can't determine master-0 InternalIP" >&2; exit 1; }
log "master-0 InternalIP: $HOST_IP"

# 2) Discover NATS ClusterIP and full streamstore svc FQDN for hostAliases injection.
#    The operator overrides the directive's nats:// URL with the streamstore svc's
#    cluster.local FQDN, which doesn't resolve on XC sites (suffix is tenant.local).
#    So we hostAlias both `nats` and the FQDN to the NATS ClusterIP.
STREAMSTORE_SVC=$(kubectl -n tawon-operator get svc -l app=tawon-streamstore \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$STREAMSTORE_SVC" ]]; then
  STREAMSTORE_SVC=$(kubectl -n tawon-operator get svc -o name 2>/dev/null | \
    grep -E 'tawon-streamstore-[a-f0-9]+$' | head -1 | sed 's|service/||')
fi
[[ -n "$STREAMSTORE_SVC" ]] || { echo "ERROR: NATS svc (tawon-streamstore-*) not found — run the core install first" >&2; exit 1; }
# Prefer the streamstore Pod's hostIP over the Service ClusterIP. The Service IP
# goes stale on chart re-install (the operator never updates this webhook with
# the new value), and cross-node Service routing is broken on XC sites anyway.
# As long as the streamstore StatefulSet stays pinned to master-0 via patches/05,
# the Pod hostIP is stable across the operator's life.
NATS_IP=$(kubectl -n tawon-operator get pod tawon-streamstore-0 -o jsonpath='{.status.hostIP}' 2>/dev/null)
if [[ -z "$NATS_IP" ]]; then
  log "  streamstore pod not ready yet; falling back to Service ClusterIP (may go stale)"
  NATS_IP=$(kubectl -n tawon-operator get svc "$STREAMSTORE_SVC" -o jsonpath='{.spec.clusterIP}')
fi
STREAMSTORE_FQDN="${STREAMSTORE_SVC}.tawon-operator.svc.cluster.local"
log "NATS endpoint (streamstore pod hostIP): $NATS_IP"
log "hostAliases FQDN: $STREAMSTORE_FQDN"

# 3) Generate self-signed TLS cert.
log "Generating TLS cert at /etc/eob-mutate/ (subject IP=$HOST_IP)"
sudo mkdir -p /etc/eob-mutate
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/eob-mutate/tls.key \
  -out    /etc/eob-mutate/tls.crt \
  -subj   "/CN=$HOST_IP" \
  -addext "subjectAltName=IP:$HOST_IP" \
  >/dev/null 2>&1
sudo chmod 600 /etc/eob-mutate/tls.key
CA_B64=$(sudo cat /etc/eob-mutate/tls.crt | base64 -w0)

# 4) Drop the Python webhook server into /usr/local/bin.
log "Installing /usr/local/bin/eob-mutate.py"
sudo cp "$SCRIPT_DIR/server.py" /usr/local/bin/eob-mutate.py
sudo chmod 755 /usr/local/bin/eob-mutate.py

# 5) Write systemd environment file with discovered values.
log "Writing /etc/eob-mutate/env"
sudo tee /etc/eob-mutate/env >/dev/null <<EOF
NATS_IP=$NATS_IP
STREAMSTORE_FQDN=$STREAMSTORE_FQDN
PORT=$PORT
CERTFILE=/etc/eob-mutate/tls.crt
KEYFILE=/etc/eob-mutate/tls.key
# --- per-directive port remap (defaults shown; override if you need wider ranges) ---
# Probe range:   [PROBE_PORT_BASE, PROBE_PORT_BASE + PROBE_PORT_RANGE)
# Metrics range: [METRICS_PORT_BASE, METRICS_PORT_BASE + METRICS_PORT_RANGE)
# Bump *_RANGE to 10000 if running more than ~20 concurrent ClusterDirectives.
#PROBE_PORT_BASE=18081
#PROBE_PORT_RANGE=1000
#METRICS_PORT_BASE=19990
#METRICS_PORT_RANGE=1000
EOF

# 6) Install + start systemd unit.
log "Installing systemd unit"
sudo cp "$SCRIPT_DIR/eob-mutate.service" /etc/systemd/system/eob-mutate.service
sudo systemctl daemon-reload
sudo systemctl enable --now eob-mutate.service

# 7) Wait for the webhook to be reachable on localhost.
log "Waiting for webhook to come up on :$PORT"
for _ in $(seq 1 20); do
  if curl -sS -k --max-time 2 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    log "  webhook healthcheck OK"
    break
  fi
  sleep 1
done

# 8) Apply the MutatingWebhookConfiguration with substitutions.
log "Applying MutatingWebhookConfiguration"
sed "s|__HOST_IP__|$HOST_IP|g; s|__PORT__|$PORT|g; s|__CA_B64__|$CA_B64|g" \
  "$SCRIPT_DIR/mutating-webhook-config.yaml.tmpl" | kubectl apply -f -

# 9) Quick verification: trigger a fresh pod cycle and confirm hostNetwork lands.
log "Webhook installed. To verify end-to-end, delete the agent pods and watch them respawn:"
echo
echo "  kubectl -n tawon-operator delete pods -l app.kubernetes.io/name=tawon-directive --grace-period=0 --force"
echo "  kubectl -n tawon-operator get pods -l app.kubernetes.io/name=tawon-directive -o jsonpath='{range .items[*]}{.metadata.name}: hostNetwork={.spec.hostNetwork}{\"\\n\"}{end}'"
echo
log "Done."
