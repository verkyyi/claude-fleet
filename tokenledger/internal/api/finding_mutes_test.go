package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// post is the harness's counterpart to get/getJSON, for the hub's one new
// viewer-facing write.
func (h *harness) post(t *testing.T, path string, body any) (int, map[string]any) {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	req.Header.Set("Content-Type", "application/json")
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

type mutableFinding struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	Severity string `json:"severity"`
	Title    string `json:"title"`
	Muted    *struct {
		Until time.Time `json:"until"`
		Note  string    `json:"note"`
		By    string    `json:"by"`
	} `json:"muted"`
}

type mutableEnvelope struct {
	Findings []mutableFinding `json:"findings"`
}

func reviewFindings(t *testing.T, h *harness) []mutableFinding {
	t.Helper()
	var env mutableEnvelope
	h.getJSON(t, "/v1/findings?account=all&since=2026-08-31T12:00:00Z&until=2026-08-31T15:00:00Z", &env)
	return env.Findings
}

// The whole feature, end to end: a finding has a name, the name survives a
// second read, muting it by that name takes effect, and the finding is STILL
// THERE -- marked, not deleted.
func TestFindingMutes_EndToEnd(t *testing.T) {
	h := newHarness(t)
	seedReviewHarness(t, h)

	first := reviewFindings(t, h)
	if len(first) == 0 {
		t.Fatal("the seeded harness produced no findings to mute")
	}
	target := first[0]
	if target.ID == "" {
		t.Fatal("findings still have no id on the wire")
	}

	// The id is stable across a recomputation over HTTP, not only inside the
	// findings package: this is the property the mute actually depends on.
	second := reviewFindings(t, h)
	if second[0].ID != target.ID {
		t.Fatalf("id moved between two identical requests: %q -> %q", target.ID, second[0].ID)
	}
	if second[0].Muted != nil {
		t.Fatal("a finding nobody muted came back muted")
	}

	code, body := h.post(t, "/v1/findings/mutes", map[string]any{
		"id": target.ID, "kind": target.Kind, "note": "known, chasing it", "hours": 6,
	})
	if code != http.StatusOK {
		t.Fatalf("mute: HTTP %d (%v)", code, body)
	}
	if body["muted"] != true {
		t.Errorf("mute response = %v", body)
	}

	after := reviewFindings(t, h)
	var found *mutableFinding
	for i := range after {
		if after[i].ID == target.ID {
			found = &after[i]
		}
	}
	if found == nil {
		t.Fatalf("the muted finding disappeared from the response entirely; a mute must not delete an alert")
	}
	if found.Muted == nil {
		t.Fatal("the finding came back without its mute")
	}
	if found.Muted.Note != "known, chasing it" {
		t.Errorf("note = %q", found.Muted.Note)
	}
	// Last, after every live finding: silenced, not gone, and not sitting in
	// the middle of the card looking urgent.
	if after[len(after)-1].ID != target.ID {
		t.Errorf("muted finding is not ranked last: %q is", after[len(after)-1].Title)
	}

	// And it comes back when the silence is lifted.
	if code, body := h.post(t, "/v1/findings/mutes", map[string]any{"id": target.ID, "action": "unmute"}); code != http.StatusOK || body["was_muted"] != true {
		t.Fatalf("unmute: HTTP %d (%v)", code, body)
	}
	for _, f := range reviewFindings(t, h) {
		if f.ID == target.ID && f.Muted != nil {
			t.Error("the finding is still muted after being unmuted")
		}
	}
}

// The roster answers "what have we silenced", including the rows the read path
// deliberately ignores -- an expired mute that is no longer in force is still
// something the operator did, and hiding it would make them doubt they did it.
func TestFindingMutes_Roster(t *testing.T) {
	h := newHarness(t)
	if code, _ := h.post(t, "/v1/findings/mutes", map[string]any{"id": "abc123", "kind": "stale_agent"}); code != http.StatusOK {
		t.Fatalf("mute: HTTP %d", code)
	}
	var got struct {
		Mutes []struct {
			FindingID string `json:"finding_id"`
			Kind      string `json:"kind"`
			Active    bool   `json:"active"`
		} `json:"mutes"`
	}
	h.getJSON(t, "/v1/findings/mutes", &got)
	if len(got.Mutes) != 1 || got.Mutes[0].FindingID != "abc123" || !got.Mutes[0].Active {
		t.Fatalf("roster = %+v", got.Mutes)
	}
	if got.Mutes[0].Kind != "stale_agent" {
		t.Errorf("kind = %q; the roster needs something a human can read", got.Mutes[0].Kind)
	}
}

func TestFindingMutes_RejectsBadRequests(t *testing.T) {
	h := newHarness(t)
	if code, _ := h.post(t, "/v1/findings/mutes", map[string]any{"id": "   "}); code != http.StatusBadRequest {
		t.Errorf("empty id: HTTP %d, want 400", code)
	}
	req, _ := http.NewRequest(http.MethodDelete, h.http.URL+"/v1/findings/mutes", nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("DELETE: HTTP %d, want 405", res.StatusCode)
	}
}

// The trust boundary, asserted rather than described. This is the hub's SECOND
// viewer-facing write, and the point of the design note in finding_mutes.go is
// that it did not widen anything: an endpoint's ingest token must not reach
// it, and an unauthenticated caller must not either.
//
// The stale-agent alert is why this matters more than it sounds: a machine
// that could silence the alarm about its own silence is a machine that can
// disappear unnoticed.
func TestFindingMutes_NotReachableByAnEndpointToken(t *testing.T) {
	h := newHarness(t)
	ingest := h.enroll(t, "mac")

	for _, tc := range []struct{ name, auth string }{
		{"endpoint ingest token", "Bearer " + ingest},
		{"no credential", ""},
		{"wrong token", "Bearer nope"},
	} {
		body, _ := json.Marshal(map[string]any{"id": "abc123"})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/findings/mutes", bytes.NewReader(body))
		if tc.auth != "" {
			req.Header.Set("Authorization", tc.auth)
		}
		res, err := h.http.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d, want 401", tc.name, res.StatusCode)
		}
	}
	// Nothing was written by any of them.
	all, err := h.srv.Store.AllFindingMutes()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 0 {
		t.Fatalf("a refused request still wrote a mute: %+v", all)
	}
}
