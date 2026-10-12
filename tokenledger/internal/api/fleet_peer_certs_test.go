package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// peerPost asks the hub for a machine-to-machine certificate with a node token.
func peerPost(t *testing.T, h *harness, tok string, body map[string]any) (int, PeerCertResponse, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/peer-cert", bytes.NewReader(b))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out PeerCertResponse
	if res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer does not parse: %v %s", err, raw)
		}
	}
	return res.StatusCode, out, string(raw)
}

// peerHarness: certHarness (Alice owns login alice on mac-e + mac-e-mac-c),
// plus Bob owning bob on mac-e-mac-c only, and the operator's own login frank —
// owned by no person — on both. Every login runs a node.
func peerHarness(t *testing.T) (*harness, *sshca.CA, map[string]*fleetNode) {
	t.Helper()
	h, ca := certHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "mac-e-mac-c", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	nodes := map[string]*fleetNode{
		"alice5": connectNode(t, h, "alice5", "mac-e", "alice", false),
		"alice4": connectNode(t, h, "alice4", "mac-e-mac-c", "alice", false),
		"bob4":   connectNode(t, h, "bob4", "mac-e-mac-c", "bob", false),
		"verk5":  connectNode(t, h, "verk5", "mac-e", "frank", false),
		"verk4":  connectNode(t, h, "verk4", "mac-e-mac-c", "frank", false),
	}
	waitFor(t, 3*time.Second, "every node on the roster", func() bool {
		for _, n := range nodes {
			if r := h.srv.nodeRow(n.id); r == nil || r.Hostname == "" {
				return false
			}
		}
		return true
	})
	return h, ca, nodes
}

// The completion criterion, hub side: a node gets a five-minute certificate
// for its OWNER's login on the target — and only that — recorded before it
// is handed out; a node that is not the owner's is refused.
func TestPeerCertOwnerOnlyShortAndAudited(t *testing.T) {
	h, ca, n := peerHarness(t)

	key := newUserKey(t)
	st, got, raw := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key})
	if st != 200 {
		t.Fatalf("alice@mac-d → mac-c: HTTP %d %s", st, raw)
	}
	c := parseCert(t, strings.TrimSpace(got.Certificate))
	if len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "alice" || got.Login != "alice" || got.Target != "mac-e-mac-c" {
		t.Fatalf("principals %v login %q target %q; want alice on mac-e-mac-c", c.ValidPrincipals, got.Login, got.Target)
	}
	if c.KeyId != "peer:alice@mac-e>alice@mac-e-mac-c:view" || got.KeyID != c.KeyId {
		t.Fatalf("key id %q", c.KeyId)
	}
	if life := time.Unix(int64(c.ValidBefore), 0).Sub(time.Now()); life > sshca.PeerTTL || life < sshca.PeerTTL-10*time.Second {
		t.Fatalf("lives %v; want five minutes", life)
	}
	if _, ok := c.Permissions.Extensions["permit-agent-forwarding"]; ok {
		t.Fatal("a peer certificate forwards the agent")
	}
	if string(c.SignatureKey.Marshal()) != string(mustParsePub(t, ca.PublicKey()).Marshal()) {
		t.Fatal("not signed by the hub's CA")
	}

	// A longer life is asked for and not given; a shorter one is.
	if _, g, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-e-mac-c", "purpose": "upgrade", "public_key": key, "ttl_sec": 86400}); g.TTLSec > int(sshca.PeerTTL.Seconds()) {
		t.Fatalf("asked a day, got %ds", g.TTLSec)
	}
	if _, g, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-e-mac-c", "purpose": "move", "public_key": key, "ttl_sec": 30}); g.TTLSec > 30 {
		t.Fatalf("asked 30s, got %ds", g.TTLSec)
	}

	// The operator's own login (no person owns it) reaches the same name only.
	if st, g, raw := peerPost(t, h, n["verk5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}); st != 200 || g.Login != "frank" {
		t.Fatalf("frank@mac-d → mac-c: HTTP %d login %q %s; want frank", st, g.Login, raw)
	}

	// Refusals: Bob has no login on mac-d; nobody's own machine; no such
	// machine; an unknown purpose; no token; a bad token.
	for name, tc := range map[string]struct {
		tok  string
		body map[string]any
		want int
	}{
		"not the owner's": {n["bob4"].token, map[string]any{"target": "mac-d", "purpose": "view", "public_key": key}, 403},
		"itself":          {n["alice5"].token, map[string]any{"target": "mac-d", "purpose": "view", "public_key": key}, 400},
		"unknown machine": {n["alice5"].token, map[string]any{"target": "nowhere", "purpose": "view", "public_key": key}, 422},
		"bad purpose":     {n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "shell", "public_key": key}, 400},
		"bad key":         {n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": "nope"}, 400},
		"no token":        {"", map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}, 401},
		"bad token":       {"not-a-token", map[string]any{"target": "mac-c", "purpose": "view", "public_key": key}, 401},
	} {
		if st, _, raw := peerPost(t, h, tc.tok, tc.body); st != tc.want {
			t.Errorf("%s: HTTP %d %s; want %d", name, st, raw, tc.want)
		}
	}

	// Every issuance is in the audit — four, newest first — and the
	// refusals are not.
	var audit struct {
		PeerCerts []map[string]any `json:"peer_certs"`
	}
	h.getJSON(t, "/v1/fleet/peer-certs", &audit)
	if len(audit.PeerCerts) != 4 {
		t.Fatalf("audit has %d rows; want 4: %v", len(audit.PeerCerts), audit.PeerCerts)
	}
	seen := map[string]bool{}
	for _, r := range audit.PeerCerts {
		seen[r["source_user"].(string)+">"+r["login"].(string)+":"+r["purpose"].(string)] = true
		if r["target_host"] != "mac-e-mac-c" || r["source_host"] != "mac-e" {
			t.Errorf("audit row %v", r)
		}
	}
	for _, k := range []string{"alice>alice:view", "alice>alice:upgrade", "alice>alice:move", "frank>frank:view"} {
		if !seen[k] {
			t.Errorf("audit misses %s: %v", k, audit.PeerCerts)
		}
	}
}

// No CA configured: the route is not there, like every certificate route.
func TestPeerCertOffWithoutCA(t *testing.T) {
	h, _, n := peerHarness(t)
	h.srv.SSHCA = nil
	if st, _, _ := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": newUserKey(t)}); st != 404 {
		t.Fatalf("HTTP %d; want 404", st)
	}
}

func mustParsePub(t *testing.T, line string) ssh.PublicKey {
	t.Helper()
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

// claude-fleet#2249: an old node joined by a code — enrolled as mac-f.local,
// on the roster as mac-f — and the person's laptop, a node by `fleet login`
// alone. Each login is the person's only through the 登录即认人 row bound to
// its node, so both ends of a peer certificate must read that row: the same
// person's two logins reach each other, another person's login is refused.
func TestPeerCertLoginBoundOnBothEnds(t *testing.T) {
	h, _, n := peerHarness(t)

	// The old node: its enrollment hostname is not the one its agent reports.
	oldTok, _ := MintToken()
	code, _ := MintJoinCode()
	now := time.Now()
	if err := h.srv.Store.CreateJoinCode(HashToken(code), "", now, JoinCodeTTL); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.RedeemJoinCode(HashToken(code), now, "ep_mac-f", "mac-f", HashToken(oldTok), "mac-f.local", "alicem"); err != nil {
		t.Fatal(err)
	}
	old := &fleetNode{token: oldTok, id: "ep_mac-f"}
	old.tnode = dialAdmin(t, h, oldTok, false)
	beat(t, old.c, control.Proto, control.Heartbeat{Hostname: "mac-f", OSUser: "alicem"})
	d1 := newDevice(t)
	d1.scan(t, h, pAlice, "mac-f")
	if c, out := d1.loginNodeAs(t, h, "mac-f", "alicem", oldTok); c != 200 || out["endpoint_id"] != "ep_mac-f" || out["account_refused"] != nil {
		t.Fatalf("old node pass: %d %v", c, out)
	}
	if _, err := h.srv.Store.PrincipalForLogin("mac-f", "alicem"); err == nil {
		t.Fatal("the fixture lost its point: the roster name answers by itself")
	}

	// The laptop: a node by its login only.
	d2 := newDevice(t)
	d2.scan(t, h, pAlice, "MacBookPro")
	c, out := d2.loginNode(t, h, "MacBookPro", "alicelap")
	if c != 200 || out["account_refused"] != nil {
		t.Fatalf("laptop node pass: %d %v", c, out)
	}
	lap := &fleetNode{token: out["token"].(string), id: out["endpoint_id"].(string)}
	lap.tnode = dialAdmin(t, h, lap.token, false)
	beat(t, lap.c, control.Proto, control.Heartbeat{Hostname: "MacBookPro", OSUser: "alicelap"})
	waitFor(t, 3*time.Second, "both on the roster", func() bool {
		for _, x := range []*fleetNode{old, lap} {
			if r := h.srv.nodeRow(x.id); r == nil || r.Hostname == "" {
				return false
			}
		}
		return true
	})

	key := newUserKey(t)
	if st, g, raw := peerPost(t, h, oldTok, map[string]any{"target": "MacBookPro", "purpose": "view", "public_key": key}); st != 200 || g.Login != "alicelap" {
		t.Fatalf("alicem@mac-f → MacBookPro: HTTP %d login %q %s; want alicelap", st, g.Login, raw)
	}
	if st, g, raw := peerPost(t, h, lap.token, map[string]any{"target": "mac-f", "purpose": "view", "public_key": key}); st != 200 || g.Login != "alicem" {
		t.Fatalf("alicelap@MacBookPro → mac-f: HTTP %d login %q %s; want alicem", st, g.Login, raw)
	}
	// Another person's login (Bob's on mac-c, the operator's unowned frank) is not.
	for _, src := range []string{"bob4", "verk4"} {
		if st, _, raw := peerPost(t, h, n[src].token, map[string]any{"target": "MacBookPro", "purpose": "view", "public_key": key}); st != 403 {
			t.Errorf("%s → MacBookPro: HTTP %d %s; want 403", src, st, raw)
		}
	}
}

// The answer carries the target's host keys and the alias they go under
// (claude-fleet#3050): the source machine's own known_hosts never heard of the
// other machine, and its BatchMode ssh refuses an unknown host. A target the
// hub knows no keys for answers without them, as before.
func TestPeerCertCarriesTargetHostKeys(t *testing.T) {
	h, _, n := peerHarness(t)
	key := newUserKey(t)
	st, got, raw := peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key})
	if st != 200 || got.Alias != "" || len(got.HostKeys) != 0 {
		t.Fatalf("no keys known: HTTP %d alias %q keys %v %s; want neither", st, got.Alias, got.HostKeys, raw)
	}
	macC, macD := hostKeyLine(t), hostKeyLine(t)
	for i := range h.srv.FleetRoutes {
		switch h.srv.FleetRoutes[i].Hostname {
		case "mac-e-mac-c":
			h.srv.FleetRoutes[i].HostKeys = []string{macC + " root@mac-c"}
		case "mac-e":
			h.srv.FleetRoutes[i].HostKeys = []string{macD}
		}
	}
	st, got, raw = peerPost(t, h, n["alice5"].token, map[string]any{"target": "mac-c", "purpose": "view", "public_key": key})
	if st != 200 || got.Alias != "mac-c" || len(got.HostKeys) != 1 || got.HostKeys[0] != macC {
		t.Fatalf("HTTP %d alias %q keys %v %s; want mac-c's one key under mac-c", st, got.Alias, got.HostKeys, raw)
	}
	st, got, raw = peerPost(t, h, n["alice4"].token, map[string]any{"target": "mac-e", "purpose": "move", "public_key": key})
	if st != 200 || got.Alias != "mac-d" || len(got.HostKeys) != 1 || got.HostKeys[0] != macD {
		t.Fatalf("HTTP %d alias %q keys %v %s; want mac-d's key under mac-d", st, got.Alias, got.HostKeys, raw)
	}
}
