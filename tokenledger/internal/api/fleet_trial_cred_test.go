package api

import (
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A trial person is a fresh p: principal nobody lists: its person allowance
// is fleet.trial.cred_allow, not a key per person (claude-fleet#4260).
func TestTrialCredAllow(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, CredPolicyModeKey, "strict")
	setHubSetting(t, h.srv, TrialKey, "on")
	const pid = "p:00000000-0000-4000-8000-000000004260"
	const member = "p:00000000-0000-4000-8000-000000004261"
	now := time.Now()
	if err := h.srv.Store.StartTrialAs(pid, store.IdentityEmail, "trier@example.com", now); err != nil {
		t.Fatal(err)
	}
	person := func(p string) credAllow {
		t.Helper()
		pol, err := h.srv.credPolicyFor("", p)
		if err != nil {
			t.Fatal(err)
		}
		return pol.User
	}
	why := func(a credAllow, uuid string) string {
		return credPolicy{Principal: pid, User: a}.check(credvault.Claude, uuid)
	}

	// Unset: "*" — every subscription the trial is otherwise eligible for.
	if a := person(pid); !a.All || why(a, uuidGmail) != "" {
		t.Fatalf("a new trial with no user key = %+v; want the default \"*\"", a)
	}
	if h.srv.trialNoSub() || h.srv.trialHold("", now) == trialWaitNoSub {
		t.Fatal("the default leaves a trial no subscription")
	}
	// Anyone else with no key is still denied (strict).
	if a := person(member); !a.None || why(a, uuidGmail) == "" {
		t.Fatalf("a non-trial person with no key = %+v; want denied", a)
	}

	// A list: only its entries.
	v, bad := checkTrialCredAllow(h.srv, `["`+uuidGmail+`"]`)
	if bad != "" {
		t.Fatal(bad)
	}
	setHubSetting(t, h.srv, TrialCredAllowKey, v)
	if a := person(pid); why(a, uuidGmail) != "" || why(a, uuidICloud) == "" {
		t.Fatalf("a listed trial allowance = %+v", a)
	}

	// []: none — and admission says so instead of placing onto a 403.
	setHubSetting(t, h.srv, TrialCredAllowKey, "[]")
	if a := person(pid); why(a, uuidGmail) == "" {
		t.Fatalf("[] = %+v; want denied", a)
	}
	if !h.srv.trialNoSub() || h.srv.trialHold("", now) != trialWaitNoSub {
		t.Fatalf("[]: hold = %q; want %q", h.srv.trialHold("", now), trialWaitNoSub)
	}
	if a, err := h.srv.tryClaim(pid, "", now); err != nil || a.Reason != trialWaitNoSub {
		t.Fatalf("[]: claim = %+v, %v; want a wait with reason nosub", a, err)
	}

	// A list written for the person wins.
	setHubSetting(t, h.srv, credUserKey(pid), `["`+uuidICloud+`"]`)
	if a := person(pid); why(a, uuidICloud) != "" || why(a, uuidGmail) == "" {
		t.Fatalf("the person's own list = %+v; want it to win", a)
	}
	if err := h.srv.Store.SetFleetSetting(credUserKey(pid), "", now); err != nil { // deletes it
		t.Fatal(err)
	}

	// Approval writes the trial's allowance as the member's own list.
	setHubSetting(t, h.srv, TrialCredAllowKey, `"*"`)
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	h.srv.convertTrial(pid, "Trier", "gh:1", now)
	if h.srv.trialPerson(pid) {
		t.Fatal("still a trial person after conversion")
	}
	settings, _ := h.srv.Store.FleetSettings()
	if settings[credUserKey(pid)] != `"*"` {
		t.Fatalf("after conversion %s = %q; want the trial's \"*\"", credUserKey(pid), settings[credUserKey(pid)])
	}
	if a := person(pid); !a.All {
		t.Fatalf("the converted member = %+v; want their own \"*\"", a)
	}
}

func TestCheckTrialCredAllow(t *testing.T) {
	for in, want := range map[string]string{
		"*":                 `"*"`,
		` "*" `:             `"*"`,
		"[]":                "[]",
		`["` + uuidCodex + `","` + "11111111-1111-4111-8111-111111111111" + `"]`: `["11111111-1111-4111-8111-111111111111","` + uuidCodex + `"]`,
	} {
		if got, bad := checkTrialCredAllow(nil, in); bad != "" || got != want {
			t.Errorf("%q = %q, %q; want %q", in, got, bad, want)
		}
	}
	for _, in := range []string{"all", "null", `["gmail"]`} {
		if _, bad := checkTrialCredAllow(nil, in); bad == "" {
			t.Errorf("%q accepted", in)
		}
	}
}
