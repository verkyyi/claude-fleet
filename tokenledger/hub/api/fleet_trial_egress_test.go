package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// 试用账号出网 (WACK C3): a machine reads the mode and the logins on it a trial
// person holds; off names nobody, a member and an admin are never named.
func TestTrialEgressNodeList(t *testing.T) {
	h := entryHarness(t)
	_, tok := rootNode(t, h, "root4", "mac-e-mac-c", control.CapEntryKeys)
	// the list does not ride on the direct door's switch
	if err := h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now()); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for _, hm := range []store.EntryHome{
		{Person: pAlice, Machine: "mac-e-mac-c", Login: "alice", SetBy: "test", SetAt: now},
		{Person: pBob, Machine: "mac-e-mac-c", Login: "bob", SetBy: "test", SetAt: now},
	} {
		if _, err := h.srv.Store.SetEntryHome(hm); err != nil {
			t.Fatal(err)
		}
	}
	// Bob is a trial member: limits with an end. Alice is a member with none.
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pBob, "until="+now.Add(72*time.Hour).Format(time.RFC3339)+",tokens=1000", now); err != nil {
		t.Fatal(err)
	}
	read := func(what string) control.TrialEgress {
		t.Helper()
		code, raw := entryCall(t, h, http.MethodGet, control.TrialEgressNodePath, asNode(tok), nil)
		var out control.TrialEgress
		if code != 200 || json.Unmarshal([]byte(raw), &out) != nil || out.Logins == nil {
			t.Fatalf("%s: HTTP %d %s", what, code, raw)
		}
		return out
	}
	if got := read("default"); got.Mode != "off" || len(got.Logins) != 0 {
		t.Fatalf("default: %+v, want off and nobody", got)
	}
	if _, why := checkTrialEgress(h.srv, "deny"); why == "" {
		t.Fatal("fleet.trial.egress took a value outside off | log | block")
	}
	for _, mode := range []string{"log", "block"} {
		if err := h.srv.Store.SetFleetSetting(TrialEgressKey, mode, now); err != nil {
			t.Fatal(err)
		}
		if got := read(mode); got.Mode != mode || strings.Join(got.Logins, ",") != "bob" {
			t.Fatalf("%s: %+v, want only bob (the trial member)", mode, got)
		}
	}
	// 转正: the limits' end goes — Bob is no longer named.
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pBob, "tokens=1000", now); err != nil {
		t.Fatal(err)
	}
	if got := read("converted"); len(got.Logins) != 0 {
		t.Fatalf("after 转正: %+v, want nobody", got)
	}
	// A login's own token is not the machine's.
	if code, raw := entryCall(t, h, http.MethodGet, control.TrialEgressNodePath, asNode(h.tokens["mac-e-alice"]), nil); code != http.StatusForbidden {
		t.Fatalf("a login's token: HTTP %d %s, want 403", code, raw)
	}
	if code, _ := entryCall(t, h, http.MethodGet, control.TrialEgressNodePath, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d, want 401", code)
	}
}
