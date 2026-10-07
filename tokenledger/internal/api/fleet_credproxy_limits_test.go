package api

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
)

// An account at its limit is not picked; a quota 429 moves the session once
// (claude-fleet#2115, EPIC #2133 C2).

const weekly429 = `{"type":"error","error":{"type":"rate_limit_error","message":"You've hit your weekly limit"}}`

// atLimit stores a reading for the account the vault label names: the
// seven-day window at pct, resetting at reset.
func atLimit(t *testing.T, r *cpRig, label string, pct float64, reset time.Time) {
	t.Helper()
	id := model.Identity{Source: "claude", AccountUUID: "uuid-" + label, Email: label + "@example.com"}
	if err := r.h.srv.Store.UpsertAccount(id, "max", ""); err != nil {
		t.Fatal(err)
	}
	snap := &model.LimitsSnapshot{AccountUUID: id.AccountUUID, ObservedAt: time.Now()}
	snap.SevenDay.Utilization, snap.SevenDay.ResetsAt = pct, &reset
	if err := r.h.srv.Store.InsertLimits(snap); err != nil {
		t.Fatal(err)
	}
}

func (r *cpRig) boundTo(t *testing.T, wid string) (string, int64) {
	t.Helper()
	b, err := r.h.srv.Store.SessionBindFor(wid, credvault.Claude)
	if err != nil {
		t.Fatal(err)
	}
	return b.Account, b.Rev
}

func (r *cpRig) upCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.upAuth)
}

// One account full → a new session gets the other; the window reset → the
// first again; every account full → the old order.
func TestSessionPickSkipsAccountAtLimit(t *testing.T) {
	r := newCPRig(t)
	soon := time.Now().Add(48 * time.Hour)
	atLimit(t, r, "acct1", 100, soon)
	credA, widA := r.issue(t, fidA)
	if st, body := r.call(t, credvault.Claude, credA); st != 200 {
		t.Fatalf("A → %d %s", st, body)
	}
	if acct, _ := r.boundTo(t, widA); acct != "acct2" {
		t.Fatalf("acct1 is at its weekly limit; A bound to %s, want acct2", acct)
	}
	if got, want := r.lastAuth(), r.leased(t, "gh:1005", credvault.Claude, "acct2"); got != want {
		t.Fatalf("upstream = %q; want acct2's lease", got)
	}

	// every account full: the pick falls back to the old order (acct1)
	atLimit(t, r, "acct2", 100, soon)
	credB, widB := r.issue(t, fidB)
	r.call(t, credvault.Claude, credB)
	if acct, _ := r.boundTo(t, widB); acct != "acct1" {
		t.Fatalf("all full: B bound to %s, want the old order's acct1", acct)
	}

	// a window that has reset is not full
	r2 := newCPRig(t)
	atLimit(t, r2, "acct1", 100, time.Now().Add(-time.Minute))
	credC, widC := r2.issue(t, fidA)
	r2.call(t, credvault.Claude, credC)
	if acct, _ := r2.boundTo(t, widC); acct != "acct1" {
		t.Fatalf("acct1's window reset; C bound to %s, want acct1", acct)
	}
}

// A quota 429 moves the session once and the request is sent again on the
// new account; the next request goes there directly. When every account is
// full, the 429 reaches the client after ONE resend at most. A request-rate
// 429 moves nothing.
func TestCredProxyRebindsOnQuota429(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	a1, a2 := r.leased(t, "gh:1005", credvault.Claude, "acct1"), r.leased(t, "gh:1005", credvault.Claude, "acct2")

	// a request-rate 429 passes through and moves nothing
	r.mu.Lock()
	r.full = map[string]string{a1: `{"type":"error","error":{"type":"rate_limit_error","message":"per-minute rate limit"}}`}
	r.mu.Unlock()
	if st, _ := r.call(t, credvault.Claude, cred); st != http.StatusTooManyRequests {
		t.Fatalf("rate 429 → %d", st)
	}
	if acct, rev := r.boundTo(t, wid); acct != "acct1" || rev != 1 || r.upCount() != 1 {
		t.Fatalf("rate 429 moved the session: %s rev %d, %d upstream", acct, rev, r.upCount())
	}

	r.mu.Lock()
	r.full = map[string]string{a1: weekly429}
	r.mu.Unlock()
	if st, body := r.call(t, credvault.Claude, cred); st != 200 || !strings.Contains(body, "PONG") {
		t.Fatalf("quota 429 on acct1 → %d %s; want the resend on acct2", st, body)
	}
	r.mu.Lock()
	sent := append([]string(nil), r.upAuth[1:]...)
	line := r.audit[len(r.audit)-1]
	r.mu.Unlock()
	if len(sent) != 2 || sent[0] != a1 || sent[1] != a2 {
		t.Fatalf("upstream saw %d (%v); want acct1 then acct2", len(sent), sent)
	}
	if !strings.Contains(line, `"rebind_from":"acct1"`) || !strings.Contains(line, `"account":"acct2"`) {
		t.Fatalf("audit: %s", line)
	}
	if acct, rev := r.boundTo(t, wid); acct != "acct2" || rev != 2 {
		t.Fatalf("binding %s rev %d; want acct2 rev 2", acct, rev)
	}
	n := r.upCount()
	r.call(t, credvault.Claude, cred)
	if r.upCount() != n+1 || r.lastAuth() != a2 {
		t.Fatalf("next request: %d upstream, %q; want one on acct2", r.upCount()-n, r.lastAuth())
	}

	// acct2 full too: the hub has no account with room — nothing moves, the
	// client gets the 429 after one request
	r.mu.Lock()
	r.full[a2] = weekly429
	r.mu.Unlock()
	n = r.upCount()
	if st, _ := r.call(t, credvault.Claude, cred); st != http.StatusTooManyRequests {
		t.Fatalf("all full → %d", st)
	}
	if r.upCount() != n+1 {
		t.Fatalf("all full: %d upstream requests; want 1", r.upCount()-n)
	}
	if acct, rev := r.boundTo(t, wid); acct != "acct2" || rev != 2 {
		t.Fatalf("all full: binding %s rev %d; want acct2 rev 2 unchanged", acct, rev)
	}

	// a new session of the same person is not handed an account the proxy
	// saw a quota 429 on: every one is full, so the old order
	credB, widB := r.issue(t, fidB)
	r.call(t, credvault.Claude, credB)
	if acct, _ := r.boundTo(t, widB); acct != "acct1" {
		t.Fatalf("B bound to %s; want acct1 (all full ⇒ old order)", acct)
	}
}

// Two 429s from one session at once move it once: the second report names
// an account the session is no longer bound to.
func TestCredProxyRebindOnce(t *testing.T) {
	r := newCPRig(t)
	cred, wid := r.issue(t, fidA)
	r.call(t, credvault.Claude, cred) // binds acct1
	req := map[string]any{"cred": cred, "provider": "claude", "account": "acct1"}
	st, out := sessDo(t, r.h, http.MethodPost, CredProxyRebindPath, cpToken, "", req)
	if st != 200 || out["account"] != "acct2" || out["rebind_from"] != "acct1" || out["bind_rev"] != float64(2) {
		t.Fatalf("first rebind: %d %v", st, out)
	}
	st, out = sessDo(t, r.h, http.MethodPost, CredProxyRebindPath, cpToken, "", req)
	if st != 200 || out["account"] != "acct2" || out["rebind_from"] != nil || out["bind_rev"] != float64(2) {
		t.Fatalf("second rebind: %d %v; want acct2 as it stands, no move", st, out)
	}
	if acct, rev := r.boundTo(t, wid); acct != "acct2" || rev != 2 {
		t.Fatalf("binding %s rev %d; want acct2 rev 2", acct, rev)
	}
	if st, _ := sessDo(t, r.h, http.MethodPost, CredProxyRebindPath, "wrong", "", req); st != 401 {
		t.Fatalf("wrong token → %d", st)
	}
}
