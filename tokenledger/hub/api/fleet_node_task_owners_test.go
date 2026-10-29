package api

import (
	"net/http"
	"testing"
)

// J7BN: an admin's task started from their admin login has owner "operator";
// the hub may place it on another login of the same person (nodePrincipal),
// whose own owner is that person. That login reads the record and its
// execution start; another person's login, and a non-admin person's own
// login, still get 404 for the operator's task.
func TestNodeTaskOwnersAdminPersonReadsOperatorTask(t *testing.T) {
	h, _, task, _ := sessionExitFixture(t)
	if task.Owner != "operator" {
		t.Fatalf("fixture task owner %q; want operator", task.Owner)
	}
	// From here frank is no admin login: mac-c's frank is pBob's managed
	// account (the person's pod); mac-d's frank is nobody's — another owner.
	h.srv.FleetAdmins = []string{"root-admin"}
	for _, a := range []FleetAccountRequest{
		{Action: "adopt", PrincipalID: pBob, Hostname: "mac-c", Login: "frank"},
	} {
		if code := operatorPost(t, h, a); code != 200 {
			t.Fatalf("adopt %v: HTTP %d", a, code)
		}
	}
	podTok, otherTok := h.tokens["mac-c"], h.tokens["mac-d"]
	record := NodeTasksPath + "/" + task.Ref
	start := record + "/execution/start"

	// pBob is no admin: his pod's login does not answer "operator".
	if st, out := nodeTaskCall(t, h, podTok, http.MethodGet, record, nil); st != 404 {
		t.Fatalf("non-admin person reads the operator's task: %d %v", st, out)
	}
	if st, out := nodeTaskCall(t, h, podTok, http.MethodGet, start, nil); st != 404 {
		t.Fatalf("non-admin person reads the operator's start: %d %v", st, out)
	}

	// pBob is a hub admin: the operator's task is his.
	h.srv.Admins = []string{pBob}
	st, out := nodeTaskCall(t, h, podTok, http.MethodGet, record, nil)
	if st != 200 || out["task"].(map[string]any)["owner"] != "operator" {
		t.Fatalf("admin's pod reads the operator's task: %d %v", st, out)
	}
	if st, out := nodeTaskCall(t, h, podTok, http.MethodGet, start, nil); st != 200 || out["task_execution"] == nil {
		t.Fatalf("admin's pod reads the execution start: %d %v", st, out)
	}
	if st, out := nodeTaskCall(t, h, podTok, http.MethodGet, record+"/execution", nil); st != 200 {
		t.Fatalf("admin's pod reads the execution: %d %v", st, out)
	}
	if st, out := nodeTaskCall(t, h, podTok, http.MethodGet, NodeTasksPath+"/executions", nil); st != 200 || len(out["task_executions"].([]any)) != 1 {
		t.Fatalf("admin's pod lists its executions: %d %v", st, out)
	}

	// Another owner's login (not an admin, not pBob's) never reads it.
	if st, out := nodeTaskCall(t, h, otherTok, http.MethodGet, record, nil); st != 404 {
		t.Fatalf("another person reads the operator's task: %d %v", st, out)
	}

	// A record the admin's pod creates is still the person's own.
	st, rec := nodeTaskCall(t, h, podTok, http.MethodPost, NodeTasksPath, map[string]any{"token": "j7bn:1", "title": "own"})
	if st != 200 || rec["owner"] != pBob {
		t.Fatalf("create = %d %v; want owner %s", st, rec, pBob)
	}
	// And another person's login never reads the admin person's record.
	if st, out := nodeTaskCall(t, h, otherTok, http.MethodGet, NodeTasksPath+"/"+rec["id"].(string), nil); st != 404 {
		t.Fatalf("another person reads the admin person's task: %d %v", st, out)
	}
}
