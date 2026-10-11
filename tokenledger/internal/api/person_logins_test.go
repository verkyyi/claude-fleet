package api

import (
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3302: one person holds several logins, with different names
// on different machines — the hub lists every pair, never one name.

// The live mapping the issue quotes (2026-10-11), as account rows.
func liveAccounts() []store.FleetAccount {
	row := func(pid, host, login, state string) store.FleetAccount {
		return store.FleetAccount{PrincipalID: pid, Hostname: host, Login: login, State: state}
	}
	return []store.FleetAccount{
		row("gh:2718137", "macmini", "verky", store.AccountActive),
		row("gh:2718137", "mini2", "verky", store.AccountActive),
		row("gh:2718137", "Verkys-Mac", "verkyyi", store.AccountActive),
		row("gh:2987262", "fleet-linux-0", "24haowan", store.AccountActive),
		row("gh:2987262", "macmini", "24haowan", store.AccountActive),
		row("gh:2987262", "mini2", "24haowan", store.AccountActive),
		row("gh:2987262", "caojiandeMac-mini.local", "caojian", store.AccountActive),
		row("gh:2987262", "myMac", "arvincao", store.AccountPending),
		row(store.SparePrefix+"1", "macmini", "spare1", store.AccountActive),
	}
}

func TestPersonLoginsEveryPairWithHomeAndKind(t *testing.T) {
	homes := map[string]store.EntryHome{"gh:2987262": {Person: "gh:2987262", Machine: "fleet-linux-0", Login: "24haowan"}}
	hosts := []string{"macmini.local", "mini2", "fleet-linux-0"}
	got := buildPersonLogins(liveAccounts(), homes, hosts)

	type pair struct {
		host, login, state string
		home               bool
		kind               string
	}
	flat := func(ls []PersonLogin) []pair {
		out := []pair{}
		for _, l := range ls {
			out = append(out, pair{l.Hostname, l.Login, l.State, l.Home, l.Kind})
		}
		return out
	}
	wantArvin := []pair{
		{"fleet-linux-0", "24haowan", "active", true, "node"},
		{"macmini", "24haowan", "active", false, "node"},
		{"mini2", "24haowan", "active", false, "node"},
		{"caojiandeMac-mini.local", "caojian", "active", false, "client"},
		{"myMac", "arvincao", "pending", false, "client"},
	}
	if g := flat(got["gh:2987262"]); !reflect.DeepEqual(g, wantArvin) {
		t.Fatalf("gh:2987262 =\n%+v\nwant\n%+v", g, wantArvin)
	}
	wantYi := []pair{
		{"macmini", "verky", "active", false, "node"},
		{"mini2", "verky", "active", false, "node"},
		{"Verkys-Mac", "verkyyi", "active", false, "client"},
	}
	if g := flat(got["gh:2718137"]); !reflect.DeepEqual(g, wantYi) {
		t.Fatalf("gh:2718137 =\n%+v\nwant\n%+v", g, wantYi)
	}
	if len(got) != 2 {
		t.Fatalf("a spare login is nobody's: %v", got)
	}
	// A home naming another login on that machine marks nothing.
	other := buildPersonLogins(liveAccounts(), map[string]store.EntryHome{"gh:2718137": {Machine: "macmini", Login: "someone"}}, nil)
	for _, l := range other["gh:2718137"] {
		if l.Home {
			t.Fatalf("home on %+v", l)
		}
	}
}

// Both of the hub's person lists carry the pairs: /v1/fleet/users (the
// people page and the per-person page) and /v1/fleet/accounts (`fleet hub
// accounts`).
func TestFleetUsersAndAccountsListEveryLogin(t *testing.T) {
	h := newUsersHarness(t)
	if code, body := h.call(t, http.MethodPost, "/v1/fleet/users", `{"login":"alice","machine_login":"alice"}`, nil); code != http.StatusCreated {
		t.Fatalf("add = %d %v", code, body)
	}
	pid := githubPrincipal(ghAlice.ID)
	now := time.Now().UTC()
	p, err := h.srv.Store.EnsurePrincipal(pid, "Alice", control.MaxLoginLen, control.ValidLogin, now)
	if err != nil {
		t.Fatal(err)
	}
	for host, login := range map[string]string{"macmini": "alice", "mini2": "ali", "alices-mac": "alicew"} {
		if _, err := h.srv.Store.RecordLoginAccount(p, host, login, "", "", now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pid, Machine: "mini2", Login: "ali", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}

	pairs := func(v any) map[string]string {
		out := map[string]string{}
		ls, _ := v.([]any)
		for _, x := range ls {
			m := x.(map[string]any)
			s := m["login"].(string) + "," + m["state"].(string) + "," + m["kind"].(string)
			if m["home"] == true {
				s += ",home"
			}
			out[m["hostname"].(string)] = s
		}
		return out
	}
	want := map[string]string{"macmini": "alice,active,client", "mini2": "ali,active,client,home", "alices-mac": "alicew,active,client"}

	code, body := h.call(t, http.MethodGet, "/v1/fleet/users", "", nil)
	if code != http.StatusOK {
		t.Fatalf("users = %d %v", code, body)
	}
	var alice map[string]any
	for _, u := range body["users"].([]any) {
		if m := u.(map[string]any); m["principal"] == pid {
			alice = m
		}
	}
	if alice == nil || !reflect.DeepEqual(pairs(alice["logins"]), want) {
		t.Fatalf("users alice = %v, want logins %v", alice, want)
	}

	code, body = h.call(t, http.MethodGet, "/v1/fleet/accounts", "", nil)
	if code != http.StatusOK {
		t.Fatalf("accounts = %d %v", code, body)
	}
	logins, _ := body["logins"].(map[string]any)
	if got := pairs(logins[pid]); !reflect.DeepEqual(got, want) {
		t.Fatalf("accounts logins[%s] = %v, want %v", pid, got, want)
	}
}
