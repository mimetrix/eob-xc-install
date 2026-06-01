package inject

import (
	"encoding/json"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func pod(name, ksLabel string, hostNet bool, dnsPolicy corev1.DNSPolicy) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:   name,
			Labels: map[string]string{"app.kubernetes.io/name": ksLabel},
		},
		Spec: corev1.PodSpec{
			HostNetwork: hostNet,
			DNSPolicy:   dnsPolicy,
		},
	}
}

func TestMatch(t *testing.T) {
	t.Parallel()
	cases := []struct {
		label string
		want  bool
	}{
		{"tawon-streamstore-d2f18e", true},
		{"tawon-streamstore-abc123", true},
		{"tawon-streamstore", true}, // prefix match still applies
		{"tawon-directive", true},
		{"tawon-dashboard", true},
		{"tawon-operator", false},
		{"tawon-something-else", false},
		{"", false},
		{"unrelated-app", false},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			got := Match(pod("p", c.label, false, corev1.DNSClusterFirst))
			if got != c.want {
				t.Errorf("Match(%q) = %v, want %v", c.label, got, c.want)
			}
		})
	}
}

func TestPatch_AddsBothFieldsWhenMissing(t *testing.T) {
	t.Parallel()
	p := pod("tawon-streamstore-0", "tawon-streamstore-d2f18e", false, corev1.DNSClusterFirst)
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 2 {
		t.Fatalf("ops: got %d, want 2", len(ops))
	}
	if ops[0].Path != "/spec/hostNetwork" || ops[0].Value != true {
		t.Errorf("hostNetwork op: %+v", ops[0])
	}
	if ops[1].Path != "/spec/dnsPolicy" || ops[1].Value != "ClusterFirstWithHostNet" {
		t.Errorf("dnsPolicy op: %+v", ops[1])
	}
}

func TestPatch_OmitsAlreadyCorrectFields(t *testing.T) {
	t.Parallel()
	p := pod("tawon-streamstore-0", "tawon-streamstore-d2f18e", true, corev1.DNSClusterFirstWithHostNet)
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 0 {
		t.Errorf("ops: got %d, want 0 (pod already correct)", len(ops))
	}
}

func TestPatch_PartialAlreadySet_Streamstore(t *testing.T) {
	t.Parallel()
	// streamstore pod: hostNetwork already true, DNS policy already
	// correct → no host-network ops; no hostAliases needed (streamstore
	// is the SERVER, not a client).
	p := pod("tawon-streamstore-0", "tawon-streamstore-d2f18e", true, corev1.DNSClusterFirstWithHostNet)
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 0 {
		t.Errorf("ops: got %d, want 0 (streamstore already correct, no aliases needed)", len(ops))
	}
}

func TestPatch_DirectiveGetsHostAliases(t *testing.T) {
	t.Parallel()
	// Directive agent: needs hostNetwork + dnsPolicy + hostAliases.
	p := pod("tawon-directive-foo", "tawon-directive", false, corev1.DNSClusterFirst)
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 3 {
		t.Fatalf("ops: got %d, want 3", len(ops))
	}
	if ops[2].Path != "/spec/hostAliases" {
		t.Errorf("expected hostAliases op at index 2, got %+v", ops[2])
	}
	aliases, ok := ops[2].Value.([]corev1.HostAlias)
	if !ok || len(aliases) != 1 {
		t.Fatalf("hostAliases value: got %T %v", ops[2].Value, ops[2].Value)
	}
	if aliases[0].IP != StreamStoreHostIP {
		t.Errorf("alias IP: got %q, want %q", aliases[0].IP, StreamStoreHostIP)
	}
}

func TestPatch_DirectiveAliasIPGetsCorrected(t *testing.T) {
	t.Parallel()
	// Operator pre-injected a hostAlias for the streamstore but with a
	// stale IP (this happens on srikan-tf-test-0: 10.3.38.189). The
	// webhook should REPLACE the IP, not add a duplicate.
	p := pod("tawon-directive-foo", "tawon-directive", true, corev1.DNSClusterFirstWithHostNet)
	p.Spec.HostAliases = []corev1.HostAlias{
		{IP: "10.3.38.189", Hostnames: []string{"nats", "tawon-streamstore-d2f18e.tawon-operator.svc.cluster.local"}},
	}
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 1 {
		t.Fatalf("ops: got %d, want 1 (only IP replace)", len(ops))
	}
	if ops[0].Op != "replace" || ops[0].Path != "/spec/hostAliases/0/ip" {
		t.Errorf("expected /spec/hostAliases/0/ip replace, got %+v", ops[0])
	}
	if ops[0].Value != StreamStoreHostIP {
		t.Errorf("value: got %v, want %s", ops[0].Value, StreamStoreHostIP)
	}
}

func TestPatch_DirectiveAliasAlreadyCorrect(t *testing.T) {
	t.Parallel()
	p := pod("tawon-directive-foo", "tawon-directive", true, corev1.DNSClusterFirstWithHostNet)
	p.Spec.HostAliases = []corev1.HostAlias{
		{IP: StreamStoreHostIP, Hostnames: []string{"nats"}},
	}
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if len(ops) != 0 {
		t.Errorf("ops: got %d, want 0 (already correct)", len(ops))
	}
}

func TestPatch_SkipsNonMatching(t *testing.T) {
	t.Parallel()
	p := pod("unrelated", "kube-rbac-proxy", false, corev1.DNSClusterFirst)
	ops, err := Patch(p)
	if err != nil {
		t.Fatalf("Patch: %v", err)
	}
	if ops != nil {
		t.Errorf("ops: got %+v, want nil", ops)
	}
}

func TestMarshal_RoundTrip(t *testing.T) {
	t.Parallel()
	ops := []Op{
		{Op: "add", Path: "/spec/hostNetwork", Value: true},
		{Op: "replace", Path: "/spec/dnsPolicy", Value: "ClusterFirstWithHostNet"},
	}
	body, err := Marshal(ops)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var got []map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got) != 2 || got[0]["op"] != "add" || got[1]["op"] != "replace" {
		t.Errorf("round-trip shape: %v", got)
	}
}

func TestMarshal_EmptyReturnsNil(t *testing.T) {
	t.Parallel()
	body, err := Marshal(nil)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if body != nil {
		t.Errorf("expected nil for empty ops, got %s", body)
	}
}
