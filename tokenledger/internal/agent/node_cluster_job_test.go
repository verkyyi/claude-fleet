package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// fleet-ops reads a throwaway Job back as its own read-only account
// (claude-fleet#3552): the state off the Job's status, the log after the asked
// offset, and nothing at all for a Job that is not the asking pod's.
func TestClusterJobReadsItsOwnersJob(t *testing.T) {
	const jobLog = "::fleet-job:: run test: make test\nok\n::fleet-job:: exit 0\n"
	var auth string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		switch r.URL.Path {
		case "/apis/batch/v1/namespaces/fleet-workers/jobs/job-aaaaaaaaaaaa":
			w.Write([]byte(`{"metadata":{"labels":{"fleet/role":"job","fleet/owner":"u-mine1"}},
				"status":{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}`))
		case "/apis/batch/v1/namespaces/fleet-workers/jobs/job-bbbbbbbbbbbb":
			w.Write([]byte(`{"metadata":{"labels":{"fleet/role":"job","fleet/owner":"u-other1"}},"status":{"active":1}}`))
		case "/apis/batch/v1/namespaces/fleet-workers/jobs/job-cccccccccccc":
			w.Write([]byte(`{"metadata":{"labels":{"fleet/role":"job","fleet/owner":"u-mine1"}},
				"status":{"failed":1,"conditions":[{"type":"Failed","status":"True","reason":"DeadlineExceeded"}]}}`))
		case "/api/v1/namespaces/fleet-workers/pods":
			if r.URL.Query().Get("labelSelector") != "job-name=job-aaaaaaaaaaaa" {
				w.Write([]byte(`{"items":[]}`))
				return
			}
			w.Write([]byte(`{"items":[{"metadata":{"name":"job-aaaaaaaaaaaa-x1"}}]}`))
		case "/api/v1/namespaces/fleet-workers/pods/job-aaaaaaaaaaaa-x1/log":
			n, _ := strconv.Atoi(r.URL.Query().Get("limitBytes"))
			if n > len(jobLog) {
				n = len(jobLog)
			}
			fmt.Fprint(w, jobLog[:n])
		default:
			http.NotFound(w, r)
		}
	}))
	defer api.Close()
	sa := t.TempDir()
	os.WriteFile(filepath.Join(sa, "token"), []byte("ops-token\n"), 0o600)
	os.WriteFile(filepath.Join(sa, "namespace"), []byte("fleet-workers"), 0o600)
	a := &Agent{cfg: Config{FleetClusterOps: "http://prov", FleetKubeAPI: api.URL, FleetKubeSADir: sa}, http: api.Client()}
	ask := func(a *Agent, req control.ClusterJob) (control.Message, control.ClusterJobResult) {
		t.Helper()
		l := &recLink{}
		m, _ := control.New(control.TypeClusterJob, req)
		a.answerClusterJob(context.Background(), l, m)
		if len(l.out) != 1 || l.out[0].OpID != m.OpID {
			t.Fatalf("answers = %+v; want one, by op_id", l.out)
		}
		var res control.ClusterJobResult
		_ = json.Unmarshal(l.out[0].Payload, &res)
		return l.out[0], res
	}
	_, res := ask(a, control.ClusterJob{Job: "job-aaaaaaaaaaaa", Owner: "u-mine1"})
	if res.State != control.JobSucceeded || res.Log != jobLog || res.Offset != int64(len(jobLog)) || auth != "Bearer ops-token" {
		t.Fatalf("own job = %+v (auth %q)", res, auth)
	}
	_, res = ask(a, control.ClusterJob{Job: "job-aaaaaaaaaaaa", Owner: "u-mine1", Offset: 10})
	if res.Log != jobLog[10:] || res.Offset != int64(len(jobLog)) {
		t.Fatalf("from 10 = %+v", res)
	}
	_, res = ask(a, control.ClusterJob{Job: "job-cccccccccccc", Owner: "u-mine1"})
	if res.State != control.JobFailed || res.Reason != "DeadlineExceeded" || res.Log != "" {
		t.Fatalf("deadline = %+v", res)
	}
	if _, res = ask(a, control.ClusterJob{Job: "job-dddddddddddd", Owner: "u-mine1"}); res.State != control.JobGone {
		t.Fatalf("never made = %+v; want gone", res)
	}
	if m, _ := ask(a, control.ClusterJob{Job: "job-bbbbbbbbbbbb", Owner: "u-mine1"}); m.Type != control.TypeError ||
		m.Error.Code != control.CodeNoSuchJob {
		t.Fatalf("another pod's job = %+v; want NO_SUCH_JOB", m)
	}
	for _, bad := range []control.ClusterJob{{Job: "../pods", Owner: "u-mine1"}, {Job: "job-aaaaaaaaaaaa", Owner: "root"},
		{Job: "job-aaaaaaaaaaaa", Owner: "u-mine1", Offset: -1}} {
		if m, _ := ask(a, bad); m.Type != control.TypeError || m.Error.Code != control.CodeBadArgs {
			t.Fatalf("%+v = %+v; want BAD_ARGS", bad, m)
		}
	}
	if m, _ := ask(&Agent{cfg: Config{}, http: api.Client()}, control.ClusterJob{Job: "job-aaaaaaaaaaaa", Owner: "u-mine1"}); m.Type != control.TypeError {
		t.Fatalf("no ops link: %+v; want a refusal", m)
	}
}
