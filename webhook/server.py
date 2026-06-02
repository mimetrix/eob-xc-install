#!/usr/bin/env python3
"""
EoB mutating admission webhook.

Injects hostNetwork=true, dnsPolicy=ClusterFirstWithHostNet, and hostAliases for
"nats" -> NATS ClusterIP onto pods that the Tawon operator spawns from a
ClusterDirective (label app.kubernetes.io/name=tawon-directive). Also assigns a
deterministic per-directive offset to the agent's probe and metrics hostPorts so
multiple ClusterDirectives can co-exist on the same nodes without colliding on
the default :8081 / :9990.

Why: Mantis EoB's operator owns the agent DaemonSet spec and reverts any external
patch that tries to set hostNetwork. On F5 XC sites without a Vega VN binding for
the tawon-operator namespace, the agent pods fail with
  "Failed adding interface to vega: Error in getting VN for namespace"
unless they bypass CNI via hostNetwork. This webhook flips that bit at admission
time so the operator never sees it.

The hostPort remap is also a side-effect of hostNetwork: with pod networking each
agent has a distinct pod IP and 8081/9990 don't collide; on hostNetwork all pods
on a node share the node IP so two directives fight for the same port. Upstream
fix would be either pod networking (needs Vega VN provisioning) or a Mantis chart
knob exposing the agent's --probes.addr / --metrics.addr.

Configuration (via environment, with sensible defaults):
  NATS_IP        -- ClusterIP of the tawon-streamstore service. Pass through
                    the systemd unit's EnvironmentFile so it picks up the real
                    value at install time.
  STREAMSTORE_FQDN -- The full cluster.local FQDN the operator hardcodes for
                    streamstore (e.g. tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local).
                    The agent's NATS URL is set to this FQDN by the operator,
                    overriding the directive's `messaging.nats.url` field. We
                    point it at NATS_IP via hostAliases.
  PROBE_PORT_BASE  / PROBE_PORT_RANGE   -- default 18081 / 1000
  METRICS_PORT_BASE / METRICS_PORT_RANGE -- default 19990 / 1000
                    Per-directive port is BASE + (sha1(directive-name) % RANGE).
                    Probe and metrics ranges must not overlap; defaults are
                    [18081..19080] and [19990..20989].
  PORT           -- listen port. Default 9443.
  CERTFILE       -- TLS cert path. Default /etc/eob-mutate/tls.crt
  KEYFILE        -- TLS key path.  Default /etc/eob-mutate/tls.key
"""
import base64
import hashlib
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


NATS_IP = os.environ.get("NATS_IP", "10.3.38.189")
STREAMSTORE_FQDN = os.environ.get("STREAMSTORE_FQDN",
    "tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local")
PROBE_PORT_BASE = int(os.environ.get("PROBE_PORT_BASE", "18081"))
PROBE_PORT_RANGE = int(os.environ.get("PROBE_PORT_RANGE", "1000"))
METRICS_PORT_BASE = int(os.environ.get("METRICS_PORT_BASE", "19990"))
METRICS_PORT_RANGE = int(os.environ.get("METRICS_PORT_RANGE", "1000"))
PORT = int(os.environ.get("PORT", "9443"))
CERTFILE = os.environ.get("CERTFILE", "/etc/eob-mutate/tls.crt")
KEYFILE = os.environ.get("KEYFILE", "/etc/eob-mutate/tls.key")

AGENT_CONTAINER_NAME = "tawon-directive"

# Pods this webhook will mutate. The MutatingWebhookConfiguration drops
# its objectSelector to admit every pod in `tawon-operator`, so this set
# is the actual gate. Membership rule: name (or generateName) starts
# with one of these prefixes — covers the three Tawon-rendered pod
# families (agent DaemonSet, dashboard Deployment, streamstore
# StatefulSet) and stays oblivious to chart-generated hex suffixes.
TAWON_MANAGED_NAME_PREFIXES = (
    "tawon-directive",
    "tawon-dashboard",
    "tawon-streamstore",
)


def is_tawon_managed(pod):
    """True if the admitted pod is one of the Tawon-rendered families
    that need hostNetwork + hostAliases injection. False for unrelated
    pods that happen to live in the same namespace (eob-mcp, debug pods,
    etc.) — those pass through unmodified."""
    meta = pod.get("metadata", {}) or {}
    name = meta.get("name") or meta.get("generateName") or ""
    return any(name.startswith(p) for p in TAWON_MANAGED_NAME_PREFIXES)


def directive_identity(pod):
    """Stable per-directive identifier (DS name) from the admitted pod."""
    meta = pod.get("metadata", {}) or {}
    for ref in meta.get("ownerReferences", []) or []:
        if ref.get("kind") == "DaemonSet" and ref.get("name"):
            return ref["name"]
    gn = (meta.get("generateName") or "").rstrip("-")
    return gn or None


def port_offset(name, mod):
    """Deterministic offset in [0, mod) from a string identifier."""
    h = hashlib.sha1(name.encode("utf-8")).digest()
    return int.from_bytes(h[:4], "big") % mod


def make_patch(pod):
    """Return a JSONPatch (RFC 6902) list that toggles hostNetwork, points the
    hardcoded streamstore FQDN at the NATS ClusterIP, and assigns per-directive
    probe/metrics ports. Returns [] for any pod that is not a Tawon-managed
    family — those pass through admission unchanged."""
    if not is_tawon_managed(pod):
        return []
    spec = pod.get("spec", {}) or {}
    patches = [
        {"op": "replace" if "hostNetwork" in spec else "add",
         "path": "/spec/hostNetwork", "value": True},
        {"op": "replace" if "dnsPolicy" in spec else "add",
         "path": "/spec/dnsPolicy", "value": "ClusterFirstWithHostNet"},
        {"op": "replace" if "hostAliases" in spec else "add",
         "path": "/spec/hostAliases",
         "value": [{"ip": NATS_IP, "hostnames": ["nats", STREAMSTORE_FQDN]}]},
    ]

    ident = directive_identity(pod)
    if not ident:
        return patches

    probe_port = PROBE_PORT_BASE + port_offset(ident + "/probes", PROBE_PORT_RANGE)
    metrics_port = METRICS_PORT_BASE + port_offset(ident + "/metrics", METRICS_PORT_RANGE)

    for ci, container in enumerate(spec.get("containers", []) or []):
        if container.get("name") != AGENT_CONTAINER_NAME:
            continue

        for pi, p in enumerate(container.get("ports", []) or []):
            pname = p.get("name")
            if pname == "http-probes":
                new_port = probe_port
            elif pname == "http-metrics":
                new_port = metrics_port
            else:
                continue
            patches.append({"op": "replace",
                "path": f"/spec/containers/{ci}/ports/{pi}/containerPort",
                "value": new_port})
            if "hostPort" in p:
                patches.append({"op": "replace",
                    "path": f"/spec/containers/{ci}/ports/{pi}/hostPort",
                    "value": new_port})

        env_list = container.get("env", []) or []
        env_names = {e.get("name"): ei for ei, e in enumerate(env_list)}
        # TAWON_METRICS_ADDR is normally set by the operator; just replace its value.
        if "TAWON_METRICS_ADDR" in env_names:
            patches.append({"op": "replace",
                "path": f"/spec/containers/{ci}/env/{env_names['TAWON_METRICS_ADDR']}/value",
                "value": f":{metrics_port}"})
        else:
            patches.append({"op": "add",
                "path": f"/spec/containers/{ci}/env/-",
                "value": {"name": "TAWON_METRICS_ADDR", "value": f":{metrics_port}"}})
        # TAWON_PROBES_ADDR is NOT set by the operator (probes default to :8081
        # from the binary). Append.
        if "TAWON_PROBES_ADDR" in env_names:
            patches.append({"op": "replace",
                "path": f"/spec/containers/{ci}/env/{env_names['TAWON_PROBES_ADDR']}/value",
                "value": f":{probe_port}"})
        else:
            patches.append({"op": "add",
                "path": f"/spec/containers/{ci}/env/-",
                "value": {"name": "TAWON_PROBES_ADDR", "value": f":{probe_port}"}})

    return patches


class Handler(BaseHTTPRequestHandler):
    server_version = "eob-mutate/1"

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _route(self):
        return self.path.split("?", 1)[0]

    def do_GET(self):
        if self._route() in ("/", "/healthz"):
            self._send_json(200, {"ok": True})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self._route() != "/mutate":
            self.send_response(404)
            self.end_headers()
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            review = json.loads(self.rfile.read(length))
            req = review["request"]
            uid = req["uid"]
            pod = req["object"]
            patches = make_patch(pod)
            patch_b64 = base64.b64encode(json.dumps(patches).encode()).decode()
            response = {
                "apiVersion": review.get("apiVersion", "admission.k8s.io/v1"),
                "kind": "AdmissionReview",
                "response": {
                    "uid": uid,
                    "allowed": True,
                    "patchType": "JSONPatch",
                    "patch": patch_b64,
                },
            }
            self._send_json(200, response)
        except Exception as e:
            # Send a deny only if we can't even parse — better than a hung admission call.
            sys.stderr.write(f"[eob-mutate] error: {e}\n")
            self._send_json(500, {
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": {
                    "uid": "",
                    "allowed": False,
                    "status": {"message": f"webhook error: {e}"},
                },
            })

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[eob-mutate] {self.address_string()} {fmt % args}\n")


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=CERTFILE, keyfile=KEYFILE)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write(
        f"[eob-mutate] listening on https://0.0.0.0:{PORT}/mutate "
        f"(NATS_IP={NATS_IP})\n"
    )
    sys.stderr.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
