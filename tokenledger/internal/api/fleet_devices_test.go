package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/api/fleetclient"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Registered devices, renewal, revocation, the machine pick and the one-line
// install (claude-fleet#1470).

// device is a client computer in a test: its key, and the certificate it holds.
type device struct {
	signer ssh.Signer
	pub    string // authorized_keys line
	fp     string
	cert   string
}

func newDevice(t *testing.T) *device {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, _ := ssh.NewSignerFromKey(priv)
	return &device{signer: s, pub: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(s.PublicKey()))) + " alice@laptop",
		fp: ssh.FingerprintSHA256(s.PublicKey())}
}

// scan runs the whole `fleet login` for sub and keeps the certificate.
func (d *device) scan(t *testing.T, h *harness, sub, name string) CertResponse {
	t.Helper()
	code, body := postJSON(t, h, "/v1/fleet/login/start", map[string]string{"public_key": d.pub, "device_name": name})
	if code != 200 {
		t.Fatalf("start: %d %s", code, body)
	}
	var st DeviceStart
	json.Unmarshal(body, &st)
	if pc, done := personForm(t, h, sub, h.http.URL, url.Values{"code": {st.UserCode}, "action": {"approve"}}); pc != 200 || !strings.Contains(done, "已签发") {
		t.Fatalf("approve %d:\n%s", pc, done)
	}
	code, body = postJSON(t, h, "/v1/fleet/login/poll", map[string]string{"device_code": st.DeviceCode})
	if code != 200 {
		t.Fatalf("poll: %d %s", code, body)
	}
	var cr CertResponse
	json.Unmarshal(body, &cr)
	d.cert = strings.TrimSpace(cr.Certificate)
	return cr
}

// renew is `fleet login renew`: the device key signs a timestamp.
func (d *device) renew(t *testing.T, h *harness, ts int64) (int, map[string]any) {
	t.Helper()
	code, body := postJSON(t, h, control.RenewPath, map[string]any{"public_key": d.pub, "ts": ts,
		"sig": sshsig(t, d.signer, control.RenewSigNamespace, []byte(control.RenewSigMessage(ts)))})
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return code, out
}

// home is `fleet`'s ask, proven by the certificate.
func (d *device) home(t *testing.T, h *harness, last string) (int, map[string]any) {
	t.Helper()
	ts := time.Now().Unix()
	code, body := postJSON(t, h, control.HomePath, map[string]any{"cert": d.cert, "ts": ts, "last": last,
		"sig": sshsig(t, d.signer, control.HomeSigNamespace, []byte(control.HomeSigMessage(ts)))})
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return code, out
}

func (d *device) routes(t *testing.T, h *harness) int {
	t.Helper()
	ts := time.Now().Unix()
	code, _ := postJSON(t, h, control.RoutesPath, map[string]any{"cert": d.cert, "ts": ts,
		"sig": sshsig(t, d.signer, control.RoutesSigNamespace, []byte(control.RoutesSigMessage(ts)))})
	return code
}

// homeHarness: twoNodes' rig (m5 at 1.0 load/core with 3 sessions, m4 idle
// with 1), WeCom SSO, a CA, routes for both machines, and Alice adopted as
// login "verk" — the login the fleets there run as — on both.
func homeHarness(t *testing.T) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h, m5, m4, f5, f4 := twoNodes(t)
	h.srv.ViewerToken = viewerToken
	enableSSO(h)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(priv)
	h.srv.SSHCA = sshca.New(signer)
	routes, err := ParseFleetRoutes(`[
	  {"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5","port":22022}]},
	  {"hostname":"m4","routes":[{"name":"public","host":"203.0.113.4","port":22023},{"name":"tailnet","host":"m4.tail.ts.net"}]}]`)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.FleetRoutes = routes
	for _, host := range []string{"m5", "m4"} {
		if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "Alice", Hostname: host, Login: "verk"}); code != 200 {
			t.Fatalf("adopt on %s: HTTP %d", host, code)
		}
	}
	return h, m5, m4, f5, f4
}

func devicesAs(t *testing.T, h *harness, sub string) DevicesResponse {
	t.Helper()
	var code int
	var body []byte
	if sub == "" {
		r, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/fleet/devices", nil)
		r.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ = io.ReadAll(resp.Body)
		code = resp.StatusCode
	} else {
		code, body = asPerson(t, h, http.MethodGet, "/v1/fleet/devices", sub, nil)
	}
	if code != 200 {
		t.Fatalf("devices as %q: %d %s", sub, code, body)
	}
	var out DevicesResponse
	json.Unmarshal(body, &out)
	return out
}

func auditActions(a []store.DeviceAudit) string {
	parts := []string{}
	for i := len(a) - 1; i >= 0; i-- { // oldest first
		parts = append(parts, a[i].Action)
	}
	return strings.Join(parts, ",")
}

// The scan registers the computer; from then on its key alone renews the
// certificate — for the same person and login, recorded as "renew" — while a
// key nobody scanned, or the wrong key's signature, gets nothing.
func TestDeviceScanRegistersAndRenews(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)
	a.scan(t, h, "Alice", "alices-mbp")

	dev, err := h.srv.Store.Device(a.fp)
	if err != nil || dev.PrincipalID != "Alice" || dev.Name != "alices-mbp" || dev.Revoked() {
		t.Fatalf("device after the scan = %+v, %v", dev, err)
	}

	code, out := a.renew(t, h, time.Now().Unix())
	if code != 200 {
		t.Fatalf("renew: %d %v", code, out)
	}
	c := parseCert(t, out["certificate"].(string))
	if strings.Join(c.ValidPrincipals, ",") != "verk" || c.KeyId != "wecom:Alice" {
		t.Fatalf("renewed certificate says %v %q", c.ValidPrincipals, c.KeyId)
	}
	if want, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(a.pub)); !bytes.Equal(c.Key.Marshal(), want.Marshal()) {
		t.Fatal("renewed a different key")
	}
	certs, _ := h.srv.Store.FleetCerts("Alice", 10)
	if len(certs) != 2 || certs[0].Via != "renew" || certs[1].Via != "device" {
		t.Fatalf("issuances = %+v; want device then renew", certs)
	}
	dev, _ = h.srv.Store.Device(a.fp)
	if dev.Renewals != 1 {
		t.Fatalf("renewals = %d, want 1", dev.Renewals)
	}

	// The wrong signer, a stale clock, a stranger's key.
	b := newDevice(t)
	ts := time.Now().Unix()
	if code, out := postJSON(t, h, control.RenewPath, map[string]any{"public_key": a.pub, "ts": ts,
		"sig": sshsig(t, b.signer, control.RenewSigNamespace, []byte(control.RenewSigMessage(ts)))}); code != 401 || !strings.Contains(string(out), "bad_signature") {
		t.Fatalf("another key's signature: %d %s", code, out)
	}
	if code, out := a.renew(t, h, ts-3600); code != 401 || out["code"] != "bad_signature" {
		t.Fatalf("an hour-old timestamp: %d %v", code, out)
	}
	if code, out := b.renew(t, h, ts); code != 404 || out["code"] != "unknown_device" {
		t.Fatalf("a key nobody scanned: %d %v", code, out)
	}

	mine := devicesAs(t, h, "Alice")
	if !mine.Mine || len(mine.Devices) != 1 || mine.Devices[0].Fingerprint != a.fp || mine.Devices[0].PublicKey != "" {
		t.Fatalf("Alice's devices = %+v", mine)
	}
	if got := auditActions(mine.Audit); got != "register,renew" {
		t.Fatalf("Alice's audit = %s", got)
	}
	// The stranger's refusal is in the operator's audit, not Alice's.
	all := devicesAs(t, h, "")
	if all.Mine || len(all.Audit) != 3 || all.Audit[0].Action != store.DeviceRenewRefused || all.Audit[0].Fingerprint != b.fp {
		t.Fatalf("operator's audit = %+v", all.Audit)
	}
}

// Seven idle days: renewal refused until the next scan, which re-registers.
// A revocation refuses renewal at once, and the hub's own doors (the route
// list, the machine pick) refuse the still-valid certificate too; only the
// device's owner or the operator can revoke it.
func TestDeviceIdleAndRevoke(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)
	a.scan(t, h, "Alice", "laptop")

	eightDaysAgo := time.Now().Add(-8 * 24 * time.Hour)
	if err := h.srv.Store.TouchDevice(a.fp, eightDaysAgo, "", false); err != nil {
		t.Fatal(err)
	}
	if code, out := a.renew(t, h, time.Now().Unix()); code != 403 || out["code"] != "device_idle" {
		t.Fatalf("renew after 8 idle days: %d %v; want 403 device_idle", code, out)
	}
	a.scan(t, h, "Alice", "laptop") // the QR again: registered afresh
	if code, _ := a.renew(t, h, time.Now().Unix()); code != 200 {
		t.Fatalf("renew after the second scan: %d", code)
	}
	if code := a.routes(t, h); code != 200 {
		t.Fatalf("route list with the certificate: %d", code)
	}

	// Bob may not revoke Alice's device.
	body, _ := json.Marshal(map[string]string{"fingerprint": a.fp})
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/devices/revoke", "Bob", body); code != 403 {
		t.Fatalf("Bob revoking Alice's device: %d, want 403", code)
	}
	// The operator does.
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	var rev map[string]any
	json.NewDecoder(resp.Body).Decode(&rev)
	resp.Body.Close()
	if resp.StatusCode != 200 || rev["changed"] != true {
		t.Fatalf("revoke: %d %v", resp.StatusCode, rev)
	}

	if code, out := a.renew(t, h, time.Now().Unix()); code != 403 || out["code"] != "device_revoked" {
		t.Fatalf("renew after revocation: %d %v; want 403 device_revoked", code, out)
	}
	if code := a.routes(t, h); code != 401 {
		t.Fatalf("route list with a revoked device's certificate: %d, want 401", code)
	}
	if code, out := a.home(t, h, ""); code != 401 || out["code"] != "device_revoked" {
		t.Fatalf("home with a revoked device's certificate: %d %v; want 401 device_revoked", code, out)
	}
	// Revoking twice changes nothing and is not an error.
	r, _ = http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, _ = http.DefaultClient.Do(r)
	json.NewDecoder(resp.Body).Decode(&rev)
	resp.Body.Close()
	if resp.StatusCode != 200 || rev["changed"] != false {
		t.Fatalf("second revoke: %d %v", resp.StatusCode, rev)
	}

	mine := devicesAs(t, h, "Alice")
	if len(mine.Devices) != 1 || !mine.Devices[0].Revoked() || mine.Devices[0].RevokedBy != "operator" {
		t.Fatalf("Alice's device = %+v; want revoked by operator", mine.Devices)
	}
	if got := auditActions(mine.Audit); got != "register,renew_refused,register,renew,revoke,renew_refused" {
		t.Fatalf("audit = %s", got)
	}

	// A scan after the revocation registers the device again: the scan is
	// the proof, the revocation only forces it.
	a.scan(t, h, "Alice", "laptop")
	if code, _ := a.renew(t, h, time.Now().Unix()); code != 200 {
		t.Fatalf("renew after re-scan: %d", code)
	}
}

// The pick, rule by rule: the least loaded machine when the person has no
// sessions anywhere; the machine with their sessions; the machine this device
// used last while it is online — and when it is not, the next rule; none
// online: a 503 that says so, with the candidates.
func TestFleetHomePicks(t *testing.T) {
	h, m5, m4, _, _ := homeHarness(t)
	empty5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet")
	empty4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet")
	busy5 := fakeFleet(t, machineA, "fleet-m5", writeRepo, "/u/verk/claude-fleet", 1, 2, 3)
	one4 := fakeFleet(t, machineB, "fleet-m4", writeRepo, "/u/verk/claude-fleet", 2)
	settle := func(what string, cond func() bool) { waitFor(t, 3*time.Second, what, cond) }
	count := func(host string) int {
		_, rows, _ := h.srv.visibleFleets(fleetPrincipal{}, time.Now())
		n := 0
		for _, r := range rows {
			if r.Hostname == host && r.Present {
				n += r.WorkerCount
			}
		}
		return n
	}

	// 1 — no sessions anywhere: load decides. m5 runs 1.0/core, m4 0.1/core.
	m5.beatLoad("m5", "verk", machineA, 10, 0, empty5)
	m4.beatLoad("m4", "verk", machineB, 1, 0, empty4)
	settle("both fleets empty", func() bool { return count("m5") == 0 && count("m4") == 0 })
	a := newDevice(t)
	a.scan(t, h, "Alice", "laptop-a")
	code, out := a.home(t, h, "")
	if code != 200 || out["rule"] != "load" || out["machine"].(map[string]any)["hostname"] != "m4" {
		t.Fatalf("no sessions: %d %v; want m4 by load", code, out)
	}
	if out["login"] != "verk" || len(out["machines"].([]any)) != 2 || out["online"].(float64) != 2 {
		t.Fatalf("home answer lacks the route list / login: %v", out)
	}
	if rs := out["machine"].(map[string]any)["routes"].([]any); len(rs) != 2 {
		t.Fatalf("m4's routes in the answer: %v", rs)
	}

	// 2 — Alice's sessions: three on m5, one on m4 → m5, load notwithstanding.
	m5.beatLoad("m5", "verk", machineA, 10, 3, busy5)
	m4.beatLoad("m4", "verk", machineB, 1, 1, one4)
	settle("sessions registered", func() bool { return count("m5") == 3 && count("m4") == 1 })
	b := newDevice(t)
	b.scan(t, h, "Alice", "laptop-b")
	if code, out := b.home(t, h, ""); code != 200 || out["rule"] != "sessions" || out["machine"].(map[string]any)["hostname"] != "m5" {
		t.Fatalf("with sessions: %d %v; want m5 by sessions", code, out)
	}
	// Device A's own last machine is m4 (step 1); it is online, so A keeps it.
	if code, out := a.home(t, h, ""); code != 200 || out["rule"] != "last" || out["machine"].(map[string]any)["hostname"] != "m4" {
		t.Fatalf("device A, last m4 online: %d %v; want m4 by last", code, out)
	}
	// The client's own hint wins over the device record.
	if code, out := a.home(t, h, "m5"); code != 200 || out["rule"] != "last" || out["machine"].(map[string]any)["hostname"] != "m5" {
		t.Fatalf("hint m5: %d %v", code, out)
	}
	dev, _ := h.srv.Store.Device(a.fp)
	if dev.LastMachine != "m5" {
		t.Fatalf("device A last_machine = %q, want m5", dev.LastMachine)
	}

	// 3 — m5 goes offline: the device that last used m5 lands on m4.
	hb5, _ := json.Marshal(control.Heartbeat{Hostname: "m5", OSUser: "verk", MachineID: machineA, Load1: 10, NCPU: 10, Sessions: 3})
	if err := h.srv.Store.NodeHeartbeat("ep_m5", "m5", "verk", machineA, control.Proto, string(hb5), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	code, out = a.home(t, h, "")
	if code != 200 || out["rule"] != "sessions" || out["machine"].(map[string]any)["hostname"] != "m4" || out["online"].(float64) != 1 {
		t.Fatalf("m5 offline: %d %v; want m4", code, out)
	}
	for _, c := range out["candidates"].([]any) {
		cm := c.(map[string]any)
		if cm["machine"] == "m5" && (cm["online"] != false || cm["last"] != true) {
			t.Fatalf("m5 candidate = %v; want offline and marked last", cm)
		}
	}

	// 4 — both offline: nothing to enter, said plainly.
	hb4, _ := json.Marshal(control.Heartbeat{Hostname: "m4", OSUser: "verk", MachineID: machineB, Load1: 1, NCPU: 10, Sessions: 1})
	if err := h.srv.Store.NodeHeartbeat("ep_m4", "m4", "verk", machineB, control.Proto, string(hb4), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	code, out = a.home(t, h, "")
	if code != 503 || out["code"] != "no_machine_online" || out["error"] != "你的机器都不在线" {
		t.Fatalf("all offline: %d %v; want 503 no_machine_online", code, out)
	}
	if home := out["home"].(map[string]any); home["machine"] != nil || len(home["candidates"].([]any)) != 2 {
		t.Fatalf("all offline answer lacks the candidates: %v", home)
	}

	// Every ask was audited on the device, with the pick.
	mine := devicesAs(t, h, "Alice")
	homes := 0
	for _, row := range mine.Audit {
		if row.Action == store.DeviceHome && row.Fingerprint == a.fp {
			homes++
		}
	}
	if homes != 5 {
		t.Fatalf("device A home audits = %d, want 5", homes)
	}

	// The operator's door asks too (a token, GET): every machine, no login.
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+control.HomePath+"?last=m4", nil)
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	var op map[string]any
	json.NewDecoder(resp.Body).Decode(&op)
	resp.Body.Close()
	if resp.StatusCode != 503 || len(op["home"].(map[string]any)["candidates"].([]any)) != 2 {
		t.Fatalf("operator's ask with everything offline: %d %v", resp.StatusCode, op)
	}
}

// Anyone may fetch the installer, the manifest and every client file on it;
// the script carries this hub's URL, each file its SHA-256; a hub that cannot
// sign anyone in serves none of it.
func TestInstallServed(t *testing.T) {
	needPacked(t)
	h, _ := certHarness(t)
	get := func(path string) (*http.Response, []byte) {
		resp, err := http.Get(h.http.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, b
	}
	resp, body := get("/install")
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/x-shellscript") {
		t.Fatalf("/install: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	script := string(body)
	if !strings.HasPrefix(script, "#!/bin/sh") || strings.Contains(script, fleetclient.HubPlaceholder) ||
		!strings.Contains(script, `HUB="${FLEET_HUB_URL:-`+h.http.URL+`}"`) {
		t.Fatalf("installer did not get this hub's URL:\n%s", script[:300])
	}
	// The manifest is a download of its own (claude-fleet#1486): the installer
	// walks the list this build embeds, so the two can never disagree.
	resp, body = get("/install/" + fleetclient.ManifestName)
	sum := sha256.Sum256(body)
	if resp.StatusCode != 200 || resp.Header.Get("X-Ccquota-Sha256") != hex.EncodeToString(sum[:]) ||
		!strings.HasPrefix(resp.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("/install/manifest: %d sha %q ct %q", resp.StatusCode, resp.Header.Get("X-Ccquota-Sha256"), resp.Header.Get("Content-Type"))
	}
	if inst, names := fleetclient.ParseManifest(body); inst != fleetclient.Installer || !reflect.DeepEqual(names, fleetclient.Names) {
		t.Fatalf("served manifest parses to %q %v, the build has %q %v", inst, names, fleetclient.Installer, fleetclient.Names)
	}
	for _, name := range fleetclient.Names {
		resp, body := get("/install/" + name)
		sum := sha256.Sum256(body)
		if resp.StatusCode != 200 || resp.Header.Get("X-Ccquota-Sha256") != hex.EncodeToString(sum[:]) {
			t.Fatalf("/install/%s: %d sha %q", name, resp.StatusCode, resp.Header.Get("X-Ccquota-Sha256"))
		}
		ct := resp.Header.Get("Content-Type")
		switch {
		case strings.HasPrefix(name, "bin/") && !bytes.HasPrefix(body, []byte("#")):
			t.Fatalf("/install/%s: a bin/ file is a script or a sourced lib (a comment first), got %q", name, body[:min(len(body), 20)])
		case strings.HasSuffix(name, ".py") && !strings.HasPrefix(ct, "text/x-python"):
			t.Fatalf("/install/%s: content-type %q", name, ct)
		case strings.HasSuffix(name, ".conf") && !strings.HasPrefix(ct, "text/plain"):
			t.Fatalf("/install/%s: content-type %q", name, ct)
		case strings.HasSuffix(name, ".sh") && !strings.HasPrefix(ct, "text/x-shellscript"):
			t.Fatalf("/install/%s: content-type %q", name, ct)
		}
	}
	if resp, _ := get("/install/" + fleetclient.Installer); resp.StatusCode != 404 {
		t.Fatalf("the template is not a download: %d", resp.StatusCode)
	}
	if resp, _ := get("/install/fleet"); resp.StatusCode != 404 {
		t.Fatalf("the pre-#1486 flat name is gone — the manifest's paths are the URLs: %d", resp.StatusCode)
	}
	if resp, _ := get("/install/embed.go"); resp.StatusCode != 404 {
		t.Fatalf("only the named client files are served: %d", resp.StatusCode)
	}
	// The 连接 page's API carries the line to copy.
	code, body := asPerson(t, h, http.MethodGet, "/v1/fleet/connect", "Alice", nil)
	var ci ConnectInfo
	json.Unmarshal(body, &ci)
	if code != 200 || ci.InstallCommand != "curl -fsSL "+h.http.URL+"/install | sh" || !ci.InstallReady {
		t.Fatalf("connect info: %d %+v", code, ci)
	}

	h.srv.SSHCA = nil
	for _, p := range []string{"/install", "/install/manifest", "/install/bin/fleet"} {
		if resp, _ := get(p); resp.StatusCode != 404 {
			t.Fatalf("%s without a CA: %d, want 404", p, resp.StatusCode)
		}
	}
}

// needPacked fails a test that drives the served client in a build that
// carries none: the client is packed from the repo before a build
// (claude-fleet#1803), so `go test` without it has nothing to serve.
func needPacked(t *testing.T) {
	t.Helper()
	if !fleetclient.Packed {
		t.Fatal("this build carries no client — run bin/fleet-client-pack.sh first (CI does)")
	}
}

// The repo keeps ONE copy of each client file (claude-fleet#1803) and the
// manifest is the one list: every path it names exists in the repo, no copy is
// committed under fleetclient/, and — when this build was packed — the pack is
// exactly the manifest's files, each byte-for-byte the repo's. Skipped where
// the repo is not beside the module. bin/fleet-client-mirror.sh --check and
// bin/fleet-client-pack.sh --check are the shell twins.
func TestFleetClientMatchesBin(t *testing.T) {
	repo := filepath.Join("..", "..", "..")
	if _, err := os.Stat(filepath.Join(repo, "bin", "fleet")); err != nil {
		t.Skip("no bin/ beside the module")
	}
	listed := map[string]bool{fleetclient.ManifestName: true}
	for _, name := range append([]string{fleetclient.Installer}, fleetclient.Names...) {
		listed[name] = true
		want, err := os.ReadFile(filepath.Join(repo, filepath.FromSlash(name)))
		if err != nil {
			t.Errorf("%s is in the manifest but not in the repo: %v", name, err)
			continue
		}
		if !fleetclient.Packed {
			continue
		}
		got, err := fleetclient.Files.ReadFile(name)
		if err != nil {
			t.Errorf("%s is in the manifest but not packed — run bin/fleet-client-pack.sh: %v", name, err)
		} else if !bytes.Equal(got, want) {
			t.Errorf("pack/%s differs from %s — run bin/fleet-client-pack.sh", name, name)
		}
	}
	// The shell (claude-fleet#1484) ships: #1486 is what put it on the list.
	// …and the Agent configuration package (claude-fleet#1725): its list, the
	// hook table + shim, a skill, and the mod's manifest under a dot directory
	// (embedded only through `all:pack`).
	for _, must := range []string{"bin/fleet", "bin/fleet-shell.sh", "bin/fleet-sidebar.py", "bin/tmux-status.sh", "conf/tmux-shell.conf",
		"conf/agent-bundle.manifest", "bin/fleet-agent-bundle.py", "hooks/settings-hooks.json", "bin/fleet-hook-run.sh",
		"skills/doc-preview/SKILL.md", "mod/fleet/.claude-plugin/plugin.json"} {
		if !listed[must] {
			t.Errorf("manifest does not list %s", must)
		}
	}
	// one copy: nothing but the manifest, the Go sources and pack/ (a build
	// input, gitignored) under fleetclient/
	ents, err := os.ReadDir(filepath.Join("fleetclient"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if n := e.Name(); n != fleetclient.ManifestName && n != "pack" && !strings.HasSuffix(n, ".go") {
			t.Errorf("fleetclient/%s: the repo keeps one copy of the client — a build packs it (bin/fleet-client-pack.sh)", n)
		}
	}
	if err := fs.WalkDir(fleetclient.Files, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && !listed[p] && p != fleetclient.PackPlaceholder {
			t.Errorf("pack/%s is embedded but not in the manifest — run bin/fleet-client-pack.sh", p)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}
