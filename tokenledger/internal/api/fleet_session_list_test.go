package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 我的会话 (claude-fleet#3927): /v1/fleet/sessions lists the viewer's own
// live sessions, and ?state=ended their own reaped ones of the last 14 days —
// never another person's, never one that is live again, never an older one.

func sessionList(t *testing.T, h *harness, who, query string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+FleetSessionListPath+query, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	if who != "" {
		req.Header.Set("X-Test-Principal", who)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestFleetSessionListOwnLiveAndEnded(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.fleetScopeHook = func(r *http.Request) (func(string, string) bool, error) {
		switch r.Header.Get("X-Test-Principal") {
		case "":
			return nil, nil
		case "alice":
			return func(host, user string) bool { return host == "mac-d" && user == "alice" }, nil
		case "bob":
			return func(host, user string) bool { return host == "mac-c" && user == "bob" }, nil
		}
		return func(string, string) bool { return false }, nil
	}
	a := connectFakeNode(t, h, "mac-d", false)
	b := connectFakeNode(t, h, "mac-c", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 2)
	a.beat("mac-d", "alice", machineA, fa)
	b.beat("mac-c", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})

	now := time.Now()
	row := func(at time.Time, key, title string) []byte {
		return []byte(at.UTC().Format(time.RFC3339) + "\t" + key + "\t" + title + "\t-\t-\t-\t-\t-\t-\tclosed\t-\n")
	}
	rec := func(fid, key, title string, at time.Time) store.FleetWorkerRecord {
		return store.FleetWorkerRecord{ID: fid + key, WorkerID: fid + "/" + key, FleetID: fid, Owner: "endpoint:x",
			Repo: "o/r", Key: key, Kind: "history", Name: "ledger", Stage: "closed",
			Content: row(at, key, title), CreatedAt: at}
	}
	if err := h.srv.Store.PutWorkerRecords([]store.FleetWorkerRecord{
		rec(fa.FleetID, "issue-41", "报名页", now.Add(-2*time.Hour)),
		rec(fa.FleetID, "issue-40", "旧事", now.Add(-20*24*time.Hour)), // past the window
		rec(fa.FleetID, "issue-1", "又接回了", now.Add(-time.Hour)),      // live again
		rec(fb.FleetID, "issue-42", "bob 的", now.Add(-time.Hour)),
	}); err != nil {
		t.Fatal(err)
	}

	// Live: alice sees her one session, not bob's.
	code, out := sessionList(t, h, "alice", "")
	if code != 200 || out["count"].(float64) != 1 {
		t.Fatalf("alice live: HTTP %d %v; want her one session", code, out)
	}
	if s := out["sessions"].([]any)[0].(map[string]any); s["machine_name"] != "mac-d" {
		t.Fatalf("alice live row = %v", s)
	}

	// Ended: hers, in the window, not live again.
	code, out = sessionList(t, h, "alice", "?state=ended")
	if code != 200 {
		t.Fatalf("alice ended: HTTP %d %v", code, out)
	}
	ended := out["sessions"].([]any)
	if len(ended) != 1 {
		t.Fatalf("alice ended = %v; want issue-41 only", ended)
	}
	e := ended[0].(map[string]any)
	if e["key"] != "issue-41" || e["title"] != "报名页" || e["machine_name"] != "mac-d" ||
		e["resume_id"] != fa.FleetID+"/issue-41" || e["state"] != "closed" {
		t.Fatalf("alice ended row = %v", e)
	}

	// Bob reads his own and nothing of alice's; a stranger, nothing.
	if _, out = sessionList(t, h, "bob", "?state=ended"); len(out["sessions"].([]any)) != 1 ||
		out["sessions"].([]any)[0].(map[string]any)["key"] != "issue-42" {
		t.Fatalf("bob ended = %v; want issue-42 only", out["sessions"])
	}
	if _, out = sessionList(t, h, "stranger", "?state=ended"); len(out["sessions"].([]any)) != 0 {
		t.Fatalf("a stranger's ended = %v; want none", out["sessions"])
	}
	if code, _ = sessionList(t, h, "alice", "?state=bogus"); code != http.StatusBadRequest {
		t.Fatalf("a bad state: HTTP %d; want 400", code)
	}
}
