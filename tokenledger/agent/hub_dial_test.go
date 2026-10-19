package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A person's pod dials the hub's in-cluster Service (claude-fleet#4175): every
// call goes to HubDial, while HubURL stays the identity a login opened here is
// joined to. No HubDial = HubURL, as before.
func TestHubDialCarriesTheCallsNotTheIdentity(t *testing.T) {
	var public, internal atomic.Int32
	pub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		public.Add(1)
		http.Error(w, "the public door", http.StatusForbidden)
	}))
	defer pub.Close()
	svc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		internal.Add(1)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer svc.Close()

	a := &Agent{cfg: Config{HubURL: pub.URL, HubDial: svc.URL, Token: "tok"}}
	// Any node call builds its URL from hub() (the SPOT reclaim notice that
	// stood here left with the SPOT nodes, claude-fleet#4797).
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, a.cfg.hub()+"/v1/node/maintenance", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	a.authorize(req)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("a node call through HubDial: %v", err)
	}
	resp.Body.Close()
	if public.Load() != 0 || internal.Load() != 1 {
		t.Fatalf("public %d, internal %d: the call must go to HubDial", public.Load(), internal.Load())
	}
	if got := (Config{HubURL: pub.URL}).hub(); got != pub.URL {
		t.Fatalf("no HubDial: hub() = %q, want HubURL", got)
	}

	// the machine hands both to every login and to its account opener; a new
	// login is still joined to the public hub
	mc := MachineConfig{HubURL: "https://hub.example", HubDial: "http://ccquota-hub.new-deploy.svc.cluster.local",
		AccountOpener: "/bin/true"}
	if mc.hub() != mc.HubDial {
		t.Fatalf("machine link dials %q", mc.hub())
	}
	acct := newMachineAccounts(mc)
	if acct.cfg.HubURL != mc.HubURL || acct.cfg.hub() != mc.HubDial {
		t.Fatalf("accounts: identity %q, dial %q", acct.cfg.HubURL, acct.cfg.hub())
	}
	env := strings.Join(accountEnv(acct.cfg.HubURL, "", control.AccountOp{Op: control.AccountCreate, Login: "dana", JoinCode: "code"}), "\n")
	if !strings.Contains(env, "FLEET_LOGIN_HUB=https://hub.example") {
		t.Fatalf("a login's join must name the public hub:\n%s", env)
	}
}
