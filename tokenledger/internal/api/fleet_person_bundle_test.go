package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// Each person's own configuration layer (claude-fleet#1856, EPIC #1855 C1).

func personCall(t *testing.T, h *harness, method string, auth func(http.Header), body any, query string) (int, TeamBundleResponse, string, http.Header) {
	t.Helper()
	rd := bytes.NewReader(nil)
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.PersonBundlePath+query, rd)
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	var out TeamBundleResponse
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String(), resp.Header
}

var personV1 = map[string]any{"bundle": map[string]any{
	"mcp":          map[string]any{"notes": map[string]any{"command": "npx", "args": []string{"-y", "notes-mcp"}, "env": map[string]any{"NOTES_TOKEN": "${NOTES_TOKEN}"}}},
	"hook_scripts": map[string]any{"say-done.sh": "#!/bin/sh\n# fleet personal hook\necho done\n"},
}}

// The completion criterion: A writes once and reads the same version from
// both of their machines; B — by session or by node — cannot write A's; a
// literal token is 422; a stale base is 409; a restore is a new version; a
// login bound to no one has no layer.
func TestPersonBundleOwnLayerFollowsThePerson(t *testing.T) {
	h, _, n := peerHarness(t) // Alice: alice on macmini + macmini-m4; Bob: bob on macmini-m4; verk: no one

	// nothing yet: version 0, an empty layer
	code, out, raw, _ := personCall(t, h, http.MethodGet, asNode(n["alice5"].token), nil, "")
	if code != 200 || out.Version != 0 || string(out.Bundle) != "{}" {
		t.Fatalf("alice@m5 before any PUT: HTTP %d %s, want version 0 and {}", code, raw)
	}

	// A writes once, from a session
	code, v1, raw, _ := personCall(t, h, http.MethodPut, asSession("Alice"), personV1, "")
	if code != 200 || v1.Version != 1 || v1.Prev != 0 || v1.Actor != "Alice" || !strings.Contains(string(v1.Bundle), "say-done.sh") {
		t.Fatalf("Alice PUT: HTTP %d %s, want version 1 by Alice", code, raw)
	}
	// … and reads the same version on both machines, under the same tag
	var tags []string
	for _, k := range []string{"alice5", "alice4"} {
		code, got, raw, hdr := personCall(t, h, http.MethodGet, asNode(n[k].token), nil, "")
		if code != 200 || got.Version != 1 || string(got.Bundle) != string(v1.Bundle) {
			t.Fatalf("%s reads: HTTP %d %s, want Alice's version 1", k, code, raw)
		}
		tags = append(tags, hdr.Get("ETag"))
	}
	if tags[0] != tags[1] || !strings.HasPrefix(tags[0], `"person-`) || !strings.HasSuffix(tags[0], `-v1"`) {
		t.Fatalf("ETags %v: want one \"person-<pid8>-v1\" on both machines", tags)
	}
	code, _, _, _ = personCall(t, h, http.MethodGet, func(hd http.Header) { asNode(n["alice4"].token)(hd); hd.Set("If-None-Match", tags[0]) }, nil, "")
	if code != http.StatusNotModified {
		t.Fatalf("If-None-Match the current version: HTTP %d, want 304", code)
	}

	// B's layer is B's: empty, and B cannot touch A's
	if code, got, raw, _ := personCall(t, h, http.MethodGet, asNode(n["bob4"].token), nil, ""); code != 200 || got.Version != 0 {
		t.Fatalf("bob@m4 reads his own: HTTP %d %s, want version 0", code, raw)
	}
	for name, auth := range map[string]func(http.Header){"Bob's session": asSession("Bob"), "Bob's node": asNode(n["bob4"].token)} {
		if code, _, raw, _ := personCall(t, h, http.MethodPut, auth, map[string]any{"bundle": map[string]any{}}, "?principal=Alice"); code != http.StatusForbidden {
			t.Fatalf("%s PUT Alice's: HTTP %d %s, want 403", name, code, raw)
		}
		if code, _, raw, _ := personCall(t, h, http.MethodGet, auth, nil, "?principal=alice"); code != http.StatusForbidden {
			t.Fatalf("%s GET Alice's: HTTP %d %s, want 403", name, code, raw)
		}
	}

	// A's own node writes A's layer; a stale base never overwrites
	code, v2, raw, _ := personCall(t, h, http.MethodPut, asNode(n["alice4"].token), map[string]any{"base": 1, "bundle": map[string]any{"skills": map[string]any{"my-notes": "# notes\n"}}}, "")
	if code != 200 || v2.Version != 2 || v2.Prev != 1 || !strings.HasPrefix(v2.Actor, "node:alice@") {
		t.Fatalf("alice@m4 PUT base 1: HTTP %d %s, want version 2 by her node", code, raw)
	}
	if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession("alice"), map[string]any{"base": 1, "bundle": map[string]any{}}, ""); code != http.StatusConflict {
		t.Fatalf("stale base: HTTP %d %s, want 409", code, raw)
	}
	// a literal credential is refused, naming where it sits
	ghp := map[string]any{"bundle": map[string]any{"mcp": map[string]any{"gh": map[string]any{"command": "x", "args": []string{"--t", "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
	if code, _, raw, _ := personCall(t, h, http.MethodPut, asSession("Alice"), ghp, ""); code != http.StatusUnprocessableEntity || !strings.Contains(raw, "bundle.mcp.gh.args[1]") {
		t.Fatalf("ghp_ literal: HTTP %d %s, want 422 naming bundle.mcp.gh.args[1]", code, raw)
	}

	// restore = a new version carrying an older body
	code, v3, raw, _ := personCall(t, h, http.MethodPut, asSession("Alice"), map[string]any{"restore": 1, "base": 2}, "")
	if code != 200 || v3.Version != 3 || v3.Prev != 2 || string(v3.Bundle) != string(v1.Bundle) {
		t.Fatalf("restore 1: HTTP %d %s, want version 3 carrying v1's body", code, raw)
	}
	code, hist, raw, _ := personCall(t, h, http.MethodGet, asSession("Alice"), nil, "?history=1")
	if code != 200 || len(hist.History) != 3 || hist.History[0].Version != 3 {
		t.Fatalf("history: HTTP %d %s", code, raw)
	}
	if code, old, _, _ := personCall(t, h, http.MethodGet, asSession("Alice"), nil, "?version=2"); code != 200 || !strings.Contains(string(old.Bundle), "my-notes") {
		t.Fatalf("?version=2: HTTP %d v%d", code, old.Version)
	}

	// the operator reads anyone's and puts back their own versions — never new content
	if code, _, raw, _ := personCall(t, h, http.MethodGet, asOperator, nil, ""); code != http.StatusBadRequest {
		t.Fatalf("operator GET with no ?principal: HTTP %d %s, want 400", code, raw)
	}
	if code, got, raw, _ := personCall(t, h, http.MethodGet, asOperator, nil, "?principal=alice"); code != 200 || got.Version != 3 {
		t.Fatalf("operator GET Alice's: HTTP %d %s", code, raw)
	}
	if code, _, raw, _ := personCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": map[string]any{}}, "?principal=Alice"); code != http.StatusForbidden {
		t.Fatalf("operator writes content: HTTP %d %s, want 403", code, raw)
	}
	code, v4, raw, _ := personCall(t, h, http.MethodPut, asOperator, map[string]any{"restore": 2}, "?principal=Alice")
	if code != 200 || v4.Version != 4 || v4.Actor != "operator" || !strings.Contains(string(v4.Bundle), "my-notes") {
		t.Fatalf("operator restores v2: HTTP %d %s, want version 4 by operator", code, raw)
	}
	if code, _, raw, _ := personCall(t, h, http.MethodGet, asOperator, nil, "?principal=nobody"); code != http.StatusNotFound {
		t.Fatalf("operator GET an unknown person: HTTP %d %s, want 404", code, raw)
	}

	// a login bound to no person has no personal layer
	for _, m := range []string{http.MethodGet, http.MethodPut} {
		if code, _, raw, _ := personCall(t, h, m, asNode(n["verk5"].token), personV1, ""); code != http.StatusNotFound || !strings.Contains(raw, "no person for this login") {
			t.Fatalf("verk@m5 %s: HTTP %d %s, want 404 no person for this login", m, code, raw)
		}
	}
	if code, _, _, _ := personCall(t, h, http.MethodGet, nil, nil, ""); code != http.StatusUnauthorized {
		t.Fatalf("no credential: HTTP %d, want 401", code)
	}
	// nothing B tried landed: A's history is exactly the four versions
	if _, got, _, _ := personCall(t, h, http.MethodGet, asSession("Alice"), nil, "?history=1"); len(got.History) != 4 {
		t.Fatalf("Alice's history after refusals: %+v", got.History)
	}
}

// hook_scripts is the personal layer's alone; the team still refuses it, and
// a program carries the same credential scan as everything else.
func TestPersonBundleHookScripts(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, personV1, ""); code != http.StatusUnprocessableEntity {
		t.Fatalf("team PUT with hook_scripts: HTTP %d %s, want 422", code, raw)
	}
	for name, s := range map[string]any{
		"bad name":     map[string]any{"../x": "echo"},
		"empty":        map[string]any{"x.sh": "  "},
		"not text":     map[string]any{"x.sh": 3},
		"over 32 KiB":  map[string]any{"x.sh": strings.Repeat("a", 33<<10)},
		"key in body":  map[string]any{"x.sh": "curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz' x"},
		"not a object": []any{"x"},
	} {
		code, _, raw, _ := personCall(t, h, http.MethodPut, asSession("wx-alice"), map[string]any{"bundle": map[string]any{"hook_scripts": s}}, "")
		if code != http.StatusUnprocessableEntity {
			t.Errorf("%s: HTTP %d %s, want 422", name, code, raw)
		}
	}
	if code, out, raw, _ := personCall(t, h, http.MethodPut, asSession("wx-alice"), personV1, ""); code != 200 || out.Version != 1 {
		t.Fatalf("a valid personal bundle: HTTP %d %s", code, raw)
	}
	// a session for someone the hub has no person for has no layer
	if code, _, raw, _ := personCall(t, h, http.MethodGet, asSession("wx-ghost"), nil, ""); code != http.StatusNotFound {
		t.Fatalf("unknown person's session: HTTP %d %s, want 404", code, raw)
	}
}

// A client-only computer reads and writes its person's layer by its
// connection certificate, signed under the personal namespace.
func TestPersonBundleByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	good := k.cert(t, "wecom:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(time.Hour))
	signed := func(ns string, msg func(int64) string) TeamBundleRequest {
		ts := now.Unix()
		return TeamBundleRequest{Cert: string(ssh.MarshalAuthorizedKey(good)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(msg(ts)))}
	}
	w := signed(control.PersonBundleSigNamespace, control.PersonBundleSigMessage)
	w.Bundle = json.RawMessage(`{"skills":{"my-notes":"# notes\n"}}`)
	code, out, raw, _ := personCall(t, h, http.MethodPut, nil, w, "")
	if code != 200 || out.Version != 1 || out.Actor != "wx-alice" {
		t.Fatalf("certificate PUT: HTTP %d %s, want version 1 by wx-alice", code, raw)
	}
	code, out, raw, _ = personCall(t, h, http.MethodPost, nil, signed(control.PersonBundleSigNamespace, control.PersonBundleSigMessage), "")
	if code != 200 || out.Version != 1 || !strings.Contains(string(out.Bundle), "my-notes") {
		t.Fatalf("certificate read: HTTP %d %s", code, raw)
	}
	if code, _, _, _ := personCall(t, h, http.MethodPost, nil, signed(control.TeamBundleSigNamespace, control.TeamBundleSigMessage), ""); code != http.StatusUnauthorized {
		t.Fatalf("a team signature: HTTP %d, want 401", code)
	}
	// the certificate's person is the only one it reaches
	h.srv.Store.AdoptPrincipal("wx-bob", "bob", "Bob", now)
	if code, _, raw, _ := personCall(t, h, http.MethodPost, nil, signed(control.PersonBundleSigNamespace, control.PersonBundleSigMessage), "?principal=wx-bob"); code != http.StatusForbidden {
		t.Fatalf("certificate reads Bob's: HTTP %d %s, want 403", code, raw)
	}
}

// Off is today's hub: no route, no table.
func TestPersonBundleOffAddsNothing(t *testing.T) {
	h := newHarness(t)
	// the catch-all UI answers every unknown path; no layer comes back
	if _, _, raw, _ := personCall(t, h, http.MethodGet, asOperator, nil, "?principal=alice"); strings.Contains(raw, `"bundle"`) {
		t.Fatalf("person-bundle answered with the fleet module off: %s", raw)
	}
	if _, err := h.srv.Store.PersonBundles("alice", 1); err == nil {
		t.Fatal("fleet_person_bundles exists although the fleet module is off")
	}
}
