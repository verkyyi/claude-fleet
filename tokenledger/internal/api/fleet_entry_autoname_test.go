package api

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/dns"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A person with a home gets their suggested address name without asking
// (claude-fleet#3337, the person's ruling): on the home's auto set, on a home
// set by hand, and — for one homed before — on the next DNS tick. A name
// they hold is never touched, a taken suggestion is not forced, and the
// operator still picks no name for anyone.
func TestEntryAutoNameWithHome(t *testing.T) {
	h := entryHarness(t)
	now := time.Now().UTC()
	nameOf := func(p string) string {
		n, ok, err := h.srv.Store.EntryName(p)
		if err != nil {
			t.Fatal(err)
		}
		if !ok {
			return ""
		}
		return n.Name
	}

	// Alice's first read sets her home (auto) and claims her name with it.
	sug := h.srv.entrySuggestedName(pAlice)
	if sug == "" {
		t.Fatal("Alice has no suggested name")
	}
	if code, raw := entryCall(t, h, http.MethodGet, control.EntryKeysPath, asSession(pAlice), nil); code != 200 ||
		!strings.Contains(raw, `"set_by":"auto"`) || !strings.Contains(raw, `"name":"`+sug+`"`) || strings.Contains(raw, "suggested_name") {
		t.Fatalf("Alice's first read: HTTP %d %s", code, raw)
	}
	if got := nameOf(pAlice); got != sug {
		t.Fatalf("Alice's name after the auto home: %q, want %q", got, sug)
	}
	audits, _ := h.srv.Store.EntryAudits(pAlice, 50)
	claimed := false
	for _, a := range audits {
		if a.Kind == "name_set" && a.Result == sug && a.Actor == "hub" {
			claimed = true
		}
	}
	if !claimed {
		t.Fatalf("no name_set audit line by the hub: %+v", audits)
	}

	// She renames it; nothing claims over it.
	if code, raw := entryCall(t, h, http.MethodPut, control.EntryNamePath, asSession(pAlice), map[string]any{"name": "alice-x"}); code != 200 {
		t.Fatalf("rename: HTTP %d %s", code, raw)
	}
	entryCall(t, h, http.MethodGet, control.EntryKeysPath, asSession(pAlice), nil)

	// Bob was homed before #3337 (no name): the next tick claims his. Alice
	// holds his suggestion first, so it is not his to get.
	bobSug := h.srv.entrySuggestedName(pBob)
	if bobSug == "" {
		t.Fatal("Bob has no suggested name")
	}
	if _, err := h.srv.Store.SetEntryName(pAlice, bobSug, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pBob, Machine: "macmini-m4", Login: "bob", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	h.srv.EntryDNS = NewEntryDNS(dns.NewFake(), "cf")
	h.srv.EntryDNSTick(context.Background(), now)
	if got := nameOf(pAlice); got != bobSug {
		t.Fatalf("Alice's own name was changed: %q", got)
	}
	if got := nameOf(pBob); got == bobSug {
		t.Fatalf("Bob was given a name Alice holds: %q", got)
	}
	// The operator still picks no arbitrary name for anyone.
	if code, raw := entryCall(t, h, http.MethodPut, control.EntryNamePath+"?principal="+pBob, asOperator, map[string]any{"name": "zzz"}); code != http.StatusForbidden {
		t.Fatalf("operator names Bob: HTTP %d %s, want 403", code, raw)
	}
}

// A name nobody claimed is not in the plan and has no address: the zone's
// own wildcard (*.24haowan.com → the hub) is shadowed by the loop's *.cf,
// which carries a TXT saying so and no A / AAAA. Its hand removal is put
// back; a second tick writes nothing.
func TestEntryDNSUnclaimedNameResolvesNowhere(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	ctx := context.Background()
	now := time.Now().UTC()
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini", now, true, "23.119.126.213")

	targets, err := h.srv.entryDNSTargets("cf", now)
	if err != nil {
		t.Fatal(err)
	}
	for host := range targets {
		if host != "alice.cf" && host != "*.cf" {
			t.Fatalf("an unclaimed name in the plan: %s (%v)", host, targets)
		}
	}
	if g := targets["*.cf"].want; len(g) != 1 || len(g["TXT"]) != 1 {
		t.Fatalf("the guard: %v, want one TXT and no address", g)
	}

	h.srv.EntryDNSTick(ctx, now)
	zone := func() string {
		var b []string
		for _, r := range f.Records() {
			b = append(b, r.Type+" "+r.Name+" "+r.Value)
		}
		return strings.Join(b, " | ")
	}
	want := "TXT *.cf " + EntryDNSUnclaimed + " | A alice.cf 23.119.126.213"
	if got := zone(); got != want {
		t.Fatalf("zone: %s\nwant %s", got, want)
	}
	for _, r := range f.Records() {
		if r.Name == "*.cf" && r.TTL != dns.TTL {
			t.Fatalf("the guard's TTL %d, want the floor %d", r.TTL, dns.TTL)
		}
	}
	if n := h.srv.EntryDNSTick(ctx, now.Add(time.Minute)); n != 0 {
		t.Fatalf("second tick: %d writes", n)
	}
	for _, r := range f.Records() {
		if r.Name == "*.cf" {
			_ = f.Delete(ctx, r.ID)
		}
	}
	if n := h.srv.EntryDNSTick(ctx, now.Add(2*time.Minute)); n != 1 || zone() != want {
		t.Fatalf("guard removed by hand: %d writes, zone %s", n, zone())
	}
}
