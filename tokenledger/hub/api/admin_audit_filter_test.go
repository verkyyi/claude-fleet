package api

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

// The Audit page narrows by person and time (claude-fleet#3938): ?actor= and
// ?since= on the one read, the CSV export carrying the same.
func TestAdminAudit_ActorAndSince(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	now := time.Now()
	for _, r := range []struct {
		actor, target string
		at            time.Time
	}{
		{"alice (gh:11)", "bob", now.Add(-3 * 24 * time.Hour)},
		{"alice (gh:11)", "carol", now.Add(-time.Hour)},
		{"dave (p:9a2d)", "erin", now.Add(-2 * time.Hour)},
	} {
		if err := h.srv.Store.HubAudit(r.actor, "user.remove", r.target, "ok", "", r.at); err != nil {
			t.Fatal(err)
		}
	}
	targets := func(evs []AuditEvent) string {
		var out []string
		for _, e := range evs {
			if e.Action == "user.remove" {
				out = append(out, e.Target)
			}
		}
		return strings.Join(out, ",")
	}
	day := url.QueryEscape(now.Add(-24 * time.Hour).Format(time.RFC3339))
	for q, want := range map[string]string{
		"":             "carol,erin,bob",
		"?actor=alice": "carol,bob",
		"?actor=ALICE": "carol,bob",
		"?actor=gh:11": "carol,bob",
		"?actor=" + url.QueryEscape("dave (p:9a2d)"): "erin",
		"?actor=ali":                          "",
		"?since=" + day:                       "carol,erin",
		"?actor=alice&since=" + day:           "carol",
		"?actor=alice&kind=user&since=" + day: "carol",
	} {
		if got := targets(auditOf(t, h, q)); got != want {
			t.Errorf("audit%s = %q; want %q", q, got, want)
		}
	}
	if code := h.getCode(t, AuditPath+"?since=yesterday"); code != http.StatusBadRequest {
		t.Errorf("since=yesterday = %d; want 400", code)
	}
	// a since before the window is the window
	if got := targets(auditOf(t, h, "?since=2000-01-01T00:00:00Z")); got != "carol,erin,bob" {
		t.Errorf("since=2000 = %q", got)
	}
	_, body := h.get(t, AuditPath+"?format=csv&actor=alice&since="+day)
	if s := string(body); !strings.Contains(s, ",carol,") || strings.Contains(s, ",bob,") || strings.Contains(s, ",erin,") {
		t.Errorf("csv for alice since a day = %s", s)
	}
}

// A setting changed and changed back is two rows, one per change, by the
// actor; the page finds both with the person filter.
func TestAdminAudit_SettingBackAndForth(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	for _, v := range []string{"on", "off"} {
		if code, out := h.post(t, "/v1/fleet/settings", map[string]string{"key": PublicBadgesKey, "value": v}); code != http.StatusOK {
			t.Fatalf("set %s: %d %v", v, code, out)
		}
	}
	n := 0
	for _, e := range auditOf(t, h, "?kind=set") {
		if e.Action == "setting" && e.Target == PublicBadgesKey {
			n++
		}
	}
	if n != 2 {
		t.Errorf("%d setting rows for %s; want 2", n, PublicBadgesKey)
	}
}
