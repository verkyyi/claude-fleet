package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The OAuth refresh relay (claude-fleet#1490): the hub's own egress is refused
// by the provider, so the one POST a refresh is travels by an admin node. The
// three outcomes the issue names — the node relays and the provider answers,
// no node is online, the provider refuses — plus the rail that a node which
// is not an admin is never handed a form.

const (
	codexRefreshSecret = "rt-SECRET-codex-0"
	codexRefreshNext   = "rt-SECRET-codex-1"
	codexIDToken       = "id-SECRET-token-1"
)

// codexJWT is an unsigned JWT whose exp is in h hours: what the provider hands
// back as the access token, and what the hub reads the expiry from.
func codexJWT(t *testing.T, in time.Duration) string {
	t.Helper()
	claims, _ := json.Marshal(map[string]any{"exp": time.Now().Add(in).Unix(), "sub": "u"})
	seg := func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }
	return seg([]byte(`{"alg":"none"}`)) + "." + seg(claims) + ".sig"
}

// fakeProvider is auth.openai.com for the test: it counts hits, checks the
// form is the one the hub built, and answers with status + body.
type fakeProvider struct {
	srv    *httptest.Server
	hits   atomic.Int64
	status atomic.Int64
	body   atomic.Value // string
	lastRT atomic.Value // string
}

func newFakeProvider(t *testing.T, access string) *fakeProvider {
	t.Helper()
	p := &fakeProvider{}
	p.status.Store(http.StatusOK)
	b, _ := json.Marshal(map[string]any{"access_token": access, "refresh_token": codexRefreshNext, "id_token": codexIDToken})
	p.body.Store(string(b))
	p.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits.Add(1)
		var form map[string]string
		_ = json.NewDecoder(r.Body).Decode(&form)
		p.lastRT.Store(form["refresh_token"])
		if form["grant_type"] != "refresh_token" || form["client_id"] != credvault.CodexClientID {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(int(p.status.Load()))
		_, _ = w.Write([]byte(p.body.Load().(string)))
	}))
	t.Cleanup(p.srv.Close)
	return p
}

func (p *fakeProvider) refuse(status int, body string) {
	p.status.Store(int64(status))
	p.body.Store(body)
}

// proxyVaultHarness is a hub whose vault refreshes through nodes, with alice's
// mac-c login (the leasing node) and one pool codex refresh token stored.
func proxyVaultHarness(t *testing.T) (*harness, string) {
	t.Helper()
	h := newFleetHarness(t)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: &credvault.ProxyRefresher{Via: h.srv.NodeOAuthRefresh}}
	tok := enrollAs(t, h, "alice-mac-c", "mac-c", "alice")
	p, err := h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "mac-c", time.Now()); err != nil {
		t.Fatal(err)
	}
	code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Codex, Account: "default", Secret: credvault.Secret{RefreshToken: codexRefreshSecret, AccountID: "acct-pool", IDToken: "id-SECRET-token-0"}})
	if code != http.StatusOK {
		t.Fatalf("put pool codex: %d %v", code, out)
	}
	return h, tok
}

// lockedBuf is a log sink the test may read while the agent still writes.
type lockedBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuf) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// A node that offers the capability without being an admin is never asked.
func TestOAuthRefreshNeverSentToNonAdmin(t *testing.T) {
	h, aliceTok := proxyVaultHarness(t)
	tok := enrollAs(t, h, "m6-user", "m6", "someone")
	c := dialNode(t, h, tok)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	m, _ := control.New(control.TypeHello, control.Hello{HeartbeatMS: 5000, Admin: true,
		Capabilities: []string{control.CapRead, control.CapOAuthRefresh}})
	if err := wsjson.Write(ctx, c, m); err != nil {
		t.Fatal(err)
	}
	var reply control.Message
	if err := wsjson.Read(ctx, c, &reply); err != nil || reply.Type != control.TypeWelcome {
		t.Fatalf("hello: %v %+v", err, reply)
	}
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m6", OSUser: "someone"})
	n := &tnode{c: c, in: make(chan control.Message, 16)}
	go func() {
		defer close(n.in)
		for {
			var m control.Message
			if err := wsjson.Read(context.Background(), c, &m); err != nil {
				return
			}
			n.in <- m
		}
	}()

	if _, _, err := h.srv.OAuthRefreshNode(time.Now()); !errors.Is(err, credvault.ErrRefreshUnavailable) {
		t.Fatalf("a non-admin node was picked to relay: %v", err)
	}
	_, got, _ := lease(t, h, aliceTok)
	if len(got.Credentials) != 1 || !strings.Contains(got.Credentials[0].Error, "refresh_unavailable") {
		t.Fatalf("credentials = %+v", got.Credentials)
	}
	if m, ok := readMsg(n, 300*time.Millisecond); ok && m.Type == control.TypeOAuthRefresh {
		t.Fatalf("the non-admin node received a refresh form: %+v", m)
	}
}

// The direct refresher is untouched by the relay: with no
// CCQUOTA_FLEET_OAUTH_REFRESH_VIA the hub posts from its own network.
func TestDirectRefreshStillPostsFromHub(t *testing.T) {
	provider := newFakeProvider(t, codexJWT(t, 8*time.Hour))
	r := &credvault.HTTPRefresher{CodexTokenURL: provider.srv.URL}
	acc, next, err := r.Refresh(context.Background(), credvault.Codex, credvault.Secret{RefreshToken: codexRefreshSecret, AccountID: "a"})
	if err != nil || acc.IDToken != codexIDToken || next.RefreshToken != codexRefreshNext || acc.ExpiresAt == nil {
		t.Fatalf("direct refresh: %+v %+v %v", acc, next, err)
	}
	if provider.hits.Load() != 1 {
		t.Fatal("direct refresh did not post once")
	}
}
