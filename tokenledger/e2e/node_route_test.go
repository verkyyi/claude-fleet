package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"

	"net/http/httptest"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// newReplicaPair is two hub processes as two replicas would run them: one
// database, each its own node links, each reachable by the other at its URL.
// tokens is shared, so an endpoint enrolled through either dials either.
func newReplicaPair(t *testing.T) (a, b *harness) {
	t.Helper()
	st := openTestStore(t)
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	tokens := map[string]string{}
	mk := func(name string) *harness {
		srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken,
			LiveStore: NewLive(), Fleet: true, Replica: &Replica{Name: name, Token: replicaTestToken}}
		ts := httptest.NewUnstartedServer(srv.Handler())
		srv.Replica.URL = "http://" + ts.Listener.Addr().String()
		ts.Start()
		t.Cleanup(ts.Close)
		if err := srv.StartReplica(); err != nil {
			t.Fatal(err)
		}
		return &harness{Srv: srv, HTTP: ts, Tokens: tokens}
	}
	return mk("hub-a"), mk("hub-b")
}

const replicaTestToken = "replica-shared-secret"
