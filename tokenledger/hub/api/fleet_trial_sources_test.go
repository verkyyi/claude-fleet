package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// fleet.trial.sources (WACK C1): the default pool,byo is no gate at all;
// byo leaves a trial identity only its own subscription — the pool's are
// refused with a readable reason, and with none of its own the try page waits
// with reason byo. A full member is never touched.
func TestTrialSources(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	const trial = "p:00000000-0000-4000-8000-0000000c1001"
	const onTerms = "p:00000000-0000-4000-8000-0000000c1002"
	const member = "p:00000000-0000-4000-8000-0000000c1003"
	now := time.Now()
	if err := h.srv.Store.StartTrialAs(trial, store.IdentityEmail, "c1@example.com", now); err != nil {
		t.Fatal(err)
	}
	setHubSetting(t, h.srv, MemberLimitsPrefix+onTerms, "until="+now.Add(7*24*time.Hour).UTC().Format(time.RFC3339)+",tokens=3000000")
	for _, p := range []string{trial, onTerms, member} {
		setHubSetting(t, h.srv, credUserKey(p), `"*"`)
	}

	pool := store.Credential{PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "shared"}
	api := store.Credential{PrincipalID: store.PoolPrincipal, Provider: credvault.Claude, Account: "key", SourceClass: store.SourceAPI}
	own := func(p string) store.Credential {
		return store.Credential{PrincipalID: p, Provider: credvault.Claude, Account: "mine"}
	}
	verdict := func(p string, c store.Credential) string {
		t.Helper()
		pol, err := h.srv.credPolicyFor("", p)
		if err != nil {
			t.Fatal(err)
		}
		_, why := h.srv.credVerdict(c, pol)
		return why
	}

	// The one trial test (共同约定 2).
	settings, _ := h.srv.Store.FleetSettings()
	for p, want := range map[string]bool{trial: true, onTerms: true, member: false, "svc:x": false, "": false} {
		if got := h.srv.trialIdentity(settings, p); got != want {
			t.Errorf("trialIdentity(%q) = %v; want %v", p, got, want)
		}
	}

	// Default pool,byo: no gate — exactly today.
	for _, p := range []string{trial, onTerms, member} {
		pol, _ := h.srv.credPolicyFor("", p)
		if pol.Sources != nil {
			t.Fatalf("default: %s has sources %v; want no gate", p, pol.Sources)
		}
		for _, c := range []store.Credential{pool, api, own(p)} {
			if why := verdict(p, c); why != "" {
				t.Fatalf("default: %s on %s/%s refused: %s", p, c.PrincipalID, c.Account, why)
			}
		}
	}
	if h.srv.trialNeedsOwn(trial) {
		t.Fatal("default: a trial is told to connect its own subscription")
	}

	// byo: the pool is refused to every trial identity, readably.
	setHubSetting(t, h.srv, TrialSourcesKey, "byo")
	for _, p := range []string{trial, onTerms} {
		for _, c := range []store.Credential{pool, api} {
			why := verdict(p, c)
			if !strings.Contains(why, TrialSourcesKey+"=byo") || !strings.Contains(why, "自己的订阅") {
				t.Fatalf("byo: %s on pool %s = %q; want the readable refusal", p, c.Account, why)
			}
		}
		if why := verdict(p, own(p)); why != "" {
			t.Fatalf("byo: %s's own subscription refused: %s", p, why)
		}
	}
	// A full member keeps the pool.
	if why := verdict(member, pool); why != "" {
		t.Fatalf("byo: a member's pool subscription refused: %s", why)
	}
	// The credential list the proxy chooses from keeps only the trial's own.
	pol, _ := h.srv.credPolicyFor("", trial)
	if kept := h.srv.credPolicyFilter([]store.Credential{pool, api, own(trial)}, pol); len(kept) != 1 || kept[0].PrincipalID != trial {
		t.Fatalf("byo: filter kept %+v; want only the trial's own", kept)
	}

	// No own subscription: the claim waits with reason byo.
	if !h.srv.trialNeedsOwn(trial) {
		t.Fatal("byo with nothing connected: trialNeedsOwn false")
	}
	if a, err := h.srv.tryClaim(trial, "", now); err != nil || a.State != "waiting" || a.Reason != trialWaitBYO {
		t.Fatalf("byo: claim = %+v, %v; want a wait with reason byo", a, err)
	}
	if h.srv.trialNeedsOwn(member) {
		t.Fatal("a member is told to connect its own subscription")
	}
	// One connected: nothing to connect any more.
	if err := h.srv.Store.PutCredential(trial, credvault.Claude, "mine", []byte("sealed"), "", nil, now); err != nil {
		t.Fatal(err)
	}
	if h.srv.trialNeedsOwn(trial) {
		t.Fatal("byo with its own subscription: still told to connect one")
	}

	// subscription: the pool's personal subscriptions, not its API keys.
	setHubSetting(t, h.srv, TrialSourcesKey, "subscription")
	if why := verdict(trial, pool); why != "" {
		t.Fatalf("subscription: an unlabelled pool row refused: %s", why)
	}
	if why := verdict(trial, api); why == "" {
		t.Fatal("subscription: an api pool row allowed")
	}
	if why := verdict(trial, own(trial)); why == "" {
		t.Fatal("subscription: the trial's own allowed")
	}

	// 转正: the limits go, and with them the gate.
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+onTerms, "", now); err != nil {
		t.Fatal(err)
	}
	if why := verdict(onTerms, api); why != "" {
		t.Fatalf("converted: refused %s", why)
	}
}

func TestCheckTrialSources(t *testing.T) {
	for in, want := range map[string]string{
		"":                           "pool,byo",
		"pool,byo":                   "pool,byo",
		" BYO , pool ":               "pool,byo",
		"byo":                        "byo",
		"api,subscription":           "pool",
		"api,byo":                    "api,byo",
		"subscription,api,byo":       "pool,byo",
		"subscription":               "subscription",
		"subscription,,subscription": "subscription",
	} {
		if got, bad := checkTrialSources(nil, in); bad != "" || got != want {
			t.Errorf("%q = %q, %q; want %q", in, got, bad, want)
		}
	}
	for _, in := range []string{"own", ",", "pool;byo"} {
		if _, bad := checkTrialSources(nil, in); bad == "" {
			t.Errorf("%q accepted", in)
		}
	}
	// A broken stored value never reads as no gate.
	if cls := trialSourcesOf(map[string]string{TrialSourcesKey: "nonsense"}); cls == nil || !cls[store.SourceBYO] || len(cls) != 1 {
		t.Fatalf("broken value = %v; want byo only", cls)
	}
}

func TestCredentialSourceClass(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	if err := h.srv.Store.PutCredential(store.PoolPrincipal, credvault.Claude, "key", []byte("sealed"), "", nil, now); err != nil {
		t.Fatal(err)
	}
	read := func() store.Credential {
		t.Helper()
		c, err := h.srv.Store.Credential(store.PoolPrincipal, credvault.Claude, "key")
		if err != nil {
			t.Fatal(err)
		}
		return *c
	}
	if c := read(); c.SourceClass != "" || c.Source() != store.SourceSubscription {
		t.Fatalf("unlabelled pool row = %q / %q; want subscription", c.SourceClass, c.Source())
	}
	if err := h.srv.Store.SetCredentialSource(store.PoolPrincipal, credvault.Claude, "key", store.SourceAPI, now); err != nil {
		t.Fatal(err)
	}
	if c := read(); c.Source() != store.SourceAPI {
		t.Fatalf("labelled api = %q", c.Source())
	}
	if err := h.srv.Store.SetCredentialSource(store.PoolPrincipal, credvault.Claude, "key", store.SourceBYO, now); err == nil {
		t.Fatal("a pool row labelled byo")
	}
	if err := h.srv.Store.SetCredentialSource("p:someone", credvault.Claude, "key", store.SourceAPI, now); err == nil {
		t.Fatal("a person's own row labelled")
	}
	if err := h.srv.Store.SetCredentialSource(store.PoolPrincipal, credvault.Claude, "nope", store.SourceAPI, now); err != store.ErrNoCredential {
		t.Fatalf("missing row = %v; want ErrNoCredential", err)
	}
	if err := h.srv.Store.SetCredentialSource(store.PoolPrincipal, credvault.Claude, "key", "", now); err != nil || read().Source() != store.SourceSubscription {
		t.Fatalf("cleared = %v / %q", err, read().Source())
	}
	if (store.Credential{PrincipalID: "p:someone"}).Source() != store.SourceBYO {
		t.Fatal("a person's own row is not byo")
	}
}
