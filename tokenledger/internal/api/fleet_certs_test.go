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
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/authz"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// certHarness: fleet on, WeCom SSO on, a CA, two machines with routes, and
// Alice holding an active login "alice" on both.
func certHarness(t *testing.T) (*harness, *sshca.CA) {
	t.Helper()
	h := newFleetHarness(t)
	enableSSO(h)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	ca := sshca.New(signer)
	h.srv.SSHCA = ca
	routes, err := ParseFleetRoutes(`[
	  {"hostname":"macmini-m4","alias":"m4","routes":[{"name":"public","host":"203.0.113.4","port":22023},{"name":"tailnet","host":"m4.tail.ts.net"}]},
	  {"hostname":"macmini","alias":"m5","routes":[{"name":"public","host":"203.0.113.5","port":22022}]},
	  {"hostname":"spare","routes":[{"name":"lan","host":"10.0.0.9"}]}]`)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.FleetRoutes = routes
	for _, host := range []string{"macmini-m4", "macmini"} {
		if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "Alice", Hostname: host, Login: "alice"}); code != 200 {
			t.Fatalf("adopt on %s: HTTP %d", host, code)
		}
	}
	return h, ca
}

func newUserKey(t *testing.T) string {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	pk, _ := ssh.NewPublicKey(pub)
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pk))) + " alice@laptop"
}

func postJSON(t *testing.T, h *harness, path string, body any) (int, []byte) {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(h.http.URL+path, "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

// personForm posts the confirmation form as sub, from this origin.
func personForm(t *testing.T, h *harness, sub, origin string, form url.Values) (int, string) {
	t.Helper()
	return cookieForm(t, h, &http.Cookie{Name: authz.CookieName, Value: authz.SignSession(sub, ssoSessionKey, time.Now(), time.Hour)}, origin, form)
}

// cookieForm posts the confirmation form on the given session cookie.
func cookieForm(t *testing.T, h *harness, c *http.Cookie, origin string, form url.Values) (int, string) {
	t.Helper()
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/fleet/login", strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.Header.Set("Origin", origin)
	r.AddCookie(c)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func parseCert(t *testing.T, line string) *ssh.Certificate {
	t.Helper()
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		t.Fatalf("certificate does not parse: %v (%q)", err, line)
	}
	c, ok := pk.(*ssh.Certificate)
	if !ok {
		t.Fatalf("not a certificate: %q", line)
	}
	return c
}

// The whole `fleet login`: start with a public key, the QR's page confirms
// it as the signed-in person, the next poll carries a 12-hour certificate for
// exactly their login — once — plus the ssh config for their machines.
func TestFleetLoginDeviceFlow(t *testing.T) {
	h, ca := certHarness(t)
	key := newUserKey(t)

	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": key})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	if !validUserCode(st.UserCode) || len(st.DeviceCode) != 64 || len(st.QR) < 21 {
		t.Fatalf("start = %+v", st)
	}
	if !strings.HasSuffix(st.VerificationURI, "/fleet/login?code="+st.UserCode) {
		t.Fatalf("verification uri %q", st.VerificationURI)
	}
	if !strings.HasPrefix(st.KeyFingerprint, "SHA256:") {
		t.Fatalf("fingerprint %q", st.KeyFingerprint)
	}

	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("poll before approval: %d, want 202", code)
	}

	// The page the QR opens shows the code, the login and the key.
	pc, raw := asPerson(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, "Alice", nil)
	page := html.UnescapeString(string(raw))
	if pc != 200 || !strings.Contains(page, st.UserCode) || !strings.Contains(page, "alice") ||
		!strings.Contains(page, st.KeyFingerprint) || !strings.Contains(page, "确认签发") {
		t.Fatalf("confirm page %d:\n%s", pc, page)
	}

	pc, done := personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	if pc != 200 || !strings.Contains(done, "已签发") {
		t.Fatalf("approve %d:\n%s", pc, done)
	}

	code, body = postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	if code != 200 {
		t.Fatalf("poll after approval: %d %s", code, body)
	}
	var cr CertResponse
	json.Unmarshal(body, &cr)
	if cr.Node != nil || bytes.Contains(body, []byte(`"node"`)) {
		t.Fatalf("a plain login carried a node pass: %s", body) // #1627
	}
	c := parseCert(t, cr.Certificate)
	if strings.Join(c.ValidPrincipals, ",") != "alice" || cr.Principals[0] != "alice" {
		t.Fatalf("principals %v", c.ValidPrincipals)
	}
	if d := time.Duration(c.ValidBefore-c.ValidAfter) * time.Second; d < 12*time.Hour || d > 12*time.Hour+2*time.Minute {
		t.Fatalf("validity %v", d)
	}
	if c.KeyId != "wecom:Alice" {
		t.Fatalf("key id %q", c.KeyId)
	}
	if string(c.SignatureKey.Marshal()) != string(mustParseKey(t, ca.PublicKey()).Marshal()) {
		t.Fatal("not signed by the hub's CA")
	}
	if want, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(key)); string(c.Key.Marshal()) != string(want.Marshal()) {
		t.Fatal("certificate is for a different key than the one the client sent")
	}
	for _, want := range []string{"# " + FleetSSHConfigVersion, "Host m4 fleet-m4 fleet-m4-public\n  HostName 203.0.113.4\n  Port 22023\n  User alice",
		"Host fleet-m4-tailnet\n  HostName m4.tail.ts.net\n  User alice", "Host m5 fleet-m5 fleet-m5-public",
		"IdentityFile ~/.ssh/fleet-cert\n  CertificateFile ~/.ssh/fleet-cert-cert.pub"} {
		if !strings.Contains(cr.SSHConfig, want) {
			t.Fatalf("ssh config lacks %q:\n%s", want, cr.SSHConfig)
		}
	}
	if strings.Contains(cr.SSHConfig, "spare") {
		t.Fatalf("ssh config lists a machine Alice has no login on:\n%s", cr.SSHConfig)
	}

	// Handed out once.
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusGone {
		t.Fatalf("second poll: %d, want 410", code)
	}
	// And recorded.
	certs, err := h.srv.Store.FleetCerts("Alice", 10)
	if err != nil || len(certs) != 1 || certs[0].Via != "device" || certs[0].KeyID != c.KeyId {
		t.Fatalf("audit = %+v, %v", certs, err)
	}
}

func mustParseKey(t *testing.T, line string) ssh.PublicKey {
	t.Helper()
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

// "不是我" ends the login: the client's poll is refused and nothing is signed.
func TestFleetLoginDeny(t *testing.T) {
	h, _ := certHarness(t)
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	json.Unmarshal(body, &st)
	personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"deny"}})
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusForbidden {
		t.Fatalf("poll after deny: %d, want 403", code)
	}
	if certs, _ := h.srv.Store.FleetCerts("", 10); len(certs) != 0 {
		t.Fatalf("signed after a deny: %+v", certs)
	}
}

// A form posted from another origin is refused — a page elsewhere cannot
// make a signed-in person approve a stranger's key.
func TestFleetLoginRefusesCrossOrigin(t *testing.T) {
	h, _ := certHarness(t)
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	json.Unmarshal(body, &st)
	if code, _ := personForm(t, h, "Alice", "https://evil.example", url.Values{"code": {st.UserCode}, "action": {"approve"}}); code != http.StatusForbidden {
		t.Fatalf("cross-origin approve: %d, want 403", code)
	}
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusAccepted {
		t.Fatalf("login no longer pending after a refused cross-origin post: %d", code)
	}
}

// Someone signed in with no active login anywhere gets no certificate, from
// either door; the operator's token is not a person and gets none either.
func TestFleetCertNeedsAnActiveLogin(t *testing.T) {
	h, _ := certHarness(t)
	_, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)})
	var st DeviceStart
	json.Unmarshal(body, &st)
	_, page := asPerson(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, "Carol", nil)
	if !strings.Contains(string(page), "还不能签发") || strings.Contains(string(page), "确认签发") {
		t.Fatalf("Carol's confirm page:\n%s", page)
	}
	req, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
	if code, b := asPerson(t, h, http.MethodPost, "/v1/fleet/cert", "Carol", req); code != http.StatusConflict {
		t.Fatalf("Carol /v1/fleet/cert: %d %s, want 409", code, b)
	}
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/cert", bytes.NewReader(req))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("operator token /v1/fleet/cert: %d, want 403", resp.StatusCode)
	}
	// A pending (not yet active) account does not count.
	operatorPost(t, h, FleetAccountRequest{Action: "assign", PrincipalID: "Dave", Hostname: "macmini-m4"})
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/cert", "Dave", req); code != http.StatusConflict {
		t.Fatalf("Dave (pending only): %d, want 409", code)
	}
}

// The 连接 page's paste-a-key door signs for the signed-in person, and its
// connect info is narrowed to their machines.
func TestFleetCertWebAndConnectInfo(t *testing.T) {
	h, ca := certHarness(t)
	req, _ := json.Marshal(map[string]string{"public_key": newUserKey(t)})
	code, body := asPerson(t, h, http.MethodPost, "/v1/fleet/cert", "Alice", req)
	if code != 200 {
		t.Fatalf("web cert: %d %s", code, body)
	}
	var cr CertResponse
	json.Unmarshal(body, &cr)
	parseCert(t, cr.Certificate)

	bad, _ := json.Marshal(map[string]string{"public_key": `command="sh" ` + newUserKey(t)})
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/cert", "Alice", bad); code != http.StatusBadRequest {
		t.Fatalf("key with options: %d, want 400", code)
	}

	code, body = asPerson(t, h, http.MethodGet, "/v1/fleet/connect", "Alice", nil)
	var ci ConnectInfo
	json.Unmarshal(body, &ci)
	if code != 200 || ci.Login != "alice" || !ci.CAEnabled || ci.CAFingerprint != ca.Fingerprint() ||
		len(ci.Machines) != 2 || len(ci.Recent) != 1 || ci.Recent[0].Via != "web" || ci.CertTTLSec != 43200 {
		t.Fatalf("connect info %d %+v", code, ci)
	}
	if ci.KeyPath != "~/.ssh/fleet-cert" || ci.CertPath != "~/.ssh/fleet-cert-cert.pub" || ci.ConfigPath != "~/.ssh/fleet-ssh-config" {
		t.Fatalf("fixed paths changed: %+v", ci)
	}

	// Public CA key, no credential.
	resp, err := http.Get(h.http.URL + "/v1/fleet/ssh-ca.pub")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if strings.TrimSpace(string(b)) != ca.PublicKey() {
		t.Fatalf("ssh-ca.pub = %q", b)
	}
}

// A QR scanned while signed out survives the trip through WeCom: the code
// waits in a cookie and /enter lands back on the confirmation page.
func TestFleetLoginSurvivesSignIn(t *testing.T) {
	h, _ := certHarness(t)
	resp := h.raw(t, "/fleet/login?code=BCDF-GHJK", map[string]string{"Accept": "text/html"})
	if resp.StatusCode != http.StatusFound || !strings.HasPrefix(resp.Header.Get("Location"), ssoGate) {
		t.Fatalf("signed-out QR: %d → %q, want the WeCom gate", resp.StatusCode, resp.Header.Get("Location"))
	}
	var remembered *http.Cookie
	for _, c := range resp.Cookies() {
		if c.Name == loginCookie {
			remembered = c
		}
	}
	if remembered == nil || remembered.Value != "BCDF-GHJK" {
		t.Fatalf("code not remembered: %+v", resp.Cookies())
	}
	resp = h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", "Alice", time.Now().Add(time.Minute).Unix()),
		map[string]string{"Cookie": remembered.Name + "=" + remembered.Value})
	if loc := resp.Header.Get("Location"); loc != "/fleet/login?code=BCDF-GHJK" {
		t.Fatalf("after sign-in → %q", loc)
	}
	// A tampered cookie lands on "/", never on a path it names.
	resp = h.raw(t, "/enter?ticket="+mintTicket(t, "ccquota", "Alice", time.Now().Add(time.Minute).Unix()),
		map[string]string{"Cookie": loginCookie + "=//evil.example"})
	if loc := resp.Header.Get("Location"); loc != "/" {
		t.Fatalf("tampered cookie → %q, want /", loc)
	}
}

// An admin node is told to trust the CA on connect, and its answer shows on
// the roster; a non-admin login is never sent it.
func TestFleetAdminNodeGetsTheCA(t *testing.T) {
	h, ca := certHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "macmini-m4", "verkyyi", true)
	other := connectNode(t, h, "m4-alice", "macmini-m4", "alice", false)

	m, ok := readMsg(admin.tnode, 5*time.Second)
	if !ok || m.Type != control.TypeSSHCA {
		t.Fatalf("admin got %+v, want ssh_ca", m)
	}
	var req control.SSHCA
	json.Unmarshal(m.Payload, &req)
	if req.PublicKey != ca.PublicKey() {
		t.Fatalf("sent %q", req.PublicKey)
	}
	if m, ok := readMsg(other.tnode, 300*time.Millisecond); ok {
		t.Fatalf("non-admin node was sent %+v", m)
	}

	res, _ := control.New(control.TypeSSHCAResult, control.SSHCAResult{OK: true, Changed: true, Detail: "trusted for new connections"})
	res.OpID = m.OpID
	writeMsg(t, admin.tnode, res)
	waitFor(t, 3*time.Second, "ssh_ca status on the roster", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.OSUser == "verkyyi" && strings.HasPrefix(n.SSHCA, "trusted") {
				return true
			}
		}
		return false
	})
}

// No CA configured: the certificate routes do not exist and admin nodes are
// sent nothing new.
func TestFleetCertsOffWithoutCA(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	if code, _ := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": newUserKey(t)}); code != http.StatusNotFound {
		t.Fatalf("start without a CA: %d, want 404", code)
	}
	h.srv.FleetAdmins = []string{"verkyyi"}
	admin := connectNode(t, h, "m4-op", "m4", "verkyyi", true)
	if m, ok := readMsg(admin.tnode, 300*time.Millisecond); ok {
		t.Fatalf("admin node was sent %+v with no CA configured", m)
	}
}

func TestParseFleetRoutesRefusesConfigInjection(t *testing.T) {
	for _, bad := range []string{
		`[{"hostname":"m4\nProxyCommand sh","routes":[]}]`,
		`[{"hostname":"m4","routes":[{"name":"x","host":"a b"}]}]`,
		`[{"hostname":"m4","routes":[{"name":"x","host":"-oProxyCommand=sh"}]}]`,
		`[{"hostname":"m4","routes":[{"name":"x","host":"h","port":70000}]}]`,
		`not json`,
	} {
		if _, err := ParseFleetRoutes(bad); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
	if ms, err := ParseFleetRoutes(""); err != nil || ms != nil {
		t.Fatalf("empty: %v %v", ms, err)
	}
}

func TestUserCodeShape(t *testing.T) {
	for i := 0; i < 50; i++ {
		c, err := randomUserCode()
		if err != nil || !validUserCode(c) {
			t.Fatalf("%q %v", c, err)
		}
	}
	for _, bad := range []string{"", "ABCD-EFGH", "bcdf-ghjk", "BCDFGHJK", "BCDF-GHJ", "/fleet/x"} {
		if validUserCode(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func writeMsg(t *testing.T, n *tnode, m control.Message) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, n.c, m); err != nil {
		t.Fatal(err)
	}
}

// `fleet node join` (claude-fleet#1627): the same start / page / poll as
// `fleet login`, with purpose=node. The page is titled for the machine, and
// the confirmation returns the certificate AND a node pass the hub accepts —
// one endpoint, enrolled under the reported host and login.
func TestFleetNodeJoinByScan(t *testing.T) {
	h, _ := certHarness(t)
	key := newUserKey(t)

	if code, _ := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": key, "purpose": "admin"}); code != http.StatusBadRequest {
		t.Fatalf("unknown purpose: %d, want 400", code)
	}
	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{
		"public_key": key, "device_name": "newbox", "purpose": "node", "os_user": "alice"})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	if !strings.HasSuffix(st.VerificationURI, "/fleet/login?code="+st.UserCode) {
		t.Fatalf("verification uri %q — the node scan opens the SAME page", st.VerificationURI)
	}

	pc, raw := asPerson(t, h, http.MethodGet, "/fleet/login?code="+st.UserCode, "Alice", nil)
	page := html.UnescapeString(string(raw))
	if pc != 200 || !strings.Contains(page, "<title>把 newbox 加为节点</title>") || !strings.Contains(page, "<h1>把 newbox 加为节点</h1>") ||
		!strings.Contains(page, st.UserCode) || !strings.Contains(page, "确认签发") {
		t.Fatalf("node confirm page %d:\n%s", pc, page)
	}
	pc, done := personForm(t, h, "Alice", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	if pc != 200 || !strings.Contains(html.UnescapeString(done), "已把 <b>newbox</b> 加为节点") {
		t.Fatalf("approve %d:\n%s", pc, done)
	}

	code, body = postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	if code != 200 {
		t.Fatalf("poll: %d %s", code, body)
	}
	var cr CertResponse
	json.Unmarshal(body, &cr)
	if cr.Certificate == "" || cr.Node == nil || cr.Node.Token == "" || cr.Node.EndpointID == "" {
		t.Fatalf("node scan answer = %s", body)
	}
	if cr.Node.Label != "newbox-alice" || cr.Node.Kind != "fixed" || cr.Node.SSHCA == "" {
		t.Fatalf("node pass = %+v", cr.Node)
	}
	if resp, sb := getWithToken(t, h, "/v1/node/self", cr.Node.Token); resp.StatusCode != 200 || !strings.Contains(string(sb), cr.Node.EndpointID) {
		t.Fatalf("the hub does not accept the node pass: %d %s", resp.StatusCode, sb)
	}
	if code, _ := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code != http.StatusGone {
		t.Fatalf("second poll: %d, want 410 — the pass is handed out once", code)
	}
}

// A person with no active login cannot add a node by scan: the same gate as
// the certificate, so no pass is minted.
func TestFleetNodeJoinNeedsAnActiveLogin(t *testing.T) {
	h, _ := certHarness(t)
	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{
		"public_key": newUserKey(t), "device_name": "newbox", "purpose": "node", "os_user": "carol"})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	personForm(t, h, "Carol", h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}})
	if code, body := postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode}); code == 200 {
		t.Fatalf("a person with no login added a node: %s", body)
	}
	if codes, _ := h.srv.Store.JoinCodes(20); len(codes) != 0 {
		t.Fatalf("a join code was minted for a refused scan: %+v", codes)
	}
}
