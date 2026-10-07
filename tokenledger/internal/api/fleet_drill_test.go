package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"html"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// drillReq sends method path with a JSON body; bearer "" = no token.
func drillReq(t *testing.T, h *harness, method, path, bearer string, body any) (int, []byte) {
	t.Helper()
	b, _ := json.Marshal(body)
	r, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

// drillKey is a device key whose private half the test holds — the drill's
// computer, so it can sign as the certificate the scan hands it.
func drillKey(t *testing.T) (string, ssh.Signer) {
	t.Helper()
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	pk, _ := ssh.NewPublicKey(pub)
	signer, _ := ssh.NewSignerFromKey(priv)
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pk))) + " drill@box", signer
}

// drillHarness: certHarness (Alice signed in, an active login on two
// machines) with macmini-m4 on the node roster, and one drill person invited
// by the operator's token.
func drillHarness(t *testing.T) (*harness, DrillInviteResponse) {
	t.Helper()
	h, _ := certHarness(t)
	enrollAs(t, h, "m4", "macmini-m4", "verkyyi")
	if err := h.srv.Store.NodeConnected("ep_m4", "macmini-m4", "verkyyi", "test", 1, 1000, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "macmini-m4.local"})
	if code != 200 {
		t.Fatalf("invite: %d %s", code, body)
	}
	var inv DrillInviteResponse
	json.Unmarshal(body, &inv)
	if inv.Kind != "drill" || inv.Host != "macmini-m4" || !strings.HasPrefix(inv.Login, "drill") ||
		!strings.HasPrefix(inv.ApproveCode, "fd_") || !strings.HasPrefix(inv.PersonID, "drill-") {
		t.Fatalf("invite = %s", body)
	}
	if d := time.Until(inv.ExpiresAt); d < DrillDefaultTTL-time.Minute || d > DrillDefaultTTL {
		t.Fatalf("default life %v, want 2h", d)
	}
	return h, inv
}

func startLogin(t *testing.T, h *harness, key string, extra map[string]string) DeviceStart {
	t.Helper()
	req := map[string]string{"public_key": key}
	for k, v := range extra {
		req[k] = v
	}
	code, body := postJSON(t, h, "/v1/fleet/login/start", req)
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	return st
}

func pollCert(t *testing.T, h *harness, st DeviceStart) CertResponse {
	t.Helper()
	code, body := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	if code != 200 {
		t.Fatalf("poll: %d %s", code, body)
	}
	var cr CertResponse
	json.Unmarshal(body, &cr)
	return cr
}

// Only an admin invites: a signed-in colleague is refused, the operator's
// token is not. The life is bounded and the host must be on the roster.
func TestDrillInviteIsAdminOnly(t *testing.T) {
	h, _ := drillHarness(t)
	if code, _ := asPerson(t, h, http.MethodPost, DrillPath, "Alice", []byte(`{"host":"macmini-m4"}`)); code != http.StatusForbidden {
		t.Fatalf("a colleague invited a drill person: %d, want 403", code)
	}
	if code, _ := drillReq(t, h, http.MethodPost, DrillPath, "", map[string]any{"host": "macmini-m4"}); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("no credential: %d", code)
	}
	for _, bad := range []map[string]any{
		{"host": "nowhere"},
		{"host": "macmini-m4", "ttl_seconds": 60},
		{"host": "macmini-m4", "ttl_seconds": 3 * 86400},
		{"host": "macmini-m4", "login": "verkyyi"},
		{"host": "macmini-m4", "login": "drill-x"},
	} {
		if code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", bad); code != http.StatusBadRequest {
			t.Fatalf("invite %v: %d %s, want 400", bad, code, body)
		}
	}
}

// The heart of #2010: an admin signed in on the browser confirms the drill's
// scan WITH the approve code — the certificate, the device and the login are
// the drill person's, never the admin's. The code works once.
func TestDrillApproveIsTheDrillPerson(t *testing.T) {
	h, inv := drillHarness(t)
	key, _ := drillKey(t)
	st := startLogin(t, h, key, nil)

	// The QR page, Alice signed in, approve_code in the form.
	pc, done := personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}, "approve_code": {inv.ApproveCode}})
	if pc != 200 || !strings.Contains(done, "valid until") || !strings.Contains(done, inv.Login) {
		t.Fatalf("approve %d:\n%s", pc, done)
	}
	cr := pollCert(t, h, st)
	c := parseCert(t, cr.Certificate)
	if strings.Join(c.ValidPrincipals, ",") != inv.Login || c.KeyId != "wecom:"+inv.PersonID {
		t.Fatalf("certificate principals %v key id %q — want the drill person's", c.ValidPrincipals, c.KeyId)
	}
	if devs, _ := h.srv.Store.Devices(inv.PersonID, 10); len(devs) != 1 {
		t.Fatalf("drill devices = %+v", devs)
	}
	if devs, _ := h.srv.Store.Devices("Alice", 10); len(devs) != 0 {
		t.Fatalf("the signed-in admin got the device: %+v", devs)
	}

	// Once: the same code on a second scan is refused, and that login stays pending.
	st2 := startLogin(t, h, newUserKey(t), nil)
	if code, body := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st2.UserCode, ApproveCode: inv.ApproveCode}); code != http.StatusForbidden {
		t.Fatalf("second use: %d %s, want 403", code, body)
	}
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st2.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("refused code touched the login: poll %d, want 202", code)
	}
	// A made-up code is refused too.
	if code, _ := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st2.UserCode, ApproveCode: "fd_nope"}); code != http.StatusForbidden {
		t.Fatalf("unknown code: %d, want 403", code)
	}
}

// The script's way: POST /fleet/login/approve, no browser, no session — then
// the drill deletes itself with its own certificate and nothing is left: no
// person, no device, no node. A real person cannot delete themselves.
func TestDrillApproveByScriptThenSelfDelete(t *testing.T) {
	h, inv := drillHarness(t)
	key, signer := drillKey(t)
	st := startLogin(t, h, key, map[string]string{"device_name": "drillbox", "purpose": "node", "os_user": inv.Login})
	code, body := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st.UserCode, ApproveCode: inv.ApproveCode})
	if code != 200 || !bytes.Contains(body, []byte(`"person_id":"`+inv.PersonID+`"`)) {
		t.Fatalf("approve: %d %s", code, body)
	}
	cr := pollCert(t, h, st)
	if cr.Node == nil || cr.Node.EndpointID == "" {
		t.Fatalf("node scan gave no node: %+v", cr)
	}
	if n, _ := h.srv.Store.Devices(inv.PersonID, 10); len(n) != 1 {
		t.Fatalf("devices before delete = %d", len(n))
	}

	// Alice (not a drill) signing the delete is refused.
	ak, asigner := drillKey(t)
	ast := startLogin(t, h, ak, nil)
	personForm(t, h, "Alice", h.http.URL, url.Values{"code": {ast.UserCode}, "action": {"approve"}})
	acr := pollCert(t, h, ast)
	ts := time.Now().Unix()
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{
		Cert: acr.Certificate, TS: ts, Sig: sshsig(t, asigner, DrillSigNamespace, []byte(DrillSelfDeleteMessage(ts)))}); code != http.StatusForbidden {
		t.Fatalf("a real person deleted themselves: %d %s", code, body)
	}
	// A signature for another message is refused.
	if code, _ := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{
		Cert: cr.Certificate, TS: ts, Sig: sshsig(t, signer, DrillSigNamespace, []byte("fleet-drill 1 delete-self"))}); code != http.StatusUnauthorized {
		t.Fatalf("a wrong signature: %d, want 401", code)
	}

	code, body = drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{
		Cert: cr.Certificate, TS: ts, Sig: sshsig(t, signer, DrillSigNamespace, []byte(DrillSelfDeleteMessage(ts)))})
	if code != 200 {
		t.Fatalf("self delete: %d %s", code, body)
	}
	var out store.DrillDeleted
	json.Unmarshal(body, &out)
	if out.Devices != 1 || len(out.Nodes) != 1 || out.Nodes[0] != cr.Node.EndpointID {
		t.Fatalf("deleted = %s", body)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("the drill person is still there")
	}
	if devs, _ := h.srv.Store.Devices(inv.PersonID, 10); len(devs) != 0 {
		t.Fatalf("devices left: %+v", devs)
	}
	if ep, err := h.srv.Store.EndpointByID(cr.Node.EndpointID); err == nil && ep.RetiredAt == nil {
		t.Fatalf("node %s is still live", cr.Node.EndpointID)
	}
	if accts, _ := h.srv.Store.FleetAccounts(inv.PersonID); len(accts) != 0 {
		t.Fatalf("accounts left: %+v", accts)
	}
	// Alice is untouched.
	if devs, _ := h.srv.Store.Devices("Alice", 10); len(devs) != 1 {
		t.Fatalf("Alice's devices = %+v", devs)
	}
}

// A drill whose scan never finished has no certificate: its approve code
// deletes it. The code is the drill's, so it deletes no one else.
func TestDrillSelfDeleteByCode(t *testing.T) {
	h, inv := drillHarness(t)
	if code, _ := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: "fd_other"}); code != http.StatusUnauthorized {
		t.Fatalf("unknown code: %d, want 401", code)
	}
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("delete by code: %d %s", code, body)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("still there")
	}
}

// Expiry: a used-up life refuses the code, and the sweep deletes the person.
func TestDrillExpires(t *testing.T) {
	h, inv := drillHarness(t)
	later := time.Now().Add(DrillDefaultTTL + time.Minute)
	if _, err := h.srv.Store.UseDrillCode(HashToken(inv.ApproveCode), later); err != store.ErrDrillCode {
		t.Fatalf("an expired code was spent: %v", err)
	}
	h.srv.SweepDrills(time.Now())
	if _, err := h.srv.Store.Principal(inv.PersonID); err != nil {
		t.Fatal("swept before its time")
	}
	h.srv.SweepDrills(later)
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("an expired drill person is still there")
	}
}

// A drill person borrows nothing: the node running as its login gets no
// credential — not even the shared pool — and no session pass.
func TestDrillGetsNoCredentials(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	now := time.Now()
	if err := h.srv.Store.CreateDrill(store.DrillPerson{PrincipalID: "drill-x", Login: "drillx", Hostname: "m4",
		CodeHash: HashToken("fd_x"), CreatedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	dtok := enrollAs(t, h, "drillx-m4", "m4", "drillx")
	code, _, body := lease(t, h, dtok)
	if code != http.StatusForbidden || body["error"] != LeaseDrill {
		t.Fatalf("drill lease: %d %v, want 403 drill", code, body)
	}
	// Alice on the same machine still leases.
	if code, _, body := lease(t, h, tok); code != 200 {
		t.Fatalf("alice lease: %d %v", code, body)
	}
}

// The confirm page as the signed-in admin, with a drill code that is wrong:
// a refusal on the page, and the admin is NOT used instead.
func TestDrillWrongCodeOnPageDoesNotFallBackToAdmin(t *testing.T) {
	h, _ := drillHarness(t)
	st := startLogin(t, h, newUserKey(t), nil)
	pc, page := personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}, "approve_code": {"fd_wrong"}})
	if pc != 200 || !strings.Contains(html.UnescapeString(page), "drill approval code is invalid") {
		t.Fatalf("page %d:\n%s", pc, page)
	}
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("the login was confirmed anyway: poll %d", code)
	}
}

// `fleet drill invite`'s door: the operator's own connection certificate
// signing the request. A fleet admin login is let in; the same signature from
// someone who is not an admin is refused; a signature over other fields is too.
func TestDrillInviteByCertificate(t *testing.T) {
	h, _ := drillHarness(t)
	key, signer := drillKey(t)
	st := startLogin(t, h, key, nil)
	personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	cr := pollCert(t, h, st)
	ask := func(host, login string, ttl int, signedHost string) (int, []byte) {
		ts := time.Now().Unix()
		return drillReq(t, h, http.MethodPost, DrillPath, "", drillInviteRequest{Host: host, Login: login, TTLSeconds: ttl,
			Cert: cr.Certificate, TS: ts, Sig: sshsig(t, signer, DrillSigNamespace, []byte(DrillInviteMessage(ts, signedHost, login, ttl)))})
	}
	if code, body := ask("macmini-m4", "drillcert1", 600, "macmini-m4"); code != http.StatusForbidden {
		t.Fatalf("a non-admin's certificate invited: %d %s", code, body)
	}
	h.srv.FleetAdmins = []string{"alice"}
	if code, body := ask("macmini-m4", "drillcert1", 600, "macmini-m4"); code != 200 || !bytes.Contains(body, []byte(`"login":"drillcert1"`)) {
		t.Fatalf("the admin's certificate: %d %s", code, body)
	}
	if code, _ := ask("macmini-m4", "drillcert2", 600, "elsewhere"); code != http.StatusUnauthorized {
		t.Fatalf("a signature over another host: %d, want 401", code)
	}
}

// A drill person sees only its own sessions: the fleet views' scope (the cert
// doors set the principal with no role) holds its one login, not Alice's.
func TestDrillSeesOnlyItsOwn(t *testing.T) {
	h, inv := drillHarness(t)
	r := httptest.NewRequest(http.MethodGet, "/v1/fleet/sessions", nil)
	r = r.WithContext(context.WithValue(r.Context(), principalKey{}, inv.PersonID))
	visible, err := h.srv.FleetScope(r)
	if err != nil || visible == nil {
		t.Fatalf("a drill person sees everything (scope %v, %v)", visible != nil, err)
	}
	if !visible(inv.Host, inv.Login) {
		t.Fatal("the drill person cannot see its own login")
	}
	if visible("macmini-m4", "alice") || visible("macmini", "alice") {
		t.Fatal("the drill person sees Alice's sessions")
	}
	if h.srv.principalIsAdmin(inv.PersonID) {
		t.Fatal("a drill person counts as an admin")
	}
}
