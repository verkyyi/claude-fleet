package api

import (
	"net/http"
	"testing"

	"github.com/verkyyi/ccquota/internal/store"
)

// TestRetiredEndpoint_TokenIsRefusedOnIngest is the issue's point 3: retired
// has to be a revocation, not a label. The push that worked a moment ago must
// stop working.
func TestRetiredEndpoint_TokenIsRefusedOnIngest(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "web-01")

	if resp := h.push(t, tok, batchFor("acct-a", "web-01", []string{"u1"}, "/w")); resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("push before retiring: %d", resp.StatusCode)
	}

	if _, err := h.srv.Store.RetireEndpoint("ep_web-01"); err != nil {
		t.Fatal(err)
	}

	resp := h.push(t, tok, batchFor("acct-a", "web-01", []string{"u2"}, "/w"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a retired endpoint's token must be refused, got %d", resp.StatusCode)
	}
}

// TestEndpoints_HidesRetiredUnlessIncluded covers the read side the dashboard
// toggle sits on.
func TestEndpoints_HidesRetiredUnlessIncluded(t *testing.T) {
	h := newHarness(t)
	for _, label := range []string{"web-01", "web-02"} {
		tok := h.enroll(t, label)
		resp := h.push(t, tok, batchFor("acct-a", label, []string{"u-" + label}, "/w"))
		resp.Body.Close()
	}
	if _, err := h.srv.Store.RetireEndpoint("ep_web-02"); err != nil {
		t.Fatal(err)
	}

	var active []store.Endpoint
	h.getJSON(t, "/v1/endpoints", &active)
	if len(active) != 1 || active[0].ID != "ep_web-01" {
		t.Fatalf("the default roster must omit retired endpoints, got %d: %+v", len(active), active)
	}
	if active[0].RetiredAt != nil {
		t.Fatal("an active endpoint must not carry retired_at")
	}

	var all []store.Endpoint
	h.getJSON(t, "/v1/endpoints?include=retired", &all)
	if len(all) != 2 {
		t.Fatalf("include=retired must show both, got %d", len(all))
	}
	var sawRetired bool
	for _, e := range all {
		if e.ID == "ep_web-02" {
			if e.RetiredAt == nil {
				t.Fatal("a retired endpoint must carry retired_at, " +
					"or the roster cannot tell it apart from a live one")
			}
			sawRetired = true
		}
	}
	if !sawRetired {
		t.Fatal("ep_web-02 missing from include=retired")
	}
}

// TestRetiredEndpoint_DropsOutOfTheAccessDoorCount pins the /access page's
// claim. That page states how open each door is; a retired token cannot push
// through any of them, so counting it would overstate the hub's exposure.
func TestRetiredEndpoint_DropsOutOfTheAccessDoorCount(t *testing.T) {
	h := newHarness(t)
	h.enroll(t, "web-01")
	h.enroll(t, "web-02")

	before, err := h.srv.Store.EnrollmentCounts()
	if err != nil {
		t.Fatal(err)
	}
	if before["agent"] != 2 {
		t.Fatalf("want 2 agents before retiring, got %v", before)
	}

	if _, err := h.srv.Store.RetireEndpoint("ep_web-02"); err != nil {
		t.Fatal(err)
	}
	after, err := h.srv.Store.EnrollmentCounts()
	if err != nil {
		t.Fatal(err)
	}
	if after["agent"] != 1 {
		t.Fatalf("a retired token can no longer push, so the door map must not "+
			"count it: got %v", after)
	}
}

// A typo in `include` is rejected rather than ignored: silently returning the
// active-only list would read as "there are no retired endpoints".
func TestEndpoints_RejectsUnknownInclude(t *testing.T) {
	h := newHarness(t)
	if code := h.getCode(t, "/v1/endpoints?include=retried"); code != http.StatusBadRequest {
		t.Fatalf("want 400 for an unknown include value, got %d", code)
	}
}
