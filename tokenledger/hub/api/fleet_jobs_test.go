package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// claude-fleet#3552 (EPIC #3500 C7): a session in a person's pod hands a run to
// a throwaway Job. The hub signs the create-job ticket for the CALLER's own pod
// (never one it names), carries it down the ops link, audits it, and reads the
// Job back only as that pod's.

// jobCall is one /v1/node/jobs request with label's node token.
func jobCall(t *testing.T, h *harness, label, method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	req.Header.Set("Authorization", "Bearer "+h.tokens[label])
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

// livePod is one spare pod made through the ops link and live, with its node's
// token enrolled under the pod's name.
func livePod(t *testing.T, h *harness, ops *fakeOps) string {
	t.Helper()
	setHubSetting(t, h.srv, SpareMaxPrefix+testCluster, "1")
	h.srv.replenishSpares(time.Now(), true)
	tk := ops.expect(control.ClusterCreateUserPod)
	waitPodState(t, h, tk.Pod, store.PodLive)
	h.enroll(t, tk.Pod)
	identify(t, h, tk.Pod, tk.Pod, "root")
	return tk.Pod
}

func TestJobRunsForTheCallersOwnPod(t *testing.T) {
	h, ops := podRig(t)
	pod := livePod(t, h, ops)
	ref := strings.Repeat("b", 40)
	st, out := jobCall(t, h, pod, http.MethodPost, NodeJobsPath,
		jobCreate{Repo: "o/r", Ref: ref, Kind: "untrusted", Cmd: "make test"})
	if st != 200 {
		t.Fatalf("create: HTTP %d %v", st, out)
	}
	tk := ops.expect(control.ClusterCreateJob)
	job, _ := out["job"].(string)
	if tk.Pod != pod || tk.Repo != "o/r" || tk.Ref != ref || tk.Kind != "untrusted" || tk.Cmd != "make test" ||
		job != "job-"+tk.Nonce[:12] || out["cluster"] != testCluster {
		t.Fatalf("ticket %+v answer %v; want the caller's pod, its kind and command, the Job named by the nonce", tk, out)
	}
	if a := audits(t, h, "job.create"); len(a) != 1 || a[0].Outcome != "ok" || a[0].Target != job ||
		!strings.Contains(a[0].Detail, pod) {
		t.Fatalf("job.create audit = %+v", a)
	}
	st, out = jobCall(t, h, pod, http.MethodGet, NodeJobsPath+"/"+job, nil)
	if st != 200 || out["state"] != control.JobSucceeded || out["log"] != fakeJobLog || out["offset"] != float64(len(fakeJobLog)) {
		t.Fatalf("read: HTTP %d %v", st, out)
	}
	st, out = jobCall(t, h, pod, http.MethodGet, NodeJobsPath+"/"+job+"?offset=6", nil)
	if st != 200 || out["log"] != fakeJobLog[6:] {
		t.Fatalf("read from 6: HTTP %d %v", st, out)
	}
	// Another pod's Job is no such job; one never made is gone.
	ops.mu.Lock()
	ops.jobs["job-0123456789ab"] = "u-someoneelse"
	ops.mu.Unlock()
	if st, out := jobCall(t, h, pod, http.MethodGet, NodeJobsPath+"/job-0123456789ab", nil); st != 404 {
		t.Fatalf("another pod's job: HTTP %d %v; want 404", st, out)
	}
	if st, out := jobCall(t, h, pod, http.MethodGet, NodeJobsPath+"/job-aaaaaaaaaaaa", nil); st != 200 || out["state"] != control.JobGone {
		t.Fatalf("a job never made: HTTP %d %v; want gone", st, out)
	}
	// Off its grammar: refused before anything is signed.
	for _, bad := range []jobCreate{
		{Repo: "o/r", Ref: ref, Kind: "root", Cmd: "x"},
		{Repo: "o/r", Ref: "main", Kind: "test", Cmd: "x"},
		{Repo: "o/r", Ref: ref, Kind: "test", Cmd: "a\nb"},
		{Repo: "../x", Ref: ref, Kind: "test", Cmd: "x"},
	} {
		if st, _ := jobCall(t, h, pod, http.MethodPost, NodeJobsPath, bad); st != 400 {
			t.Fatalf("%+v: HTTP %d; want 400", bad, st)
		}
	}
	ops.quiet(200 * time.Millisecond)
}

// A node that is no live pod of a cluster — a Mac, or any pod with no account
// key here — is refused, and nothing is signed or sent.
func TestJobRefusedOffAPod(t *testing.T) {
	h, ops := podRig(t)
	h.enroll(t, "m1")
	identify(t, h, "m1", "m1", "alice")
	body := jobCreate{Repo: "o/r", Ref: strings.Repeat("b", 40), Kind: "test", Cmd: "make test"}
	if st, _ := jobCall(t, h, "m1", http.MethodPost, NodeJobsPath, body); st != 403 {
		t.Fatalf("a machine that is no pod: HTTP %d; want 403", st)
	}
	pod := livePod(t, h, ops)
	h.srv.SetAccountKey(nil)
	if st, _ := jobCall(t, h, pod, http.MethodPost, NodeJobsPath, body); st != 403 {
		t.Fatalf("no account key: HTTP %d; want 403", st)
	}
	ops.quiet(200 * time.Millisecond)
	if a := audits(t, h, "job.create"); len(a) != 0 {
		t.Fatalf("job.create audits = %+v; want none", a)
	}
}
