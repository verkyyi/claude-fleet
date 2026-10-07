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

// The team configuration layer (claude-fleet#1726).

func teamCall(t *testing.T, h *harness, method string, auth func(http.Header), body any, query string) (int, TeamBundleResponse, string, http.Header) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.TeamBundlePath+query, rd)
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

func asNode(tok string) func(http.Header) {
	return func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+tok) }
}

var teamV1 = map[string]any{"bundle": map[string]any{
	"mcp":          map[string]any{"docs-ro": map[string]any{"command": "npx", "args": []string{"-y", "docs-mcp", "--read-only"}}},
	"codex_config": map[string]any{"model_reasoning_effort": "high"},
}}

// PUT is the operator's: a person's session, a node token and a
// certificate are refused; every PUT is a version; a rollback is a PUT.
func TestTeamBundlePutOperatorOnlyVersionsRollback(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob, pCarol)
	node := h.enroll(t, "m5")

	// nothing yet: version 0, an empty layer, for every reader
	for name, auth := range map[string]func(http.Header){"operator": asOperator, "person": asSession(pAlice), "node": asNode(node)} {
		code, out, raw, _ := teamCall(t, h, http.MethodGet, auth, nil, "")
		if code != 200 || out.Version != 0 || string(out.Bundle) != "{}" {
			t.Fatalf("%s before any PUT: HTTP %d %s, want version 0 and {}", name, code, raw)
		}
	}
	if code, _, _, _ := teamCall(t, h, http.MethodGet, nil, nil, ""); code != http.StatusUnauthorized {
		t.Fatalf("no credential: HTTP %d, want 401", code)
	}

	for name, auth := range map[string]func(http.Header){"person": asSession(pAlice), "node": asNode(node)} {
		if code, _, raw, _ := teamCall(t, h, http.MethodPut, auth, teamV1, ""); code != http.StatusForbidden {
			t.Fatalf("%s PUT: HTTP %d %s, want 403", name, code, raw)
		}
	}

	code, v1, raw, _ := teamCall(t, h, http.MethodPut, asOperator, teamV1, "")
	if code != 200 || v1.Version != 1 || v1.Prev != 0 || !strings.Contains(string(v1.Bundle), "docs-ro") {
		t.Fatalf("operator PUT: HTTP %d %s, want version 1", code, raw)
	}
	v2body := map[string]any{"base": 1, "bundle": map[string]any{"skills": map[string]any{"team-notes": "# notes\n"}}}
	code, v2, raw, _ := teamCall(t, h, http.MethodPut, asOperator, v2body, "")
	if code != 200 || v2.Version != 2 || v2.Prev != 1 {
		t.Fatalf("second PUT: HTTP %d %s, want version 2 prev 1", code, raw)
	}
	// a stale base never overwrites
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": v2body["bundle"]}, ""); code != 200 {
		t.Fatalf("PUT with no base check is fine: HTTP %d %s", code, raw)
	}
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"base": 1, "bundle": map[string]any{}}, ""); code != http.StatusConflict {
		t.Fatalf("stale base: HTTP %d %s, want 409", code, raw)
	}

	// rollback = a PUT of version 1's body, as a new version
	code, v4, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"restore": 1}, "")
	if code != 200 || v4.Version != 4 || v4.Prev != 3 || !strings.Contains(string(v4.Bundle), "docs-ro") || strings.Contains(string(v4.Bundle), "team-notes") {
		t.Fatalf("restore 1: HTTP %d %s, want version 4 carrying v1's body", code, raw)
	}
	code, cur, _, hdr := teamCall(t, h, http.MethodGet, asNode(node), nil, "")
	if code != 200 || cur.Version != 4 || hdr.Get("ETag") != `"team-v4"` {
		t.Fatalf("node reads after restore: HTTP %d v%d etag %s", code, cur.Version, hdr.Get("ETag"))
	}
	// unchanged → 304
	code, _, _, _ = teamCall(t, h, http.MethodGet, func(hd http.Header) { asNode(node)(hd); hd.Set("If-None-Match", `"team-v4"`) }, nil, "")
	if code != http.StatusNotModified {
		t.Fatalf("If-None-Match the current version: HTTP %d, want 304", code)
	}
	code, old, _, _ := teamCall(t, h, http.MethodGet, asOperator, nil, "?version=2")
	if code != 200 || old.Version != 2 || !strings.Contains(string(old.Bundle), "team-notes") {
		t.Fatalf("?version=2: HTTP %d v%d", code, old.Version)
	}
	code, hist, _, _ := teamCall(t, h, http.MethodGet, asOperator, nil, "?history=1")
	if code != 200 || len(hist.History) != 4 || hist.History[0].Version != 4 {
		t.Fatalf("history: HTTP %d %+v", code, hist.History)
	}
	if code, _, _, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"restore": 9}, ""); code != http.StatusNotFound {
		t.Fatalf("restore of a version that never was: HTTP %d, want 404", code)
	}
}

// A credential never enters the layer, and nothing outside the allow-list does.
func TestTeamBundleRefusesSecretsAndUnknownKeys(t *testing.T) {
	h := newFleetHarness(t)
	for name, b := range map[string]map[string]any{
		"env token":        {"mcp": map[string]any{"gh": map[string]any{"command": "x", "env": map[string]any{"GITHUB_TOKEN": "abc123"}}}},
		"ghp in args":      {"mcp": map[string]any{"gh": map[string]any{"command": "x", "args": []string{"--t", "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}},
		"anthropic key":    {"claude_settings": map[string]any{"env": map[string]any{"X": "sk-ant-api03-abcdefghij"}}},
		"bearer header":    {"mcp": map[string]any{"web": map[string]any{"url": "https://x", "headers": map[string]any{"X-Y": "Bearer abcdefghijklmnopqrstuvwxyz"}}}},
		"password in hook": {"hooks": map[string]any{"Stop": []any{map[string]any{"command": "echo -----BEGIN RSA PRIVATE KEY-----"}}}},
		"api_key setting":  {"codex_config": map[string]any{"api_key": "abcdef"}},
		"unknown key":      {"accounts": map[string]any{}},
		"model":            {"codex_config": map[string]any{"model": "gpt-5"}},
		"apiKeyHelper":     {"claude_settings": map[string]any{"apiKeyHelper": "/bin/echo"}},
		"server no cmd":    {"mcp": map[string]any{"x": map[string]any{"args": []string{}}}},
		"bad hook event":   {"hooks": map[string]any{"OnBoot": []any{map[string]any{"command": "x"}}}},
	} {
		code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": b}, "")
		if code != http.StatusUnprocessableEntity {
			t.Errorf("%s: HTTP %d %s, want 422", name, code, raw)
		}
	}
	// a reference is not a credential: the value is read on each computer
	ok := map[string]any{"mcp": map[string]any{"gh": map[string]any{"command": "x", "env": map[string]any{"GITHUB_TOKEN": "${GITHUB_TOKEN}"}}}}
	if code, out, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": ok}, ""); code != 200 || out.Version != 1 {
		t.Fatalf("a ${VAR} reference: HTTP %d %s, want stored as version 1", code, raw)
	}
	// nothing refused was stored
	if _, cur, _, _ := teamCall(t, h, http.MethodGet, asOperator, nil, "?history=1"); len(cur.History) != 1 {
		t.Fatalf("refused bodies left versions behind: %+v", cur.History)
	}
}

// A client-only computer reads by its connection certificate; a certificate
// never writes.
func TestTeamBundleByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", now)
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, teamV1, ""); code != 200 {
		t.Fatalf("seed: HTTP %d %s", code, raw)
	}
	good := k.cert(t, sshca.KeyIDPrefix+pAlice, []string{"alice"}, now.Add(-time.Minute), now.Add(time.Hour))
	signed := func(ns string, msg func(int64) string, ts int64) TeamBundleRequest {
		return TeamBundleRequest{Cert: string(ssh.MarshalAuthorizedKey(good)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(msg(ts)))}
	}
	code, out, raw, _ := teamCall(t, h, http.MethodPost, nil, signed(control.TeamBundleSigNamespace, control.TeamBundleSigMessage, now.Unix()), "")
	if code != 200 || out.Version != 1 || !strings.Contains(string(out.Bundle), "docs-ro") {
		t.Fatalf("certificate read: HTTP %d %s", code, raw)
	}
	if code, _, _, _ := teamCall(t, h, http.MethodPost, nil, signed(control.SummarySigNamespace, control.SummarySigMessage, now.Unix()), ""); code != http.StatusUnauthorized {
		t.Fatalf("a summary signature: HTTP %d, want 401", code)
	}
	w := signed(control.TeamBundleSigNamespace, control.TeamBundleSigMessage, now.Unix())
	w.Bundle = json.RawMessage(`{}`)
	if code, _, _, _ := teamCall(t, h, http.MethodPut, nil, w, ""); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("a certificate PUT: HTTP %d, want refused", code)
	}
}
