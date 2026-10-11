package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Pool usage, one request a row, filed under the pass's person
// (claude-fleet#3226, EPIC #3225 C1).

func poolRows(t *testing.T, h *harness, principal string) []store.PoolUsage {
	t.Helper()
	rows, err := h.srv.Store.PoolUsageFor(principal, time.Now().Add(-24*time.Hour), time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// A report with no pass, a pass this hub did not sign, or a pass naming
// another person / session than the report is refused, and writes nothing.
func TestPoolUsageRefusedWithoutItsPass(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	for name, body := range map[string]map[string]any{
		"no pass":           {"principal": "gh:1005", "provider": "claude", "in": 100, "out": 50},
		"forged pass":       {"cred": cred + "x", "principal": "gh:1005", "provider": "claude", "in": 100, "out": 50},
		"another principal": {"cred": cred, "principal": "gh:9999", "worker_id": wid, "provider": "claude", "in": 100, "out": 50},
		"another session":   {"cred": cred, "principal": "gh:1005", "worker_id": "nobody/else", "provider": "claude", "in": 100, "out": 50},
		"another provider":  {"cred": cred + "", "provider": "gemini", "in": 100},
	} {
		st, out := sessDo(t, r.h, http.MethodPost, CredProxyUsagePath, cpToken, "", body)
		if st == http.StatusOK {
			t.Errorf("%s: accepted (%v)", name, out)
		}
		if name != "another provider" && (st != http.StatusForbidden || out["error"] != PoolUsageRefused) {
			t.Errorf("%s: %d %v; want 403 %s", name, st, out, PoolUsageRefused)
		}
	}
	// without the proxy's own token, nothing is even read
	if st, _ := sessDo(t, r.h, http.MethodPost, CredProxyUsagePath, "not-the-token", "", map[string]any{"cred": cred, "provider": "claude", "in": 1}); st != http.StatusUnauthorized {
		t.Errorf("no proxy token → %d", st)
	}
	if rows := poolRows(t, r.h, ""); len(rows) != 0 {
		t.Fatalf("a refused report wrote %d rows: %+v", len(rows), rows)
	}
	// the same report with its own pass and nothing self-reported: one row,
	// the pass's person and session
	st, out := sessDo(t, r.h, http.MethodPost, CredProxyUsagePath, cpToken, "", map[string]any{"cred": cred, "provider": "claude", "in": 100, "out": 50})
	if st != http.StatusOK || out["principal"] != "gh:1005" {
		t.Fatalf("own pass: %d %v", st, out)
	}
	if rows := poolRows(t, r.h, ""); len(rows) != 1 || rows[0].Principal != "gh:1005" || rows[0].WorkerID != wid {
		t.Fatalf("rows = %+v", rows)
	}
}

// A request through the cluster proxy lands as ONE row under the pass's
// person, with the task frozen from the session's lease and the response's
// usage by kind.
func TestPoolUsageOneRowPerRequestWithItsLease(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	now := time.Now()
	if ok, _, _, err := r.h.srv.Store.AcquireLease(store.LeaseClaim{Repo: "verkyyi/claude-fleet", Issue: 3226, WorkerID: wid,
		FleetID: r.f5, EndpointID: "ep-m5", Hostname: "m5", OSUser: "verk"}, time.Hour, now); err != nil || !ok {
		t.Fatalf("lease: %v %v", ok, err)
	}
	for i := 1; i <= 2; i++ {
		if st, body := r.call(t, credvault.Claude, cred); st != 200 {
			t.Fatalf("request %d → %d %s", i, st, body)
		}
		waitFor(t, 3*time.Second, "the request's row", func() bool { return len(poolRows(t, r.h, "gh:1005")) == i })
	}
	rows := poolRows(t, r.h, "gh:1005")
	for _, u := range rows {
		if u.WorkerID != wid || u.Provider != credvault.Claude || u.Model != "claude-opus-5-5" ||
			u.In != 100 || u.CacheRead != 9000 || u.Out != 50 || u.CacheWrite != 0 || u.Requests != 1 ||
			u.Repo != "verkyyi/claude-fleet" || u.Issue != 3226 || u.Account == "" {
			t.Fatalf("row = %+v", u)
		}
	}
	// the budget reads the same rows
	if got := personUsed(t, r.h, "gh:1005"); got != 300 {
		t.Fatalf("used_5h = %v; want 300 (2 × 150)", got)
	}
	// the lease released: the next request is 「没挂在任务上」, still the person's
	if _, err := r.h.srv.Store.ReleaseLease("verkyyi/claude-fleet", 3226, wid); err != nil {
		t.Fatal(err)
	}
	if st, body := r.call(t, credvault.Claude, cred); st != 200 {
		t.Fatalf("after release → %d %s", st, body)
	}
	waitFor(t, 3*time.Second, "the third row", func() bool { return len(poolRows(t, r.h, "gh:1005")) == 3 })
	if u := poolRows(t, r.h, "gh:1005")[2]; u.Repo != "" || u.Issue != 0 || u.Principal != "gh:1005" {
		t.Fatalf("unleased row = %+v", u)
	}
}

// The orchestrator's window holds no lease and its pass is its login's: its
// usage goes to the login's owner, on no task.
func TestPoolUsageOrchestratorToLoginOwner(t *testing.T) {
	r := newCPRig(t)
	c := assertClaims(r.f5, time.Now())
	c.Fid, c.WorkerID, c.Key, c.Repo, c.Issue = fidB, fleetid.WorkerID(r.f5, fidB), "orchestrator", "", ""
	st, out := sessDo(t, r.h, http.MethodPost, "/v1/fleet/session-cred", r.tok5, signWorkerAssertion(c, HashToken(r.tok5)), nil)
	if st != 200 {
		t.Fatalf("issue the orchestrator's pass: %d %v", st, out)
	}
	cred, wid := out["cred"].(string), out["worker_id"].(string)
	if st, body := r.call(t, credvault.Claude, cred); st != 200 {
		t.Fatalf("orchestrator request → %d %s", st, body)
	}
	waitFor(t, 3*time.Second, "the orchestrator's row", func() bool { return len(poolRows(t, r.h, "")) == 1 })
	if u := poolRows(t, r.h, "")[0]; u.Principal != "gh:1005" || u.WorkerID != wid || u.Repo != "" || u.Issue != 0 {
		t.Fatalf("orchestrator row = %+v; want the login owner gh:1005 on no task", u)
	}
}

// The local proxy's aggregate report is the login's person's, in the same
// table — and no row anywhere is ownerless.
func TestPoolUsageNodeReportAndNoOwnerless(t *testing.T) {
	h, tok5, tok4, _, _ := sessHarness(t)
	rep := map[string]any{"usage": []map[string]any{{"provider": "claude", "tokens": 600, "requests": 2}}}
	if st, out := sessDo(t, h, http.MethodPost, "/v1/node/usage", tok5, "", rep); st != 200 || out["used_5h"].(float64) != 600 {
		t.Fatalf("node report: %d %v", st, out)
	}
	// a login with no person: nothing written at all
	if st, _ := sessDo(t, h, http.MethodPost, "/v1/node/usage", tok4, "", rep); st != 200 {
		t.Fatalf("nobody's login: %d", st)
	}
	rows := poolRows(t, h, "")
	if len(rows) != 1 || rows[0].Principal != "gh:1005" || rows[0].In != 600 || rows[0].Requests != 2 {
		t.Fatalf("rows = %+v", rows)
	}
	if err := h.srv.Store.AddPoolUsage(store.PoolUsage{Provider: "claude", In: 1, At: time.Now()}); err != store.ErrPoolUsageNoPrincipal {
		t.Fatalf("an ownerless row: %v; want ErrPoolUsageNoPrincipal", err)
	}
}
