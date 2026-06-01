// Package inject computes the JSONPatch that a Tawon-managed pod needs
// to bypass Vega CNI block + cluster.local DNS hardcoding on F5 XC sites.
//
// Two related XC-specific quirks the Tawon CRDs don't address:
//
//  1. Vega CNI rejects pods in the tawon-operator namespace with
//     `Error in getting VN for namespace`. Fix: hostNetwork=true.
//
//  2. Tawon hardcodes cluster.local in its NATS / pktsapi URLs (see
//     memory: project_xc_cluster_dns_suffix), but XC sites use
//     <site>.<tenant>.tenant.local as the DNS suffix. Fix: hostAliases
//     entries mapping the hardcoded names to a reachable IP.
//
// This webhook applies both at pod admission. Operator reconciles
// can't undo them because the StatefulSet/DaemonSet spec stays
// unchanged — the mutation happens to the rendered Pod object.
package inject

import (
	"encoding/json"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
)

// StreamStoreHostIP is the node IP where the streamstore Pod runs
// (hostNetwork=true means Pod IP == node IP). NATS clients in
// directive agents resolve `nats` and the cluster.local FQDN to
// this address via injected hostAliases.
//
// TODO: read this from a ConfigMap or env var so it's not hardcoded
// per-deploy. For the srikan-tf-test-0 install it's master-2.
const StreamStoreHostIP = "172.31.33.234"

// streamstoreHostnames are the names Tawon's runtime expects to
// resolve to the streamstore. The operator hardcodes the cluster.local
// FQDN; agents also use the short name "nats" out of their config.
var streamstoreHostnames = []string{
	"nats",
	"tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local",
	"tawon-streamstore-d2f18e.tawon-operator.svc",
	"tawon-streamstore-d2f18e",
}

// Match decides whether a pod is a Tawon-managed pod that needs the
// hostNetwork mutation. Identity comes from the standard label
// `app.kubernetes.io/name`:
//
//   tawon-streamstore-<chart-suffix>  → StreamStore
//   tawon-directive                   → ClusterDirective agent DaemonSets
//   tawon-dashboard                   → Dashboard
//
// The operator and webhook themselves are NOT in scope — they have
// their own deploy-time configuration that already sets the right
// network mode.
func Match(pod *corev1.Pod) bool {
	name := pod.Labels["app.kubernetes.io/name"]
	switch {
	case strings.HasPrefix(name, "tawon-streamstore"):
		return true
	case name == "tawon-directive":
		return true
	case name == "tawon-dashboard":
		return true
	}
	return false
}

// Patch returns the JSONPatch operations needed to put the pod into
// host-network mode plus a hostAliases entry pointing the streamstore
// names at the right IP. Returns nil + nil when no mutation is
// needed (Match returned false OR the pod already has every setting).
func Patch(pod *corev1.Pod) ([]Op, error) {
	if !Match(pod) {
		return nil, nil
	}
	var ops []Op
	if !pod.Spec.HostNetwork {
		ops = append(ops, Op{Op: "add", Path: "/spec/hostNetwork", Value: true})
	}
	wantDNS := corev1.DNSClusterFirstWithHostNet
	if pod.Spec.DNSPolicy != wantDNS {
		// "replace" is the safe choice: the field is always set by
		// the apiserver to a default before admission webhooks run,
		// so "add" would conflict.
		ops = append(ops, Op{Op: "replace", Path: "/spec/dnsPolicy", Value: string(wantDNS)})
	}
	if pod.Labels["app.kubernetes.io/name"] == "tawon-directive" {
		ops = append(ops, hostAliasOps(pod)...)
	}
	return ops, nil
}

// hostAliasOps returns the JSONPatch ops to ensure the pod has a
// hostAliases entry mapping the streamstore hostnames to the right IP.
//
// Three cases:
//   - existing alias for our hostnames has the right IP → no-op
//   - existing alias for our hostnames has WRONG IP (operator stamped
//     a stale value) → replace just that entry's IP
//   - no existing alias for our hostnames → add a fresh one
func hostAliasOps(pod *corev1.Pod) []Op {
	wantAlias := corev1.HostAlias{IP: StreamStoreHostIP, Hostnames: streamstoreHostnames}

	for i, ha := range pod.Spec.HostAliases {
		if !aliasMatchesStreamstore(ha) {
			continue
		}
		if ha.IP == StreamStoreHostIP {
			return nil // already correct
		}
		// Same alias, wrong IP — replace only the .ip field so we
		// preserve any extra hostnames the operator added.
		return []Op{{
			Op:    "replace",
			Path:  fmt.Sprintf("/spec/hostAliases/%d/ip", i),
			Value: StreamStoreHostIP,
		}}
	}
	// No existing alias for the streamstore — add one.
	if len(pod.Spec.HostAliases) == 0 {
		return []Op{{Op: "add", Path: "/spec/hostAliases", Value: []corev1.HostAlias{wantAlias}}}
	}
	return []Op{{Op: "add", Path: "/spec/hostAliases/-", Value: wantAlias}}
}

// aliasMatchesStreamstore reports whether any hostname in the alias is
// one of the streamstore names we care about — substring "tawon-streamstore"
// or the literal short name "nats".
func aliasMatchesStreamstore(ha corev1.HostAlias) bool {
	for _, h := range ha.Hostnames {
		if h == "nats" || strings.Contains(h, "tawon-streamstore") {
			return true
		}
	}
	return false
}

// Op is one JSONPatch (RFC 6902) operation. Encoded as JSON for the
// admission response.
type Op struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value,omitempty"`
}

// Marshal serializes a list of ops as a JSONPatch document.
func Marshal(ops []Op) ([]byte, error) {
	if len(ops) == 0 {
		return nil, nil
	}
	b, err := json.Marshal(ops)
	if err != nil {
		return nil, fmt.Errorf("inject: marshal patch: %w", err)
	}
	return b, nil
}
