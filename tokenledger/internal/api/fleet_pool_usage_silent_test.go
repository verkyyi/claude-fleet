package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3233: a person whose passes keep resolving at the credential
// proxy while no pool_usage row lands is raised as pool_usage_silent, and
// cleared once a row lands or the proxy stops asking.

func poolSilentOpen(t *testing.T, st *store.Store) []string {
	t.Helper()
	subs, err := st.OpenFleetAlertSubjects(store.AlertPoolUsageSilent, "")
	if err != nil {
		t.Fatal(err)
	}
	return subs
}

func poolSilentRow(t *testing.T, st *store.Store, principal string, at time.Time) {
	t.Helper()
	if err := st.AddPoolUsage(store.PoolUsage{Principal: principal, Provider: credvault.Claude, In: 100, Out: 50, At: at}); err != nil {
		t.Fatal(err)
	}
}

func TestPoolUsageSilentRaisedWhenResolvesGoUnbilled(t *testing.T) {
	st := usageSilentStore(t)
	srv := &Server{Store: st, PoolUsageSilentAfter: 30 * time.Minute}
	t0 := time.Now().UTC().Truncate(time.Second)

	// A session working on the pool, its usage never reported.
	for m := 0; m <= 31; m++ {
		srv.notePoolResolve("gh:1005", t0.Add(time.Duration(m)*time.Minute))
		if m == 20 {
			srv.PoolUsageSilentTick(t0.Add(20*time.Minute), true)
			if subs := poolSilentOpen(t, st); len(subs) != 0 {
				t.Fatalf("raised before the threshold: %v", subs)
			}
		}
	}
	now := t0.Add(31 * time.Minute)
	srv.PoolUsageSilentTick(now, true)
	if subs := poolSilentOpen(t, st); len(subs) != 1 || subs[0] != "gh:1005" {
		t.Fatalf("open = %v; want [gh:1005]", subs)
	}
	alerts, err := st.FleetAlerts(50)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range alerts {
		if a.Kind == store.AlertPoolUsageSilent && a.Subject == "gh:1005" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no pool_usage_silent row among %+v", alerts)
	}

	// The first billed request clears it.
	poolSilentRow(t, st, "gh:1005", now.Add(time.Minute))
	srv.notePoolResolve("gh:1005", now.Add(time.Minute))
	srv.PoolUsageSilentTick(now.Add(2*time.Minute), true)
	if subs := poolSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("still open after usage landed: %v", subs)
	}

	// Raised again later, then cleared by the proxy going quiet.
	for m := 3; m <= 40; m++ {
		srv.notePoolResolve("gh:1005", now.Add(time.Duration(m)*time.Minute))
	}
	srv.PoolUsageSilentTick(now.Add(40*time.Minute), true)
	if subs := poolSilentOpen(t, st); len(subs) != 1 {
		t.Fatalf("not raised again: %v", subs)
	}
	srv.PoolUsageSilentTick(now.Add(50*time.Minute), true)
	if subs := poolSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("still open with nothing resolving: %v", subs)
	}
}

func TestPoolUsageSilentQuietWhenBilledOrIdle(t *testing.T) {
	st := usageSilentStore(t)
	srv := &Server{Store: st, PoolUsageSilentAfter: 30 * time.Minute}
	t0 := time.Now().UTC().Truncate(time.Second)
	for m := 0; m <= 60; m++ {
		at := t0.Add(time.Duration(m) * time.Minute)
		// billed: every request lands
		srv.notePoolResolve("gh:1005", at)
		poolSilentRow(t, st, "gh:1005", at)
		// idle between bursts: a turn every 10 minutes is a fresh stretch
		if m%10 == 0 {
			srv.notePoolResolve("gh:2002", at)
		}
		srv.PoolUsageSilentTick(at, true)
	}
	if subs := poolSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("raised on a billed / idle person: %v", subs)
	}

	// Off: nothing noted, nothing raised.
	off := &Server{Store: st, PoolUsageSilentAfter: -1}
	for m := 0; m <= 40; m++ {
		off.notePoolResolve("gh:3003", t0.Add(time.Duration(m)*time.Minute))
	}
	off.PoolUsageSilentTick(t0.Add(40*time.Minute), true)
	if subs := poolSilentOpen(t, st); len(subs) != 0 {
		t.Fatalf("raised while off: %v", subs)
	}
}

// The real road: a resolve the hub answers counts, a refused one does not;
// a request that reports clears the alert.
func TestPoolUsageSilentFromResolves(t *testing.T) {
	r := newCPRig(t)
	cred, _ := r.issue(t, fidA)
	srv := r.h.srv
	srv.PoolUsageSilentAfter = 30 * time.Minute

	if st, out := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, cpToken, "", map[string]any{"cred": cred + "x", "provider": "claude"}); st != 200 || out["valid"] == true {
		t.Fatalf("forged resolve: %d %v", st, out)
	}
	if len(srv.poolUsageSilent.resolve) != 0 {
		t.Fatalf("a refused pass counted: %v", srv.poolUsageSilent.resolve)
	}
	if st, out := sessDo(t, r.h, http.MethodPost, CredProxyResolvePath, cpToken, "", map[string]any{"cred": cred, "provider": "claude"}); st != 200 || out["valid"] != true {
		t.Fatalf("resolve: %d %v", st, out)
	}
	srv.poolUsageSilent.mu.Lock()
	stretch, ok := srv.poolUsageSilent.resolve["gh:1005"]
	if ok { // the stretch began half an hour ago; no report since
		stretch.first = stretch.first.Add(-31 * time.Minute)
		srv.poolUsageSilent.resolve["gh:1005"] = stretch
	}
	srv.poolUsageSilent.mu.Unlock()
	if !ok {
		t.Fatal("a resolve the hub answered did not count")
	}
	srv.PoolUsageSilentTick(time.Now(), true)
	if subs := poolSilentOpen(t, srv.Store); len(subs) != 1 || subs[0] != "gh:1005" {
		t.Fatalf("open = %v; want [gh:1005]", subs)
	}

	// A request through the proxy reports its usage: cleared.
	if st, body := r.call(t, credvault.Claude, cred); st != 200 {
		t.Fatalf("request → %d %s", st, body)
	}
	waitFor(t, 3*time.Second, "the request's row", func() bool { return len(poolRows(t, r.h, "gh:1005")) == 1 })
	srv.PoolUsageSilentTick(time.Now(), true)
	if subs := poolSilentOpen(t, srv.Store); len(subs) != 0 {
		t.Fatalf("still open after a billed request: %v", subs)
	}
}

func TestPoolUsageSilentAfterFromEnv(t *testing.T) {
	for v, want := range map[string]time.Duration{
		"": defaultPoolUsageSilentAfter, "x": defaultPoolUsageSilentAfter, "-5": defaultPoolUsageSilentAfter,
		"600": 10 * time.Minute, "0": -1,
	} {
		t.Setenv("FLEET_POOL_USAGE_SILENT_ALERT_SECS", v)
		if got := PoolUsageSilentAfterFromEnv(); got != want {
			t.Errorf("FLEET_POOL_USAGE_SILENT_ALERT_SECS=%q: %v, want %v", v, got, want)
		}
	}
}
