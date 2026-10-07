package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
)

// 会话通行证 (claude-fleet#1969, EPIC #1967 C2): a pass for one person's one
// session, signed by the hub, verifiable, renewable, revocable at once.

const sessVerifier = "verifier-secret"

// sessHarness is twoNodes with passes on and m5's login (verk) a person;
// m4's login is nobody.
func sessHarness(t *testing.T) (*harness, string, string, string, string) {
	t.Helper()
	h, _, _, f5, f4 := twoNodes(t)
	h.srv.SessionCredKey = bytes.Repeat([]byte{9}, 32)
	h.srv.SessionCredVerifyToken = sessVerifier
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{7}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: &stubRefresher{}}
	p, err := h.srv.Store.AdoptPrincipal("gh:1005", "verk", "Verk", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.AdoptAccount(p, "m5", time.Now()); err != nil {
		t.Fatal(err)
	}
	return h, h.tokens["m5"], h.tokens["m4"], f5.FleetID, f4.FleetID
}

func sessDo(t *testing.T, h *harness, method, path, token, assertion string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if assertion != "" {
		req.Header.Set(workerAssertHeader, assertion)
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func sessIssue(t *testing.T, h *harness, tok, fleet string, body any) map[string]any {
	t.Helper()
	a := signWorkerAssertion(assertClaims(fleet, time.Now()), HashToken(tok))
	st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", tok, a, body)
	if st != 200 {
		t.Fatalf("issue: %d %v", st, out)
	}
	return out
}

func sessVerify(t *testing.T, h *harness, body map[string]any) map[string]any {
	t.Helper()
	st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/verify", sessVerifier, "", body)
	if st != 200 {
		t.Fatalf("verify: %d %v", st, out)
	}
	return out
}

func sessAudits(t *testing.T, h *harness) []auditRow {
	t.Helper()
	rows, err := h.srv.Store.DB().Query(`SELECT actor, worker_id, worker_key, outcome FROM fleet_audit WHERE action = 'session_cred' ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []auditRow
	for rows.Next() {
		var a auditRow
		if err := rows.Scan(&a.actor, &a.worker, &a.key, &a.outcome); err != nil {
			t.Fatal(err)
		}
		out = append(out, a)
	}
	return out
}

// A session whose statement holds gets a pass naming it, and verify answers
// for it: principal, worker_id, machine, providers, exp, not revoked. The
// issue is in fleet_audit with the session's worker_id.
func TestSessionCredIssueAndVerify(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, nil)
	cred, _ := out["cred"].(string)
	wid := assertClaims(f5, time.Now()).WorkerID
	if !strings.HasPrefix(cred, "fcp-h1.") || out["principal_id"] != "gh:1005" || out["worker_id"] != wid || out["machine"] != "m5" {
		t.Fatalf("issue = %v; want an fcp-h1. pass for gh:1005 / %s on m5", out, wid)
	}
	exp, _ := time.Parse(time.RFC3339, out["expires_at"].(string))
	if d := time.Until(exp); d < 23*time.Hour || d > 24*time.Hour+time.Minute {
		t.Fatalf("expires in %v; want the default 24 h", d)
	}
	renew, _ := time.Parse(time.RFC3339, out["renew_after"].(string))
	if exp.Sub(renew) != 2*time.Hour {
		t.Fatalf("renew_after %v is %v before exp; want 2 h", renew, exp.Sub(renew))
	}
	v := sessVerify(t, h, map[string]any{"cred": cred, "principal": "gh:1005", "provider": "claude"})
	if v["valid"] != true || v["revoked"] != false || v["principal"] != "gh:1005" || v["worker_id"] != wid ||
		v["machine"] != "m5" || v["exp"] == nil || len(v["providers"].([]any)) != 2 {
		t.Fatalf("verify = %v; want a valid pass for gh:1005", v)
	}
	// The operator may verify too; a node's token, or none, may not.
	if st, v := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/verify", viewerToken, "", map[string]any{"cred": cred}); st != 200 || v["valid"] != true {
		t.Fatalf("operator verify: %d %v", st, v)
	}
	for _, bad := range []string{"", tok5, "nope"} {
		if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/verify", bad, "", map[string]any{"cred": cred}); st != 401 {
			t.Fatalf("verify with %q: %d; want 401", bad, st)
		}
	}
	a := sessAudits(t, h)
	if len(a) != 1 || a[0].actor != "node:verk@m5" || a[0].worker != wid || a[0].key != "issue-1" ||
		!strings.HasPrefix(a[0].outcome, "issued sc_") {
		t.Fatalf("audit = %+v; want one issued row for %s", a, wid)
	}
	t.Logf("audit: actor=%s worker_id=%s outcome=%s", a[0].actor, a[0].worker, a[0].outcome)
	// The operator's list names it — and carries no pass.
	st, l := sessDo(t, h, http.MethodGet, "/v1/fleet/session-cred", viewerToken, "", nil)
	raw, _ := json.Marshal(l)
	if st != 200 || len(l["session_creds"].([]any)) != 1 || strings.Contains(string(raw), "fcp-h1.") {
		t.Fatalf("list: %d %s", st, raw)
	}
}

// Issued only to a statement that holds: none, forged (another node's key),
// a fleet this node does not run, a login that is nobody — all refused, and
// no pass is recorded.
func TestSessionCredIssueOnlyForTrueStatement(t *testing.T) {
	h, tok5, tok4, f5, f4 := sessHarness(t)
	now := time.Now()
	cases := []struct {
		name, tok, assertion string
		want                 int
	}{
		{"no assertion", tok5, "", 401},
		{"another node's key", tok5, signWorkerAssertion(assertClaims(f5, now), HashToken(tok4)), 401},
		{"tampered", tok5, signWorkerAssertion(assertClaims(f5, now), HashToken(tok5)) + "x", 401},
		{"m4's fleet, signed by m5", tok5, signWorkerAssertion(assertClaims(f4, now), HashToken(tok5)), 404},
		{"a login that is nobody", tok4, signWorkerAssertion(assertClaims(f4, now), HashToken(tok4)), 403},
		{"not a node", viewerToken, signWorkerAssertion(assertClaims(f5, now), HashToken(tok5)), 401},
	}
	for _, c := range cases {
		st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", c.tok, c.assertion, nil)
		if st != c.want || out["cred"] != nil {
			t.Errorf("%s: %d %v; want %d and no pass", c.name, st, out, c.want)
		}
	}
	if rows, _ := h.srv.Store.SessionCreds(false, now, 100); len(rows) != 0 {
		t.Fatalf("passes recorded: %+v", rows)
	}
	// A machine / person revoked gets none either.
	if st, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m5"}); st != 200 {
		t.Fatalf("revoke m5: %d %v", st, out)
	}
	if st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", tok5,
		signWorkerAssertion(assertClaims(f5, now), HashToken(tok5)), nil); st != 403 || out["error"] != LeaseRevoked {
		t.Fatalf("revoked machine: %d %v; want 403 revoked", st, out)
	}
	// Bad arguments.
	a := signWorkerAssertion(assertClaims(f5, now), HashToken(tok5))
	h.srv.Store.Unrevoke("m5", "")
	for _, body := range []map[string]any{{"providers": []string{"github"}}, {"ttl_seconds": 60}, {"ttl_seconds": 90000}} {
		if st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", tok5, a, body); st != 400 {
			t.Errorf("%v: %d %v; want 400", body, st, out)
		}
	}
}

// reclaim rewrites a pass's claims, keeping the signature — what a forger who
// lacks the key can do.
func reclaim(t *testing.T, cred string, edit func(*sessionCredClaims)) string {
	t.Helper()
	parts := strings.Split(cred, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var c sessionCredClaims
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	edit(&c)
	b, _ := json.Marshal(c)
	return parts[0] + "." + base64.RawURLEncoding.EncodeToString(b) + "." + parts[2]
}

// Forged, expired, revoked, another person's — every one fails verify.
func TestSessionCredVerifyRefuses(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	cred := sessIssue(t, h, tok5, f5, map[string]any{"providers": []string{"claude"}})["cred"].(string)
	parts := strings.Split(cred, ".")
	raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
	var c sessionCredClaims
	_ = json.Unmarshal(raw, &c)
	expired := c
	expired.Iat, expired.Exp = time.Now().Add(-25*time.Hour).Unix(), time.Now().Add(-time.Hour).Unix()
	unknown := c
	unknown.ID = "sc_nosuch"
	cases := map[string]map[string]any{
		"another key":            {"cred": signSessionCred(c, bytes.Repeat([]byte{1}, 32))},
		"principal rewritten":    {"cred": reclaim(t, cred, func(c *sessionCredClaims) { c.Principal = "gh:1006" })},
		"exp rewritten":          {"cred": reclaim(t, cred, func(c *sessionCredClaims) { c.Exp += 3600 })},
		"expired":                {"cred": signSessionCred(expired, h.srv.SessionCredKey)},
		"never issued":           {"cred": signSessionCred(unknown, h.srv.SessionCredKey)},
		"another principal":      {"cred": cred, "principal": "gh:1006"},
		"provider not covered":   {"cred": cred, "provider": "codex"},
		"malformed":              {"cred": "fcp-h1.e30"},
		"the node's prefix only": {"cred": "fcp1." + parts[1] + "." + parts[2]},
	}
	for name, body := range cases {
		if v := sessVerify(t, h, body); v["valid"] != false || v["reason"] == "" {
			t.Errorf("%s: %v; want invalid with a reason", name, v)
		} else {
			t.Logf("%-22s → %v", name, v["reason"])
		}
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != true {
		t.Fatalf("the genuine pass: %v", v)
	}
	// Revoked by the operator: invalid, and says revoked.
	id := c.ID
	if st, out := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id+"?reason=test", viewerToken, "", nil); st != 200 || out["revoked"] != true {
		t.Fatalf("operator revoke: %d %v", st, out)
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != false || v["revoked"] != true {
		t.Fatalf("revoked: %v; want invalid + revoked", v)
	}
}

// Revocation is at once through the hub's routes (the pass's own DELETE, a
// machine / person revoke), and within sessionCredCacheTTL ≤ 30 s when it
// happened elsewhere (another replica, the store directly).
func TestSessionCredRevokeTakesEffect(t *testing.T) {
	if sessionCredCacheTTL > 30*time.Second {
		t.Fatalf("verify cache %v; the contract is ≤ 30 s", sessionCredCacheTTL)
	}
	h, tok5, tok4, f5, _ := sessHarness(t)

	// The issuing node's DELETE (the session wrapper at exit): at once.
	out := sessIssue(t, h, tok5, f5, nil)
	cred, id := out["cred"].(string), out["id"].(string)
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != true {
		t.Fatalf("before: %v", v)
	}
	if st, _ := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok4, "", nil); st != 404 {
		t.Fatalf("another node revoking m5's pass: %d; want 404", st)
	}
	if st, out := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil); st != 200 || out["already"] != false {
		t.Fatalf("node revoke: %d %v", st, out)
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != false || v["revoked"] != true {
		t.Fatalf("right after DELETE: %v; want revoked", v)
	}

	// Revoked behind this hub's back: the cache holds it ≤ 30 s, no longer.
	out = sessIssue(t, h, tok5, f5, nil)
	cred, id = out["cred"].(string), out["id"].(string)
	now := time.Now()
	if v, _ := h.srv.verifySessionCred(cred, "", "", false, now); !v.Valid {
		t.Fatalf("before: %+v", v)
	}
	if ok, err := h.srv.Store.RevokeSessionCred(id, "elsewhere", "", now); !ok || err != nil {
		t.Fatalf("store revoke: %v %v", ok, err)
	}
	if v, _ := h.srv.verifySessionCred(cred, "", "", false, now.Add(time.Second)); !v.Valid {
		t.Logf("(cache already re-read: %+v)", v)
	}
	if v, _ := h.srv.verifySessionCred(cred, "", "", false, now.Add(sessionCredCacheTTL)); v.Valid || !v.Revoked {
		t.Fatalf("%v after a revocation elsewhere: %+v; want revoked", sessionCredCacheTTL, v)
	}

	// The machine revoked by the operator: every pass of it stops at once.
	out = sessIssue(t, h, tok5, f5, nil)
	cred = out["cred"].(string)
	_ = sessVerify(t, h, map[string]any{"cred": cred}) // cached valid
	if st, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m5", Reason: "lost"}); st != 200 {
		t.Fatalf("revoke m5: %d %v", st, out)
	}
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != false || v["revoked"] != true {
		t.Fatalf("after the machine's revocation: %v; want revoked", v)
	}
	a := sessAudits(t, h)
	if len(a) != 4 || !strings.HasPrefix(a[1].outcome, "revoked sc_") || a[1].actor != "node:verk@m5" {
		t.Fatalf("audit = %+v; want issue, the node's revoke, two issues", a)
	}
}

// Renewal: the issuing node, a live pass → the same pass id with a fresh
// expiry, no session restart. Anyone else, or a revoked pass, gets nothing.
func TestSessionCredRenew(t *testing.T) {
	h, tok5, tok4, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, map[string]any{"ttl_seconds": 600})
	cred, id := out["cred"].(string), out["id"].(string)
	if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok4, "", map[string]any{"cred": cred}); st != 404 {
		t.Fatalf("renew by another node: %d; want 404", st)
	}
	st, r := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": cred})
	if st != 200 || r["id"] != id || r["cred"] == nil {
		t.Fatalf("renew: %d %v", st, r)
	}
	if v := sessVerify(t, h, map[string]any{"cred": r["cred"]}); v["valid"] != true || v["id"] != id {
		t.Fatalf("renewed pass: %v", v)
	}
	row, _ := h.srv.Store.SessionCredByID(id)
	if row.RenewedAt == nil || time.Until(row.ExpiresAt) < 9*time.Minute {
		t.Fatalf("row after renew: %+v", row)
	}
	_, _ = sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil)
	if st, _ := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok5, "", map[string]any{"cred": r["cred"]}); st != 403 {
		t.Fatalf("renew a revoked pass: %d; want 403", st)
	}
}

// A trusted machine may ask for a pass too (one interface): m5 is trusted by
// the migration and still gets one, and its lease is untouched by the call.
func TestSessionCredTrustedMachineToo(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	set, err := h.srv.trustSettings(time.Now())
	if err != nil || trustOf("m5", set) != TrustTrusted {
		t.Fatalf("m5 trust = %v (%v); want trusted by the migration", trustOf("m5", set), err)
	}
	sessIssue(t, h, tok5, f5, nil)
	if a := sessAudits(t, h); len(a) != 1 || !strings.HasSuffix(a[0].outcome, "· trusted") {
		t.Fatalf("audit = %+v; want the issue on a trusted machine", a)
	}
}

// No key: every route answers 503 session_cred_off, nothing is recorded.
func TestSessionCredOffAddsNothing(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	h.srv.SessionCredKey = nil
	a := signWorkerAssertion(assertClaims(f5, time.Now()), HashToken(tok5))
	for _, c := range []struct{ method, path, tok string }{
		{http.MethodPost, "/v1/fleet/session-cred", tok5},
		{http.MethodGet, "/v1/fleet/session-cred", viewerToken},
		{http.MethodPost, "/v1/fleet/session-cred/verify", sessVerifier},
		{http.MethodPost, "/v1/fleet/session-cred/renew", tok5},
		{http.MethodDelete, "/v1/fleet/session-cred/sc_x", tok5},
	} {
		if st, out := sessDo(t, h, c.method, c.path, c.tok, a, map[string]any{"cred": "x"}); st != 503 || out["error"] != SessionCredOff {
			t.Errorf("%s %s: %d %v; want 503 %s", c.method, c.path, st, out, SessionCredOff)
		}
	}
	if rows, _ := h.srv.Store.SessionCreds(false, time.Now(), 10); len(rows) != 0 || len(sessAudits(t, h)) != 0 {
		t.Fatal("a pass or an audit row with passes off")
	}
}

// A client-only computer runs no fleet (claude-fleet#2136): its session names
// the fleet UUID derived from its own node token, and gets a pass as the
// node's login. Another node cannot name it, and an unregistered UUID that is
// not this derivation is still no such session.
func TestSessionCredClientComputer(t *testing.T) {
	h, tok5, tok4, _, _ := sessHarness(t)
	now := time.Now()
	cf := fleetid.ClientFleetID(HashToken(tok5))
	out := sessIssue(t, h, tok5, cf, map[string]any{"providers": []string{"claude"}})
	if !strings.HasPrefix(out["cred"].(string), "fcp-h1.") {
		t.Fatalf("no pass: %v", out)
	}
	v := sessVerify(t, h, map[string]any{"cred": out["cred"]})
	if v["valid"] != true || v["worker_id"] != fleetid.WorkerID(cf, assertFid) || v["machine"] != "m5" {
		t.Fatalf("verify: %v", v)
	}
	for name, c := range map[string]struct{ tok, fleet string }{
		"m5's client fleet, signed by m4":  {tok4, cf},
		"an unregistered, underived fleet": {tok5, fleetid.ClientFleetID("someone-else")},
	} {
		a := signWorkerAssertion(assertClaims(c.fleet, now), HashToken(c.tok))
		if st, out := sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred", c.tok, a, nil); st != 404 || out["cred"] != nil {
			t.Errorf("%s: %d %v; want 404 and no pass", name, st, out)
		}
	}
}

// A lapsed pass (claude-fleet#2012): the machine slept through the renew
// window, so the session's pass ran out while the session lives. Verify
// still refuses it; its issuing node may renew it within the grace — from
// the string the session was born with, too — and not past it, nor once
// revoked.
func TestSessionCredRenewLapsed(t *testing.T) {
	h, tok5, tok4, f5, _ := sessHarness(t)
	out := sessIssue(t, h, tok5, f5, map[string]any{"ttl_seconds": 600})
	born, id := out["cred"].(string), out["id"].(string)
	lapse := func(ago time.Duration) string {
		t.Helper()
		exp := time.Now().Add(-ago).Truncate(time.Second)
		if _, err := h.srv.Store.DB().Exec(`UPDATE fleet_session_creds SET expires_at = ? WHERE id = ?`,
			exp.UTC().Format("2006-01-02T15:04:05Z"), id); err != nil {
			t.Fatal(err)
		}
		h.srv.sessCred.drop(id)
		parts := strings.Split(born, ".")
		raw, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var c sessionCredClaims
		_ = json.Unmarshal(raw, &c)
		c.Iat, c.Exp = exp.Add(-600*time.Second).Unix(), exp.Unix()
		return signSessionCred(c, h.srv.SessionCredKey)
	}
	renew := func(tok, cred string) (int, map[string]any) {
		return sessDo(t, h, http.MethodPost, "/v1/fleet/session-cred/renew", tok, "", map[string]any{"cred": cred})
	}

	cred := lapse(10 * time.Hour)
	if v := sessVerify(t, h, map[string]any{"cred": cred}); v["valid"] != false {
		t.Fatalf("a lapsed pass verifies: %v", v)
	}
	if st, _ := renew(tok4, cred); st != 404 {
		t.Fatalf("lapsed, renewed by another node: %d; want 404", st)
	}
	st, r := renew(tok5, cred)
	if st != 200 || r["id"] != id {
		t.Fatalf("renew a pass lapsed 10 h ago: %d %v; want 200", st, r)
	}
	if v := sessVerify(t, h, map[string]any{"cred": r["cred"]}); v["valid"] != true {
		t.Fatalf("the renewed lapsed pass: %v", v)
	}
	if row, _ := h.srv.Store.SessionCredByID(id); time.Until(row.ExpiresAt) < 9*time.Minute {
		t.Fatalf("row after renewing a lapsed pass: %+v", row)
	}
	if a := sessAudits(t, h); !strings.Contains(a[len(a)-1].outcome, "(lapsed)") {
		t.Fatalf("audit = %+v; want the renewal marked lapsed", a)
	}

	// The string the session was born with: the grace runs from the record.
	_ = lapse(time.Hour)
	if st, r := renew(tok5, born); st != 200 || r["id"] != id {
		t.Fatalf("renew from the born string, record lapsed 1 h: %d %v", st, r)
	}

	if st, _ := renew(tok5, lapse(SessionCredRenewGrace+time.Hour)); st != 403 {
		t.Fatalf("renew a pass lapsed past the grace: %d; want 403", st)
	}

	cred = lapse(time.Hour)
	_, _ = sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil)
	if st, _ := renew(tok5, cred); st != 403 {
		t.Fatalf("renew a revoked lapsed pass: %d; want 403", st)
	}
}
