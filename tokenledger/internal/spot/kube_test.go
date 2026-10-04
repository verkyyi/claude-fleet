package spot

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/spot/spottest"
)

func testClient(t *testing.T, srv *spottest.Server) *Client {
	t.Helper()
	c, err := New(Config{APIServer: srv.URL, Token: "t", Namespace: "ns"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// The four verbs against the fake, including the two "already gone" answers
// the controller relies on: a 404 on get is (found=false, nil), on delete
// likewise.
func TestClientPodLifecycle(t *testing.T) {
	srv := spottest.New()
	defer srv.Close()
	c := testClient(t, srv)
	ctx := context.Background()

	pod := BuildPod(PodInput{Name: "ccquota-spot-x", Image: "img:1", Labels: map[string]string{"app": "ccquota-spot-node"},
		Env: map[string]string{"B": "2", "A": "1"}, GraceSeconds: 300})
	created, err := c.CreatePod(ctx, pod)
	if err != nil || created.Name != "ccquota-spot-x" || created.Phase != "Pending" {
		t.Fatalf("create: %+v %v", created, err)
	}
	if _, err := c.CreatePod(ctx, pod); err == nil || !strings.Contains(err.Error(), "409") {
		t.Fatalf("duplicate create: %v, want a 409", err)
	}
	got, found, err := c.GetPod(ctx, "ccquota-spot-x")
	if err != nil || !found || got.Phase != "Pending" {
		t.Fatalf("get: %+v %v %v", got, found, err)
	}
	srv.SetPhase("ccquota-spot-x", "Failed")
	if got, _, _ = c.GetPod(ctx, "ccquota-spot-x"); !got.Gone() {
		t.Fatalf("a Failed pod must read as gone: %+v", got)
	}
	pods, err := c.ListPods(ctx, "app=ccquota-spot-node")
	if err != nil || len(pods) != 1 {
		t.Fatalf("list: %v %v", pods, err)
	}
	if pods, _ = c.ListPods(ctx, "app=other"); len(pods) != 0 {
		t.Fatalf("list with a non-matching selector: %v", pods)
	}
	if found, err := c.DeletePod(ctx, "ccquota-spot-x", 30); err != nil || !found {
		t.Fatalf("delete: %v %v", found, err)
	}
	if _, found, err := c.GetPod(ctx, "ccquota-spot-x"); err != nil || found {
		t.Fatalf("get after delete: found=%v err=%v, want absent and no error", found, err)
	}
	if found, err := c.DeletePod(ctx, "ccquota-spot-x", 30); err != nil || found {
		t.Fatalf("delete of an absent pod: found=%v err=%v, want (false, nil)", found, err)
	}
	if srv.Created != 1 || len(srv.Deleted) != 1 {
		t.Fatalf("fake counted created=%d deleted=%v", srv.Created, srv.Deleted)
	}
}

// An API server that refuses is an error, never a silent "not found".
func TestClientRefusalIsAnError(t *testing.T) {
	srv := spottest.New()
	defer srv.Close()
	c := testClient(t, srv)
	srv.Refuse = 503
	if _, found, err := c.GetPod(context.Background(), "x"); err == nil || found || IsNotFound(err) {
		t.Fatalf("get under a 503: found=%v err=%v", found, err)
	}
}

// A client needs an address and a credential; it says so up front.
func TestNewRefusesAnUnusableConfig(t *testing.T) {
	t.Setenv("KUBERNETES_SERVICE_HOST", "")
	if _, err := New(Config{}); err == nil || !strings.Contains(err.Error(), "not in a cluster") {
		t.Fatalf("New with nothing: %v", err)
	}
	if _, err := New(Config{APIServer: "http://127.0.0.1:1", TokenFile: "/nonexistent/token"}); err == nil || !strings.Contains(err.Error(), "no credential") {
		t.Fatalf("New with a missing token file: %v", err)
	}
	if InCluster() {
		t.Fatal("InCluster() with KUBERNETES_SERVICE_HOST unset")
	}
}

// The generated Pod: restartPolicy Never (a node is never restarted in
// place — the hub starts a fresh one), the grace, env in a stable order, the
// selector and tolerations only when given, and the overlay merged last.
func TestBuildPod(t *testing.T) {
	tol, err := ParseTolerations("spot=true:NoSchedule,kubernetes.io/spot:NoExecute")
	if err != nil {
		t.Fatal(err)
	}
	sel, err := ParseSelector("node.kubernetes.io/instance-type=spot, zone=a")
	if err != nil {
		t.Fatal(err)
	}
	pod := BuildPod(PodInput{Name: "p", Image: "img", Env: map[string]string{"Z": "1", "A": "2"},
		NodeSelector: sel, Tolerations: tol, GraceSeconds: 120, CPU: "500m", Memory: "4Gi",
		ServiceAccount: "sa", PullSecret: "reg",
		Overlay: map[string]any{"spec": map[string]any{"runtimeClassName": "gvisor", "terminationGracePeriodSeconds": float64(90)}}})
	raw, _ := json.Marshal(pod)
	js := string(raw)
	for _, want := range []string{
		`"restartPolicy":"Never"`,
		`"terminationGracePeriodSeconds":90`, // the overlay won
		`"runtimeClassName":"gvisor"`,
		`"nodeSelector":{"node.kubernetes.io/instance-type":"spot","zone":"a"}`,
		`{"effect":"NoSchedule","key":"spot","operator":"Equal","value":"true"}`,
		`{"effect":"NoExecute","key":"kubernetes.io/spot","operator":"Exists"}`,
		`"env":[{"name":"A","value":"2"},{"name":"Z","value":"1"}]`,
		`"requests":{"cpu":"500m","memory":"4Gi"}`,
		`"serviceAccountName":"sa"`,
		`"imagePullSecrets":[{"name":"reg"}]`,
	} {
		if !strings.Contains(js, want) {
			t.Errorf("pod lacks %s:\n%s", want, js)
		}
	}
	// Nothing optional leaks into a minimal pod.
	raw, _ = json.Marshal(BuildPod(PodInput{Name: "p", Image: "img", GraceSeconds: 1}))
	for _, no := range []string{"nodeSelector", "tolerations", "resources", "serviceAccountName", "imagePullSecrets"} {
		if strings.Contains(string(raw), no) {
			t.Errorf("minimal pod carries %s: %s", no, raw)
		}
	}
}

func TestParsers(t *testing.T) {
	if tol, err := ParseTolerations(`[{"key":"k","operator":"Exists"}]`); err != nil || len(tol) != 1 || tol[0]["key"] != "k" {
		t.Fatalf("JSON tolerations: %v %v", tol, err)
	}
	if _, err := ParseTolerations(`[not json`); err == nil {
		t.Fatal("bad JSON tolerations accepted")
	}
	if tol, err := ParseTolerations(""); err != nil || tol != nil {
		t.Fatalf("empty tolerations: %v %v", tol, err)
	}
	if _, err := ParseSelector("novalue"); err == nil {
		t.Fatal("selector without = accepted")
	}
	for _, ok := range []string{"", "500m", "2", "4Gi", "1.5"} {
		if err := Quantity(ok); err != nil {
			t.Errorf("Quantity(%q): %v", ok, err)
		}
	}
	for _, bad := range []string{"lots", "Gi", "4 Gi"} {
		if err := Quantity(bad); err == nil {
			t.Errorf("Quantity(%q) accepted", bad)
		}
	}
}
