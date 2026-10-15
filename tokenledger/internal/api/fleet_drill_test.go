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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
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
// machines) with mac-e-mac-c on the node roster, and one drill person invited
// by the operator's token.
func drillHarness(t *testing.T) (*harness, DrillInviteResponse) {
	t.Helper()
	h, _ := certHarness(t)
	enrollAs(t, h, "mac-c", "mac-e-mac-c", "ivan")
	if err := h.srv.Store.NodeConnected("ep_mac-c", "mac-e-mac-c", "ivan", "test", 1, 1000, time.Now()); err != nil {
		t.Fatal(err)
	}
	code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "mac-e-mac-c.local"})
	if code != 200 {
		t.Fatalf("invite: %d %s", code, body)
	}
	var inv DrillInviteResponse
	json.Unmarshal(body, &inv)
	if inv.Kind != "drill" || inv.Host != "mac-e-mac-c" || !strings.HasPrefix(inv.Login, "drill") ||
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
	if code, _ := asPerson(t, h, http.MethodPost, DrillPath, pAlice, []byte(`{"host":"mac-e-mac-c"}`)); code != http.StatusForbidden {
		t.Fatalf("a colleague invited a drill person: %d, want 403", code)
	}
	if code, _ := drillReq(t, h, http.MethodPost, DrillPath, "", map[string]any{"host": "mac-e-mac-c"}); code != http.StatusUnauthorized && code != http.StatusForbidden {
		t.Fatalf("no credential: %d", code)
	}
	for _, bad := range []map[string]any{
		{"host": "nowhere"},
		{"host": "mac-e-mac-c", "ttl_seconds": 60},
		{"host": "mac-e-mac-c", "ttl_seconds": 3 * 86400},
		{"host": "mac-e-mac-c", "login": "ivan"},
		{"host": "mac-e-mac-c", "login": "drill-x"},
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
	pc, done := personForm(t, h, pAlice, h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}, "approve_code": {inv.ApproveCode}})
	if pc != 200 || !strings.Contains(done, "valid until") || !strings.Contains(done, inv.Login) {
		t.Fatalf("approve %d:\n%s", pc, done)
	}
	cr := pollCert(t, h, st)
	c := parseCert(t, cr.Certificate)
	if strings.Join(c.ValidPrincipals, ",") != inv.Login || c.KeyId != sshca.KeyIDPrefix+inv.PersonID {
		t.Fatalf("certificate principals %v key id %q — want the drill person's", c.ValidPrincipals, c.KeyId)
	}
	if devs, _ := h.srv.Store.Devices(inv.PersonID, 10); len(devs) != 1 {
		t.Fatalf("drill devices = %+v", devs)
	}
	if devs, _ := h.srv.Store.Devices(pAlice, 10); len(devs) != 0 {
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
	personForm(t, h, pAlice, h.http.URL, url.Values{"code": {ast.UserCode}, "action": {"approve"}})
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
	if devs, _ := h.srv.Store.Devices(pAlice, 10); len(devs) != 1 {
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

// A drill person leases like the newcomer it stands in for (claude-fleet#3155,
// reversing #2010's refusal on the person's call): the shared pool rides in its
// lease, another person's own account never does.
func TestDrillLeasesLikeANewcomer(t *testing.T) {
	h, tok, _ := newVaultHarness(t)
	exp := time.Now().Add(365 * 24 * time.Hour).UTC().Truncate(time.Second)
	if code, out := h.post(t, "/v1/fleet/credentials", FleetCredentialRequest{Action: "put", PrincipalID: store.PoolPrincipal,
		Provider: credvault.Claude, Account: "icloud", Secret: credvault.Secret{SetupToken: "sk-ant-oat01-POOL", ExpiresAt: &exp}}); code != http.StatusOK {
		t.Fatalf("put pool: %d %v", code, out)
	}
	putCred(t, h, credvault.Claude, "main", credvault.Secret{RefreshToken: "sk-ant-ort01-ALICE"})
	now := time.Now()
	if err := h.srv.Store.CreateDrill(store.DrillPerson{PrincipalID: "drill-x", Login: "drillx", Hostname: "mac-c",
		CodeHash: HashToken("fd_x"), CreatedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	dtok := enrollAs(t, h, "drillx-mac-c", "mac-c", "drillx")
	code, got, body := lease(t, h, dtok)
	if code != http.StatusOK {
		t.Fatalf("drill lease: %d %v, want 200 like a newcomer", code, body)
	}
	if got.PrincipalID != "drill-x" {
		t.Fatalf("leased as %q, want drill-x", got.PrincipalID)
	}
	accts := map[string]bool{}
	for _, c := range got.Credentials {
		accts[c.Account] = true
	}
	if !accts["icloud"] || accts["main"] {
		t.Fatalf("drill lease accounts = %v, want the pool's icloud and never alice's main", accts)
	}
	// Alice on the same machine still leases her own and the pool.
	if code, _, body := lease(t, h, tok); code != 200 {
		t.Fatalf("alice lease: %d %v", code, body)
	}
}

// The confirm page as the signed-in admin, with a drill code that is wrong:
// a refusal on the page, and the admin is NOT used instead.
func TestDrillWrongCodeOnPageDoesNotFallBackToAdmin(t *testing.T) {
	h, _ := drillHarness(t)
	st := startLogin(t, h, newUserKey(t), nil)
	pc, page := personForm(t, h, pAlice, h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}, "approve_code": {"fd_wrong"}})
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
	personForm(t, h, pAlice, h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	cr := pollCert(t, h, st)
	ask := func(host, login string, ttl int, signedHost string) (int, []byte) {
		ts := time.Now().Unix()
		return drillReq(t, h, http.MethodPost, DrillPath, "", drillInviteRequest{Host: host, Login: login, TTLSeconds: ttl,
			Cert: cr.Certificate, TS: ts, Sig: sshsig(t, signer, DrillSigNamespace, []byte(DrillInviteMessage(ts, signedHost, login, ttl, "")))})
	}
	if code, body := ask("mac-e-mac-c", "drillcert1", 600, "mac-e-mac-c"); code != http.StatusForbidden {
		t.Fatalf("a non-admin's certificate invited: %d %s", code, body)
	}
	// Alice becomes an admin: CCQUOTA_GITHUB_ADMINS names her, pinned to her ID.
	if _, err := h.srv.Store.PinLogin("alice-gh", 1001, time.Now()); err != nil {
		t.Fatal(err)
	}
	h.srv.GitHub.Admins = []string{"alice-gh"}
	if code, body := ask("mac-e-mac-c", "drillcert1", 600, "mac-e-mac-c"); code != 200 || !bytes.Contains(body, []byte(`"login":"drillcert1"`)) {
		t.Fatalf("the admin's certificate: %d %s", code, body)
	}
	if code, _ := ask("mac-e-mac-c", "drillcert2", 600, "elsewhere"); code != http.StatusUnauthorized {
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
	if visible("mac-e-mac-c", "alice") || visible("mac-e", "alice") {
		t.Fatal("the drill person sees Alice's sessions")
	}
	if h.srv.principalIsAdmin(inv.PersonID) {
		t.Fatal("a drill person counts as an admin")
	}
}

// drillOnFleet (claude-fleet#2549): leastBusyFleet (mac-c busy, mac-d quiet, m6
// 维护中, m7 no admin) with a certificate authority, and a drill person whose
// own computer is the quiet machine mac-d — its scan confirmed by its code.
func drillOnFleet(t *testing.T) (*harness, map[string]*fleetNode, DrillInviteResponse) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "none")
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	h.srv.SSHCA = sshca.New(signer)
	code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "mac-d"})
	if code != 200 {
		t.Fatalf("invite: %d %s", code, body)
	}
	var inv DrillInviteResponse
	json.Unmarshal(body, &inv)
	key, _ := drillKey(t)
	st := startLogin(t, h, key, nil)
	if code, body := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st.UserCode, ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("approve: %d %s", code, body)
	}
	return h, nodes, inv
}

// A drill person is a newcomer: its own computer is no machine to open a
// session on, so the scan itself opens its login on the least-busy OTHER
// machine (never its own — one row per person per machine), the doors say
// 「正在开」 instead of 「No fleet on any of your machines」, and once it is
// active the person reads as anyone with a login.
func TestDrillFirstSessionGetsAMachine(t *testing.T) {
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	if op.Op != control.AccountCreate || op.Login != inv.Login {
		t.Fatalf("op = %+v; want a create of %s on mac-c", op, inv.Login)
	}
	if got, ok := readMsg(nodes["mac-d"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the drill's own computer mac-d was sent %+v", got)
	}
	if st := h.srv.accountStateOf(inv.PersonID, time.Now()); st == nil || st.State != "opening" || st.Machine != "mac-c" {
		t.Fatalf("account = %+v; want opening on mac-c", st)
	}
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)
	loginReportsFleet(t, h, "mac-c", op.Login, machineA) // #2941: placeable once its fleet reports
	if st := h.srv.accountStateOf(inv.PersonID, time.Now()); st != nil {
		t.Fatalf("an active drill still gets account = %+v", st)
	}
	// Looking again opens nothing more.
	if got, ok := readMsg(nodes["mac-c"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("a second op: %+v", got)
	}
}

// The login opened for a drill is a real OS login: the drill does not go
// before it is removed — DELETE /v1/self answers 202 removing and sends the
// remove, and only once the machine says removed does the person go. The
// expiry sweep waits the same way.
func TestDrillGoesOnlyAfterItsLoginIsRemoved(t *testing.T) {
	old := drillCloseGiveUp
	drillCloseGiveUp = 48 * time.Hour // the sweep below runs a day ahead
	t.Cleanup(func() { drillCloseGiveUp = old })
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	// #2652: the create carries the login's own join code, so it can enroll
	// and bring its fleet up — the hub sees a login's fleet only through it.
	if !joinCodeRE.MatchString(op.JoinCode) {
		t.Fatalf("create op join_code = %q; want a fresh fj_ code", op.JoinCode)
	}
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)

	code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	if code != http.StatusAccepted || !strings.Contains(string(body), inv.Login+"@mac-c") {
		t.Fatalf("self-delete with a login open: %d %s; want 202 naming %s@mac-c", code, body, inv.Login)
	}
	m, op = expectAccountOp(t, nodes["mac-c"].tnode)
	if op.Op != control.AccountRemove || op.Login != inv.Login || !op.DropHome {
		t.Fatalf("op = %+v; want a remove of %s with drop_home (#2652: no archive of a throwaway login)", op, inv.Login)
	}
	h.srv.SweepDrills(time.Now().Add(DrillMaxTTL)) // expired meanwhile: still waits
	if _, err := h.srv.Store.Principal(inv.PersonID); err != nil {
		t.Fatal("the drill went before its login was removed")
	}
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountRemoved)
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("self-delete after the removal: %d %s", code, body)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("still there")
	}
}

// No other machine to open one on (a one-machine fleet, the drill's own
// login hosting its fleet): the doors answer as before — no account at all,
// never 「nobody gave you a machine」.
func TestDrillOnlyItsOwnMachineAnswersAsBefore(t *testing.T) {
	h, inv := drillHarness(t)
	if st := h.srv.accountStateOf(inv.PersonID, time.Now()); st != nil {
		t.Fatalf("account = %+v; want none at all", st)
	}
	if as, _ := h.srv.Store.FleetAccounts(inv.PersonID); len(as) != 1 {
		t.Fatalf("accounts = %+v; want only its own", as)
	}
}

// A create that failed may have left half an OS login (drill10091238 on the
// 2026-10-09 drill: the user made, the install not), so the drill does not go
// while it may still be there: DELETE /v1/self removes it first, and a machine
// with no such login answers the remove with exit 4 — removed, never failed
// (claude-fleet#2696). Before, the person went at once and the login stayed.
func TestDrillFailedCreateIsRemovedBeforeItGoes(t *testing.T) {
	old := drillRemoveRetry
	drillRemoveRetry = 0
	t.Cleanup(func() { drillRemoveRetry = old })
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, Exit: 1, Detail: "step 7: clone failed"})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountFailed)
	if st := h.srv.accountStateOf(inv.PersonID, time.Now()); st == nil || st.State != "failed" || !strings.Contains(st.Why, "clone failed") {
		t.Fatalf("account = %+v; want failed saying why", st)
	}

	code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	if code != http.StatusAccepted || !strings.Contains(string(body), inv.Login+"@mac-c") {
		t.Fatalf("self-delete after a failed create: %d %s; want 202 naming %s@mac-c", code, body, inv.Login)
	}
	m, op = expectAccountOp(t, nodes["mac-c"].tnode)
	if op.Op != control.AccountRemove || op.Login != inv.Login || !op.DropHome {
		t.Fatalf("op = %+v; want a remove of %s with drop_home", op, inv.Login)
	}
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: op.Login,
		Exit: control.RemoveExitNoLogin, Detail: "fleet-login-remove: no login " + op.Login + " on this machine: nothing to remove"})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountRemoved)
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("self-delete after the removal: %d %s", code, body)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("still there")
	}
}

// A failed remove is retried, never a reason to drop the person and leave
// the login; a create that met a login already there (someone else's) is
// never removed on the drill's behalf.
func TestDrillFailedRemoveIsRetriedExistingIsLeft(t *testing.T) {
	old := drillRemoveRetry
	drillRemoveRetry = 0
	t.Cleanup(func() { drillRemoveRetry = old })
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)
	drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	m, op = expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: op.Login, Exit: 6, Detail: "services not moved"})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountFailed)
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != http.StatusAccepted {
		t.Fatalf("self-delete after a failed remove: %d %s; want 202 (the login is still there)", code, body)
	}
	if _, op = expectAccountOp(t, nodes["mac-c"].tnode); op.Op != control.AccountRemove {
		t.Fatalf("op = %+v; want the remove again", op)
	}

	h2, nodes2, inv2 := drillOnFleet(t)
	m, op = expectAccountOp(t, nodes2["mac-c"].tnode)
	sendResult(t, nodes2["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, Exit: 3, Exists: true})
	waitState(t, h2, inv2.PersonID, "mac-c", store.AccountFailed)
	if code, body := drillReq(t, h2, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv2.ApproveCode}); code != 200 {
		t.Fatalf("self-delete after a create met an existing login: %d %s; want 200 (left for the operator)", code, body)
	}
	if got, ok := readMsg(nodes2["mac-c"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("someone else's login was sent %+v", got)
	}
}

// A create nobody answered (its link dropped mid-op: unknown) is waited out —
// the node re-sends its answer when it reconnects — and one still unanswered
// after drillCloseGiveUp is handed to the operator, never dropped in silence:
// the person goes, but its account row (and so its person row) stays for
// `fleet hub accounts`, and the 200 names it (claude-fleet#2728: before, the
// person went at once with every row, and drill10092046 stayed on mac-e
// with nobody to close it).
func TestDrillUnknownCreateIsWaitedThenHanded(t *testing.T) {
	h, nodes, inv := drillOnFleet(t)
	expectAccountOp(t, nodes["mac-c"].tnode)
	a := waitState(t, h, inv.PersonID, "mac-c", store.AccountCreating)
	if err := h.srv.Store.LoseAccountOps(a.EndpointID, time.Now()); err != nil {
		t.Fatal(err)
	}
	waitState(t, h, inv.PersonID, "mac-c", store.AccountUnknown)

	code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	if code != http.StatusAccepted || !strings.Contains(string(body), inv.Login+"@mac-c") {
		t.Fatalf("self-delete with a create unanswered: %d %s; want 202 naming %s@mac-c (wait for the node)", code, body, inv.Login)
	}
	// the hub may ask the node about the create again (claude-fleet#2918) —
	// never remove it on a guess
	for {
		got, ok := readMsg(nodes["mac-c"].tnode, 300*time.Millisecond)
		if !ok {
			break
		}
		var op control.AccountOp
		if got.Type == control.TypeAccountOp && (json.Unmarshal(got.Payload, &op) != nil || op.Op != control.AccountCreate) {
			t.Fatalf("an unanswered create was removed on a guess: %+v", got)
		}
	}

	old := drillCloseGiveUp
	drillCloseGiveUp = time.Millisecond
	t.Cleanup(func() { drillCloseGiveUp = old })
	time.Sleep(5 * time.Millisecond)
	code, body = drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	var out store.DrillDeleted
	if code != 200 || json.Unmarshal(body, &out) != nil || len(out.LeftForOperator) != 1 || out.LeftForOperator[0] != inv.Login+"@mac-c" {
		t.Fatalf("self-delete past the give-up: %d %s; want 200 with left_for_operator [%s@mac-c]", code, body, inv.Login)
	}
	accts, err := h.srv.Store.FleetAccounts(inv.PersonID)
	if err != nil || len(accts) != 1 || accts[0].Hostname != "mac-c" || !strings.Contains(accts[0].Detail, "left for the operator") {
		t.Fatalf("accounts after the person went = %+v, %v; want the mac-c row kept for the operator", accts, err)
	}
	if code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode}); code != http.StatusUnauthorized {
		t.Fatalf("the drill person can still delete itself: %d %s; want 401 (gone)", code, body)
	}
}

// A drill that names its machine (claude-fleet#3432, `fleet drill invite
// --home`): its scan opens the login THERE — mac-c, the busy one — never
// placement's pick (mac-d, the quiet one); its own computer (m7) is never a
// home, and a home off the roster is refused before anything is minted.
func TestDrillHomeOpensItsLoginThere(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	nodes := leastBusyFleet(t, h)
	setHubSetting(t, h.srv, AutoAssignKey, "least-busy")
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	h.srv.SSHCA = sshca.New(signer)
	for _, bad := range []struct{ host, home, want string }{
		{"m7", "m7", "own computer"},
		{"m7", "nowhere", "roster"},
	} {
		code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": bad.host, "home": bad.home})
		if code != http.StatusBadRequest || !strings.Contains(string(body), bad.want) {
			t.Fatalf("home %q on host %q: %d %s; want 400 naming %q", bad.home, bad.host, code, body, bad.want)
		}
	}
	code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "m7", "home": "mac-c.local"})
	if code != 200 {
		t.Fatalf("invite: %d %s", code, body)
	}
	var inv DrillInviteResponse
	json.Unmarshal(body, &inv)
	if inv.Home != "mac-c" {
		t.Fatalf("invite home = %q; want the roster's mac-c (%s)", inv.Home, body)
	}
	key, _ := drillKey(t)
	st := startLogin(t, h, key, nil)
	if code, body := drillReq(t, h, http.MethodPost, LoginApprovePath, "", approveRequest{Code: st.UserCode, ApproveCode: inv.ApproveCode}); code != 200 {
		t.Fatalf("approve: %d %s", code, body)
	}
	_, op := expectAccountOp(t, nodes["mac-c"].tnode)
	if op.Op != control.AccountCreate || op.Login != inv.Login {
		t.Fatalf("op = %+v; want a create of %s on its home mac-c", op, inv.Login)
	}
	for _, host := range []string{"mac-d", "m7"} {
		if got, ok := readMsg(nodes[host].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
			t.Fatalf("%s was sent %+v; the drill named mac-c", host, got)
		}
	}
	if st := h.srv.accountStateOf(inv.PersonID, time.Now()); st == nil || st.Machine != "mac-c" {
		t.Fatalf("account = %+v; want opening on mac-c", st)
	}
	// A real newcomer never has a home: placement as before.
	if got := h.srv.drillHome("gh:4004"); got != "" {
		t.Fatalf("a non-drill's home = %q", got)
	}
}

// The signed invite: with no home the message an older client signs, byte
// for byte; a home is signed after the rest.
func TestDrillInviteMessageHome(t *testing.T) {
	if got := DrillInviteMessage(7, "mac-c", "drillx", 600, ""); got != "fleet-drill 7 invite mac-c drillx 600" {
		t.Fatalf("no home: %q", got)
	}
	if got := DrillInviteMessage(7, "mac-c", "drillx", 600, "mac-d"); got != "fleet-drill 7 invite mac-c drillx 600 mac-d" {
		t.Fatalf("home: %q", got)
	}
}

// A person's pod keeps its one login until the pod itself goes: the node's
// rc 2 「pod keeps its one login」 is final, so it settles the login — the drill
// is not held for an hour re-sending the remove every minute, the person goes
// with every row, and the same login can be invited again at once
// (claude-fleet#4297, drillcn on u-drillcn4150). A login on a pod the hub did
// not make is settled before any remove is sent at all.
func TestDrillLoginOnUserPodIsSettledNotRetried(t *testing.T) {
	old := drillRemoveRetry
	drillRemoveRetry = 0
	t.Cleanup(func() { drillRemoveRetry = old })
	h, nodes, inv := drillOnFleet(t)
	m, op := expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountActive)
	drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	m, op = expectAccountOp(t, nodes["mac-c"].tnode)
	sendResult(t, nodes["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountRemove, Login: op.Login, Exit: 2,
		Detail: "fleet-node-linux: a person's pod keeps its one login until the pod itself is destroyed"})
	waitState(t, h, inv.PersonID, "mac-c", store.AccountFailed)
	code, body := drillReq(t, h, http.MethodDelete, DrillSelfPath, "", selfDeleteRequest{ApproveCode: inv.ApproveCode})
	var out store.DrillDeleted
	if code != 200 || json.Unmarshal(body, &out) != nil || len(out.LeftForOperator) != 0 {
		t.Fatalf("self-delete after the pod refused: %d %s; want 200, nothing left for the operator", code, body)
	}
	if got, ok := readMsg(nodes["mac-c"].tnode, 300*time.Millisecond); ok && got.Type == control.TypeAccountOp {
		t.Fatalf("the refused remove was sent again: %+v", got)
	}
	if _, err := h.srv.Store.Principal(inv.PersonID); err == nil {
		t.Fatal("the person is still there")
	}
	// the same login is invited again at once (the probe's next identity)
	if code, body := drillReq(t, h, http.MethodPost, DrillPath, "viewer-secret", map[string]any{"host": "mac-d", "login": inv.Login}); code != 200 {
		t.Fatalf("invite %s again: %d %s; want 200", inv.Login, code, body)
	}

	// An active login on a person's pod (u-<nonce>) the hub did not make: no
	// remove, settled at once.
	h2, nodes2, inv2 := drillOnFleet(t)
	m, op = expectAccountOp(t, nodes2["mac-c"].tnode)
	sendResult(t, nodes2["mac-c"].c, m.OpID, control.AccountResult{Op: control.AccountCreate, Login: op.Login, OK: true})
	waitState(t, h2, inv2.PersonID, "mac-c", store.AccountActive)
	if _, err := h2.srv.Store.DB().Exec(`UPDATE fleet_accounts SET hostname = 'u-drillpod42' WHERE principal_id = ? AND hostname = 'mac-c'`, inv2.PersonID); err != nil {
		t.Fatal(err)
	}
	d, err := h2.srv.Store.Drill(inv2.PersonID)
	if err != nil {
		t.Fatal(err)
	}
	if left, handed := h2.srv.closeDrillLogins(d, time.Now()); len(left) != 0 || len(handed) != 0 {
		t.Fatalf("close on a pod: left %v handed %+v; want it settled", left, handed)
	}
	as, _ := h2.srv.Store.FleetAccounts(inv2.PersonID)
	for _, a := range as {
		if a.Hostname == "u-drillpod42" && a.State != store.AccountActive {
			t.Fatalf("pod row = %+v; want no remove queued", a)
		}
	}

	// The pod's machine link runs as its one login — the drill's: deleting the
	// person keeps it enrolled (before, it was retired and the pod fell off the
	// hub, 「unrecognised enrollment token」); the login's endpoint on any other
	// machine goes as before.
	db := h2.srv.Store.DB()
	for _, ep := range [][2]string{{"ep_pod42", "u-drillpod42"}, {"ep_other42", "mac-c"}} {
		if _, err := db.Exec(`INSERT INTO endpoints (endpoint_id, token_hash, label, enrolled_at, hostname, os_user)
			VALUES (?, ?, ?, ?, ?, ?)`, ep[0], "h-"+ep[0], ep[0], time.Now().UTC().Format(time.RFC3339), ep[1], inv2.Login); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(`INSERT INTO nodes (endpoint_id, hostname, os_user) VALUES (?, ?, ?)`, ep[0], ep[1], inv2.Login); err != nil {
			t.Fatal(err)
		}
	}
	h2.srv.SweepDrills(d.ExpiresAt.Add(time.Minute))
	if _, err := h2.srv.Store.Principal(inv2.PersonID); err == nil {
		t.Fatal("the expired drill person on a pod is still there")
	}
	var live int
	db.QueryRow(`SELECT COUNT(*) FROM endpoints WHERE endpoint_id = 'ep_pod42' AND retired_at IS NULL`).Scan(&live)
	var roster int
	db.QueryRow(`SELECT COUNT(*) FROM nodes WHERE endpoint_id = 'ep_pod42'`).Scan(&roster)
	if live != 1 || roster != 1 {
		t.Fatalf("pod endpoint live=%d roster=%d; want the pod still enrolled and on the roster", live, roster)
	}
	db.QueryRow(`SELECT COUNT(*) FROM nodes WHERE endpoint_id = 'ep_other42'`).Scan(&roster)
	if roster != 0 {
		t.Fatal("the drill login's endpoint on another machine was kept")
	}
}
