package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The service door (claude-fleet#4003): a service principal's fcs_ token opens
// /v1/svc/ scope by scope, and nothing else on the hub.

// svcAdmin posts one op to /v1/fleet/svc with the viewer token (an admin's door).
func svcAdmin(t *testing.T, h *harness, req SvcAdminRequest) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(req)
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+SvcAdminPath, bytes.NewReader(b))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

// svcCall asks path with bearer tok; the status alone.
func svcCall(t *testing.T, h *harness, method, path, tok string) int {
	t.Helper()
	r, _ := http.NewRequest(method, h.http.URL+path, nil)
	if tok != "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	return res.StatusCode
}

// svcSetup makes svc:<name> with scopes and issues one token.
func svcSetup(t *testing.T, h *harness, name, scopes string) string {
	t.Helper()
	if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "create", Principal: name, Scopes: scopes}); st != http.StatusCreated {
		t.Fatalf("create %s: %d %v", name, st, out)
	}
	return svcIssue(t, h, name)
}

func svcIssue(t *testing.T, h *harness, name string) string {
	t.Helper()
	st, out := svcAdmin(t, h, SvcAdminRequest{Op: "issue", Principal: name})
	if st != http.StatusCreated {
		t.Fatalf("issue %s: %d %v", name, st, out)
	}
	tok, _ := out["token"].(string)
	if _, ok := svcTokenPrefix(tok); !ok {
		t.Fatalf("issued token %q is not fcs_<prefix8>_<secret>", tok)
	}
	return tok
}

func svcAudited(t *testing.T, h *harness, action, outcome string) bool {
	t.Helper()
	rows, err := h.srv.Store.FleetAuditLog(500)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Action == action && (outcome == "" || r.Outcome == outcome) {
			return true
		}
	}
	return false
}

func TestSvcTokenShape(t *testing.T) {
	tok, prefix, err := MintSvcToken()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(tok, "fcs_"+prefix+"_") || len(prefix) != 8 {
		t.Fatalf("token %q prefix %q", tok, prefix)
	}
	if p, ok := svcTokenPrefix(tok); !ok || p != prefix {
		t.Fatalf("parse %q = %q %v", tok, p, ok)
	}
	for _, bad := range []string{"", "fcs_", "fcs_zzzzzzzz_x", "fcs_0123456x_x", "ccq_abc", "fcs_01234567x"} {
		if _, ok := svcTokenPrefix(bad); ok {
			t.Errorf("%q parsed as a service token", bad)
		}
	}
}

// A token without the route's scope is 403; with it, the call goes through.
func TestSvcScopeForbidden(t *testing.T) {
	h := newFleetHarness(t)
	tok := svcSetup(t, h, "reader", "runs:read")
	ok := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	for scope, want := range map[string]int{store.SvcRunsWrite: http.StatusForbidden,
		store.SvcTemplatesWrite: http.StatusForbidden, store.SvcRunsRead: http.StatusNoContent} {
		hd := h.srv.svcGate(h.srv.svcOnly(scope, ok))
		r := httptest.NewRequest(http.MethodPost, "/v1/svc/runs", nil)
		r.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		hd.ServeHTTP(w, r)
		if w.Code != want {
			t.Errorf("scope %s: %d, want %d", scope, w.Code, want)
		}
	}
	if !svcAudited(t, h, "svc.call", "FORBIDDEN") || !svcAudited(t, h, "svc.call", "ok") {
		t.Error("the scoped calls left no svc.call audit rows")
	}
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusOK {
		t.Errorf("whoami with a live token: %d", st)
	}
}

// Revoked: the very next call is 401, on every /v1/svc/ path.
func TestSvcRevokedIs401(t *testing.T) {
	h := newFleetHarness(t)
	tok := svcSetup(t, h, "livepage", "runs:write runs:read templates:write")
	prefix, _ := svcTokenPrefix(tok)
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusOK {
		t.Fatalf("whoami before the revoke: %d", st)
	}
	if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "revoke", Prefix: prefix, Reason: "drill"}); st != http.StatusOK {
		t.Fatalf("revoke: %d %v", st, out)
	}
	for _, p := range []string{SvcWhoamiPath, "/v1/svc/runs", "/v1/svc/runs/R1"} {
		if st := svcCall(t, h, http.MethodGet, p, tok); st != http.StatusUnauthorized {
			t.Errorf("%s after the revoke: %d, want 401", p, st)
		}
	}
	if !svcAudited(t, h, "svc.token.revoke", "ok") || !svcAudited(t, h, "svc.call", "REVOKED") {
		t.Error("the revoke or the refused call left no audit row")
	}
	// A second revoke keeps the first one's time.
	t1, _ := h.srv.Store.SvcTokenByPrefix(prefix)
	svcAdmin(t, h, SvcAdminRequest{Op: "revoke", Prefix: prefix})
	t2, _ := h.srv.Store.SvcTokenByPrefix(prefix)
	if t1.RevokedAt == nil || t2.RevokedAt == nil || !t1.RevokedAt.Equal(*t2.RevokedAt) {
		t.Errorf("revoked_at moved: %v → %v", t1.RevokedAt, t2.RevokedAt)
	}
	// No token at all, a made-up one: 401 as well.
	for _, bad := range []string{"", "fcs_00000000_nope", viewerToken} {
		if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, bad); st != http.StatusUnauthorized {
			t.Errorf("whoami with %q: %d, want 401", bad, st)
		}
	}
}

// With the list on, a revoke also lands on #3560's revocation list.
func TestSvcRevokeOnRevocationList(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.RevocationsToken = revTok
	tok := svcSetup(t, h, "listed", "runs:read")
	prefix, _ := svcTokenPrefix(tok)
	svcAdmin(t, h, SvcAdminRequest{Op: "revoke", Prefix: prefix})
	_, list := revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	if !revHas(list, "fcs:"+prefix) {
		t.Fatalf("fcs:%s not on the list: %+v", prefix, list.Entries)
	}
}

// Rotation: two live tokens at once, both open the door; never a third.
func TestSvcRotationTwoLive(t *testing.T) {
	h := newFleetHarness(t)
	a := svcSetup(t, h, "rot", "runs:read")
	b := svcIssue(t, h, "rot")
	for _, tok := range []string{a, b} {
		if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusOK {
			t.Errorf("a rotating token: %d", st)
		}
	}
	if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "issue", Principal: "rot"}); st != http.StatusConflict {
		t.Fatalf("a third live token: %d %v", st, out)
	}
	pa, _ := svcTokenPrefix(a)
	svcAdmin(t, h, SvcAdminRequest{Op: "revoke", Prefix: pa})
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, a); st != http.StatusUnauthorized {
		t.Errorf("the old token after the rotation: %d", st)
	}
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, b); st != http.StatusOK {
		t.Errorf("the new token after the rotation: %d", st)
	}
	svcIssue(t, h, "rot") // room again
}

// Disabled: every token of the principal is 401 until it is enabled again.
func TestSvcDisable(t *testing.T) {
	h := newFleetHarness(t)
	tok := svcSetup(t, h, "sw", "runs:read")
	svcAdmin(t, h, SvcAdminRequest{Op: "disable", Principal: "sw"})
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusUnauthorized {
		t.Errorf("disabled: %d", st)
	}
	svcAdmin(t, h, SvcAdminRequest{Op: "enable", Principal: "sw"})
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusOK {
		t.Errorf("enabled again: %d", st)
	}
}

// Expired: 401.
func TestSvcExpired(t *testing.T) {
	h := newFleetHarness(t)
	svcSetup(t, h, "old", "runs:read")
	now := time.Now()
	tok, _, err := SvcIssue(h.srv.Store, "old", 1, "test", now.Add(-48*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != http.StatusUnauthorized {
		t.Errorf("expired: %d", st)
	}
}

// The database holds the hash and the prefix, never the token or its secret.
func TestSvcOnlyHashStored(t *testing.T) {
	h := newFleetHarness(t)
	tok := svcSetup(t, h, "hashed", "runs:read")
	// The secret is base64url, which may itself hold a "_": cut after the
	// prefix, never at the last "_" (a one-letter tail matched "svc:hashed").
	secret := tok[len(svcTokenWord)+svcPrefixLen+1:]
	rows, err := h.srv.Store.DB().Query(`SELECT prefix, sha256, principal, created, expires, revoked_at, last_used FROM svc_tokens`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	n := 0
	for rows.Next() {
		var c [7]string
		if err := rows.Scan(&c[0], &c[1], &c[2], &c[3], &c[4], &c[5], &c[6]); err != nil {
			t.Fatal(err)
		}
		n++
		if c[1] != HashToken(tok) {
			t.Errorf("sha256 column %q is not the token's hash", c[1])
		}
		for _, v := range c {
			if strings.Contains(v, secret) || strings.Contains(v, tok) {
				t.Errorf("a column holds the token: %q", v)
			}
		}
	}
	if n != 1 {
		t.Fatalf("%d token rows, want 1", n)
	}
	// GET lists the tokens without any secret either.
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+SvcAdminPath, nil)
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || strings.Contains(string(body), secret) || strings.Contains(string(body), HashToken(tok)) {
		t.Fatalf("GET %s: %d %s", SvcAdminPath, res.StatusCode, body)
	}
}

// svcHubRoutes is every /v1/fleet/* and /v1/node/* path the api package spells.
func svcHubRoutes(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`"(/v1/(?:fleet|node)/[A-Za-z0-9_./-]*)"`)
	seen := map[string]bool{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range re.FindAllStringSubmatch(string(b), -1) {
			p := m[1]
			if strings.HasSuffix(p, "/") {
				p += "x"
			}
			seen[p] = true
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	if len(out) < 40 {
		t.Fatalf("found only %d hub routes in the source — the scan is broken", len(out))
	}
	return out
}

// BREAK-IT svc-token-escalate: a service token with every scope, against
// every admin and node route, gets nothing more than no credential gets —
// never a 2xx where a stranger is refused — and the admin road itself is 401.
func TestSvcTokenEscalate(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.RevocationsToken = revTok
	tok := svcSetup(t, h, "escalate", "runs:write runs:read templates:write")
	cl := &http.Client{Timeout: 3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	do := func(method, path, bearer string) (int, error) {
		r, _ := http.NewRequest(method, h.http.URL+path, strings.NewReader("{}"))
		r.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		res, err := cl.Do(r)
		if err != nil {
			return 0, err
		}
		res.Body.Close()
		return res.StatusCode, nil
	}
	routes := svcHubRoutes(t)
	checked := 0
	for _, p := range routes {
		for _, m := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete} {
			base, berr := do(m, p, "")
			got, gerr := do(m, p, tok)
			if berr != nil || gerr != nil {
				continue // a long poll a stranger is held on too
			}
			checked++
			if got/100 == 2 && base/100 != 2 {
				t.Errorf("%s %s: the service token got %d where no credential gets %d", m, p, got, base)
			}
		}
	}
	if checked < 100 {
		t.Fatalf("only %d route calls answered", checked)
	}
	for _, m := range []string{http.MethodGet, http.MethodPost} {
		if st, _ := do(m, SvcAdminPath, tok); st != http.StatusUnauthorized {
			t.Errorf("%s %s with a service token: %d, want 401", m, SvcAdminPath, st)
		}
	}
	if testing.Verbose() {
		fmt.Printf("svc-token-escalate: %d routes, %d calls\n", len(routes), checked)
	}
}
