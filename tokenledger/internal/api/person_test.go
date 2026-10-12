package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#3603 (EPIC #3570 C10): an account is not a GitHub account.

// The whole repo's Go spells "gh:" as a principal in ONE place — the GitHub
// identity's prefix (store.GitHubPrincipalPrefix) — and only github_auth.go
// makes or parses it (githubPrincipal / githubIDOf). Every "is this a
// person" asks isPerson. BREAK-IT account-gh-only-check.
func TestNoGHPrefixOutsideIdentity(t *testing.T) {
	root := filepath.Join("..", "..")
	literal := regexp.MustCompile(`"gh:"`)
	prefix := regexp.MustCompile(`\b(githubPrincipalPrefix|GitHubPrincipalPrefix)\b`)
	// Where each may appear, and why.
	literalOK := map[string]string{
		"internal/store/hub_users.go":   "the GitHub identity's prefix itself",
		"internal/api/fleet_tickets.go": "a ticket id, gh:<repo>#<N> (EPIC #3570 共同约定 1) — not a person",
	}
	prefixOK := map[string]bool{
		"internal/store/hub_users.go": true, // declares it; UpsertHubUser spells a GitHub person's
		"internal/api/github_auth.go": true, // githubPrincipal / githubIDOf
	}
	var bad []string
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			if n := info.Name(); n == "web" || n == "node_modules" || strings.HasPrefix(n, ".") && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		rel = filepath.ToSlash(rel)
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for i, line := range strings.Split(string(b), "\n") {
			code := line
			if c := strings.Index(code, "//"); c >= 0 {
				code = code[:c]
			}
			if literal.MatchString(code) {
				if _, ok := literalOK[rel]; !ok {
					bad = append(bad, rel+":"+itoa(i+1)+`: "gh:" — ask isPerson`)
				}
			}
			if prefix.MatchString(code) && !prefixOK[rel] {
				bad = append(bad, rel+":"+itoa(i+1)+": the GitHub principal prefix outside the identity — ask isPerson")
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(bad) > 0 {
		t.Fatalf("a principal is judged by its gh: spelling:\n  %s", strings.Join(bad, "\n  "))
	}
}

func TestIsPerson(t *testing.T) {
	p, err := newPersonPrincipal()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		pid  string
		want bool
	}{
		{"gh:1001", true}, {p, true},
		{"gh:", false}, {"gh:x", false}, {"p:nope", false}, {strings.ToUpper(p), false},
		{"someone", false}, {"wx:Zhang", false}, {store.PoolPrincipal, false}, {"", false},
	} {
		if got := isPerson(c.pid); got != c.want {
			t.Errorf("isPerson(%q) = %v, want %v", c.pid, got, c.want)
		}
	}
	if l := store.LoginBase(p, 32); !regexp.MustCompile(`^p[0-9a-f]+$`).MatchString(l) {
		t.Errorf("a p: person's minted login %q is not a plain name", l)
	}
}

// emailCookie is the session an address sign-in mints (C11's door): Sub
// email, UID the person.
func emailCookie(pid, name string) *http.Cookie {
	return &http.Cookie{Name: authz.CookieName, Value: authz.SignRole(store.IdentityEmail, pid, name, roleUser,
		(&GitHubAuth{ClientSecret: testGitHubSecret}).sessionKey(), time.Now(), time.Hour)}
}

func cookieDo(t *testing.T, h *harness, method, path string, c *http.Cookie, body []byte) (int, []byte) {
	t.Helper()
	r, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader(body))
	r.Header.Set("Origin", h.http.URL)
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	r.AddCookie(c)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

// A person with no GitHub walks the whole way: invited by address → signed
// in → a machine login bound → a certificate for it → their own /v1/me.
// Nobody uninvited gets a new account (共同约定 11), and a bound invite admits
// its own address only.
func TestPAccountInviteMachineCert(t *testing.T) {
	h, _ := certHarness(t)
	now := time.Now()
	mint := func(code, email string) {
		if err := h.srv.Store.CreateInvite(store.Invite{ID: "inv_" + code[:6], CodeHash: inviteHash(code), Email: email,
			CreatedBy: "admin (gh:100)", CreatedAt: now, ExpiresAt: now.Add(store.InviteTTL)}); err != nil {
			t.Fatal(err)
		}
	}
	const code, other = "danacodedanacodedana", "evecodeevecodeevecode"
	mint(code, "Dana@Example.com")
	mint(other, "")

	// No invite: refused, no account.
	if pid, role, why, err := h.srv.admitPerson(store.IdentityEmail, "eve@example.com", "Eve", "", now); err != nil || role != "" || why != denyNotListed || pid != "" {
		t.Fatalf("uninvited = %q %q %q %v; want a refusal and no account", pid, role, why, err)
	}
	// Someone else's address on Dana's invite: refused, the invite unspent.
	if _, role, why, _ := h.srv.admitPerson(store.IdentityEmail, "eve@example.com", "Eve", code, now); role != "" || why != denyInvitePrefix+store.InviteOtherUser {
		t.Fatalf("another address on a bound invite = %q %q", role, why)
	}
	if users, _ := h.srv.Store.HubUsers(); len(users) != 3 {
		t.Fatalf("refusals put someone on the list: %+v", users)
	}

	pid, role, why, err := h.srv.admitPerson(store.IdentityEmail, "dana@example.com", "Dana", code, now)
	if err != nil || role != roleUser || why != "" || !strings.HasPrefix(pid, personPrincipalPrefix) || !isPerson(pid) {
		t.Fatalf("Dana's sign-in = %q %q %q %v", pid, role, why, err)
	}
	if u, _ := h.srv.Store.HubUserByPrincipal(pid); u == nil || u.GitHubID != 0 || u.Login != "Dana" || u.Role != roleUser {
		t.Fatalf("Dana's row = %+v", u)
	}
	// The same address again is the same person, with no invite.
	if again, role, _, _ := h.srv.admitPerson(store.IdentityEmail, "DANA@example.com", "", "", now); again != pid || role != roleUser {
		t.Fatalf("Dana again = %q %q; want %s", again, role, pid)
	}

	// Bind a machine: the operator adopts her login there.
	if c := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pid, Hostname: "spare", Login: "dana"}); c != 200 {
		t.Fatalf("adopt dana: HTTP %d", c)
	}
	sess := emailCookie(pid, "Dana")
	code2, body := cookieDo(t, h, http.MethodGet, "/v1/me", sess, nil)
	var me Me
	_ = json.Unmarshal(body, &me)
	if code2 != 200 || me.Person != pid || me.Via != store.IdentityEmail || me.Role != roleUser || me.Login != "dana" {
		t.Fatalf("/v1/me = %d %s", code2, body)
	}

	// A certificate for exactly her login, named by the name she signed in with.
	req, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
	code2, body = cookieDo(t, h, http.MethodPost, "/v1/fleet/cert", sess, req)
	if code2 != 200 {
		t.Fatalf("cert: %d %s", code2, body)
	}
	var cr CertResponse
	_ = json.Unmarshal(body, &cr)
	c := parseCert(t, cr.Certificate)
	if c.KeyId != sshca.KeyIDPrefix+pid || len(c.ValidPrincipals) != 1 || c.ValidPrincipals[0] != "dana" || cr.Name != "Dana" {
		t.Fatalf("cert key id %q principals %v name %q", c.KeyId, c.ValidPrincipals, cr.Name)
	}
	if sshca.PrincipalOfKeyID(c.KeyId) != pid {
		t.Fatalf("the key id does not name her: %q", c.KeyId)
	}

	// Taken off the list: her next request is refused, as a GitHub person's is.
	if ok, err := h.srv.Store.DeleteHubPrincipal(pid); !ok || err != nil {
		t.Fatal(ok, err)
	}
	if code2, _ := cookieDo(t, h, http.MethodGet, "/v1/me", sess, nil); code2 == 200 {
		t.Fatalf("a removed person still reads /v1/me")
	}
}

// CCQUOTA_ADMINS names an admin by principal or by an address — someone
// CCQUOTA_GITHUB_ADMINS cannot name.
func TestAdminsByPrincipalOrAddress(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	a, _ := newPersonPrincipal()
	b, _ := newPersonPrincipal()
	for _, p := range []string{a, b} {
		listPerson(t, h, p, "x")
	}
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "boss@example.com", PrincipalID: b}); err != nil {
		t.Fatal(err)
	}
	if r, _ := h.srv.personRole(a); r != roleUser {
		t.Fatalf("no CCQUOTA_ADMINS: %q", r)
	}
	h.srv.Admins = []string{a, "Boss@Example.com"}
	for _, p := range []string{a, b} {
		if r, _ := h.srv.personRole(p); r != roleAdmin {
			t.Errorf("%s = %q, want admin", p, r)
		}
	}
	if r, _ := h.srv.personRole("gh:1001"); r != "" {
		t.Errorf("someone not on the list = %q", r)
	}
}

// 登录方式: listed, an address added (an admin vouching for their own), the
// last one never removed, one that lets someone else in never taken.
func TestMeIdentities(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	sess := personCookie(pAlice, "alice-gh")
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityGitHub, Subject: "1001", PrincipalID: pAlice}); err != nil {
		t.Fatal(err)
	}
	read := func(c int, b []byte) IdentitiesView {
		t.Helper()
		if c != 200 {
			t.Fatalf("HTTP %d %s", c, b)
		}
		var v IdentitiesView
		_ = json.Unmarshal(b, &v)
		return v
	}
	v := read(cookieDo(t, h, http.MethodGet, "/v1/me/identities", sess, nil))
	if v.Person != pAlice || len(v.Identities) != 1 || v.Identities[0].Kind != store.IdentityGitHub || len(v.CanAdd) != 0 {
		t.Fatalf("alice = %+v", v)
	}
	if c, _ := cookieDo(t, h, http.MethodDelete, "/v1/me/identities?kind=github&subject=1001", sess, nil); c != http.StatusConflict {
		t.Fatalf("removing the only way in = %d, want 409", c)
	}
	add, _ := json.Marshal(map[string]string{"kind": "email", "subject": "alice@example.com"})
	if c, _ := cookieDo(t, h, http.MethodPost, "/v1/me/identities", sess, add); c != http.StatusForbidden {
		t.Fatalf("a user adding an unproven address = %d, want 403", c)
	}

	h.srv.Admins = []string{pAlice}
	v = read(cookieDo(t, h, http.MethodGet, "/v1/me/identities", sess, nil))
	if len(v.CanAdd) != 1 || v.CanAdd[0] != store.IdentityEmail {
		t.Fatalf("an admin may add = %v", v.CanAdd)
	}
	v = read(cookieDo(t, h, http.MethodPost, "/v1/me/identities", sess, add))
	if len(v.Identities) != 2 || v.Identities[0].Kind != store.IdentityEmail || v.Identities[1].Kind != store.IdentityGitHub {
		t.Fatalf("after adding = %+v", v.Identities)
	}
	// The address now signs her in, as herself.
	if pid, role, _, _ := h.srv.admitPerson(store.IdentityEmail, "ALICE@example.com", "", "", time.Now()); pid != pAlice || role != roleAdmin {
		t.Fatalf("her address signs in %q as %q", pid, role)
	}
	// Someone else cannot take it.
	other, _ := newPersonPrincipal()
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "alice@example.com", PrincipalID: other}); err != store.ErrIdentityTaken {
		t.Fatalf("another person took her address: %v", err)
	}
	read(cookieDo(t, h, http.MethodDelete, "/v1/me/identities?kind=email&subject=alice%40example.com", sess, nil))

	// GitHub is linked by signing in with it: githubLink hangs it on her.
	b, _ := newPersonPrincipal()
	listPerson(t, h, b, "Bo")
	if err := h.srv.Store.AddHubIdentity(store.HubIdentity{Kind: store.IdentityEmail, Subject: "bo@example.com", PrincipalID: b}); err != nil {
		t.Fatal(err)
	}
	if to := h.srv.githubLink(b, 1001, "alice-gh", time.Now()); !strings.Contains(to, "e=taken") {
		t.Fatalf("linking alice's GitHub to bo went to %q", to)
	}
	if to := h.srv.githubLink(b, 4242, "bo-gh", time.Now()); to != AppPrefix+"/config#logins" {
		t.Fatalf("link = %q", to)
	}
	if pid, _ := h.srv.githubPersonOf(4242); pid != b {
		t.Fatalf("GitHub 4242 signs in %q, want %s", pid, b)
	}
	if r, _ := h.srv.personRole(b); r != roleUser {
		t.Fatalf("bo's role after linking = %q", r)
	}
}

// Migrating the people list leaves a GitHub person's world as it was:
// role, machine login, name, /v1/me, certificate and tasks — read before
// on the old table and after on the new one, the same.
func TestMigrationKeepsGitHubPerson(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hub.db")
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	ca := sshca.New(signer)
	serve := func(st *store.Store) *harness {
		srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(), Fleet: true,
			GitHub: &GitHubAuth{ClientID: "Iv1.test", ClientSecret: testGitHubSecret}, SSHCA: ca}
		ts := httptest.NewServer(srv.Handler())
		t.Cleanup(ts.Close)
		return &harness{srv: srv, http: ts, tokens: map[string]string{}}
	}
	st, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	h := serve(st)
	listPerson(t, h, pAlice, "alice-gh")
	if c := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "host-a", Login: "alice"}); c != 200 {
		t.Fatalf("adopt: %d", c)
	}
	if _, err := st.CreateFleetTask(store.FleetTask{Owner: pAlice, Title: "fix it", Via: "⌘P"}, "tok-3603", time.Now()); err != nil {
		t.Fatal(err)
	}
	snap := func(h *harness) string {
		t.Helper()
		role, _ := h.srv.personRole(pAlice)
		ml, _ := h.srv.machineLoginOf(pAlice)
		mapped, _ := h.srv.mappedLoginFor(pAlice)
		tasks, _ := h.srv.Store.FleetTasksFor(pAlice, 10)
		_, me := cookieDo(t, h, http.MethodGet, "/v1/me", personCookie(pAlice, "alice-gh"), nil)
		var m Me
		_ = json.Unmarshal(me, &m)
		req, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
		_, cb := cookieDo(t, h, http.MethodPost, "/v1/fleet/cert", personCookie(pAlice, "alice-gh"), req)
		var cr CertResponse
		_ = json.Unmarshal(cb, &cr)
		var keyID string
		var principals []string
		if cr.Certificate != "" {
			c := parseCert(t, cr.Certificate)
			keyID, principals = c.KeyId, c.ValidPrincipals
		}
		out, _ := json.Marshal([]any{role, ml, mapped, h.srv.personName(pAlice), m.Person, m.Login, m.Role, m.Via,
			keyID, principals, cr.Name, len(tasks)})
		return string(out)
	}
	want := snap(h)

	// Put the table back the way a hub from before #3603 had it.
	db := st.DB()
	for _, q := range []string{
		`DELETE FROM hub_identities`,
		`ALTER TABLE hub_users RENAME TO hub_users_new`,
		`CREATE TABLE hub_users (github_id INTEGER PRIMARY KEY, login TEXT NOT NULL, role TEXT NOT NULL,
			machine_login TEXT NOT NULL DEFAULT '', added_by TEXT NOT NULL DEFAULT '', added_at TEXT NOT NULL, last_seen TEXT)`,
		`INSERT INTO hub_users SELECT github_id, login, role, machine_login, added_by, added_at, last_seen FROM hub_users_new`,
		`DROP TABLE hub_users_new`,
		`DELETE FROM hub_migrations WHERE id = 2`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	st.Close()
	st2, err := store.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st2.Close() })
	if ms, _ := st2.Migrations(); len(ms) < 2 || ms[1].ID != 2 || !strings.Contains(ms[1].Detail, `"hub_users.rekeyed":1`) {
		t.Fatalf("migration 2 did not re-key the old table: %+v", ms)
	}
	if got := snap(serve(st2)); got != want {
		t.Fatalf("a GitHub person's world moved:\n want %s\n got  %s", want, got)
	}
	if !strings.Contains(want, `"alice"`) || !strings.Contains(want, `"person:gh:1001"`) {
		t.Fatalf("the snapshot is empty: %s", want)
	}
}
