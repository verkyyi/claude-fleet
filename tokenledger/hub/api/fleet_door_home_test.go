package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The door's way home (A5SQ).

// doorHomeDial opens DoorHomePath?principal= with tok; a refused stream is its
// code ("HTTP <n>" before the upgrade), else the open websocket.
func doorHomeDial(t *testing.T, h *harness, tok, person string) (*websocket.Conn, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.DoorHomePath + "?principal=" + url.QueryEscape(person)
	c, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + tok}}})
	if err != nil {
		if resp != nil {
			return nil, "HTTP " + http.StatusText(resp.StatusCode)
		}
		t.Fatalf("dial the way home: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	var m control.SSHRelayHello
	if err := wsjson.Read(ctx, c, &m); err != nil {
		t.Fatalf("the way home's handshake: %v", err)
	}
	if m.Type == "error" {
		return nil, m.Code
	}
	if m.Type != "ready" {
		t.Fatalf("unexpected frame %+v", m)
	}
	return c, ""
}

// playEntryAgent answers the next relay request on the home's link c the way
// the agent does — only one aimed at the entry port — and echoes the stream.
func playEntryAgent(t *testing.T, h *harness, c *websocket.Conn, tok string) <-chan string {
	t.Helper()
	got := make(chan string, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		for {
			var m control.Message
			if err := wsjson.Read(ctx, c, &m); err != nil {
				got <- "read: " + err.Error()
				return
			}
			if m.Type != control.TypeSSHRelayOpen {
				continue
			}
			var ro control.SSHRelayOpen
			_ = json.Unmarshal(m.Payload, &ro)
			got <- "target=" + ro.Target
			url := "ws" + strings.TrimPrefix(h.http.URL, "http") + control.SSHRelayDataPath + "?id=" + ro.RelayID
			d, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPHeader: http.Header{
				"Authorization": {"Bearer " + tok}, "X-Relay-Secret": {ro.Secret}}})
			if err != nil {
				return
			}
			defer d.CloseNow()
			for {
				typ, b, err := d.Read(ctx)
				if err != nil {
					return
				}
				if d.Write(ctx, typ, append([]byte("home:"), b...)) != nil {
					return
				}
			}
		}
	}()
	return got
}

// doorSig signs, as the person's ssh client does, a publickey login of user
// on session — the request the door hands in.
func doorSig(t *testing.T, signer ssh.Signer, session []byte, user string, doorKey string) control.DoorSessionRequest {
	t.Helper()
	algo := signer.PublicKey().Type()
	sig, err := signer.Sign(rand.Reader, doorSignedData(session, user, algo, signer.PublicKey()))
	if err != nil {
		t.Fatal(err)
	}
	return control.DoorSessionRequest{Key: strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey()))),
		User: user, SessionID: base64.StdEncoding.EncodeToString(session), Algo: algo,
		Sig: base64.StdEncoding.EncodeToString(ssh.Marshal(sig)), DoorKey: doorKey}
}

func newSigner(t *testing.T) ssh.Signer {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func randSession(t *testing.T) []byte {
	b := make([]byte, 32)
	rand.Read(b)
	return b
}

type doorRig struct {
	h        *harness
	dtok     string
	alice    ssh.Signer
	door     ssh.Signer
	doorKey  string
	homeTok0 string
}

// newDoorRig: a hub with a door; Alice's home is the machine mac-e (login
// alice) with one key of hers, Bob's a pod.
func newDoorRig(t *testing.T) doorRig {
	t.Helper()
	h := entryHarness(t)
	if err := h.srv.Store.SetFleetSetting(DoorKey, "fleet-door", time.Now()); err != nil {
		t.Fatal(err)
	}
	_, dtok := rootNode(t, h, "door", "fleet-door", control.CapEntryKeys)
	r := doorRig{h: h, dtok: dtok, alice: newSigner(t), door: newSigner(t)}
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(r.alice.PublicKey()))) + " alice-phone"
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line}); code != http.StatusCreated {
		t.Fatalf("Alice adds a key: HTTP %d %s", code, raw)
	}
	doorHome(t, h, pBob, "u-bob123", "bob")
	doorHome(t, h, pAlice, "mac-e", "alice")
	r.doorKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(r.door.PublicKey())))
	_, r.homeTok0 = rootNode(t, h, "homelist", "mac-e")
	return r
}

func (r doorRig) post(t *testing.T, tok string, req control.DoorSessionRequest) (int, control.DoorSessionCert, string) {
	t.Helper()
	code, raw := entryCall(t, r.h, http.MethodPost, control.DoorSessionPath, asNode(tok), req)
	var c control.DoorSessionCert
	_ = json.Unmarshal([]byte(raw), &c)
	return code, c, raw
}

// The door's book carries the people whose home is a machine only when it
// asks (an older door reads the list byte for byte); a home's list carries
// the door-session CA — its own key, never the SSH CA's.
func TestDoorHomesOnlyWhenTheDoorAsks(t *testing.T) {
	r := newDoorRig(t)
	if code, _, raw := doorRoutes(t, r.h, r.dtok); code != 200 || strings.Contains(raw, `"homes"`) {
		t.Fatalf("a door that did not ask: HTTP %d %s", code, raw)
	}
	code, raw := entryCall(t, r.h, http.MethodGet, control.EntryRoutesNodePath+"?home=1", asNode(r.dtok), nil)
	var lst control.EntryRouteList
	if err := json.Unmarshal([]byte(raw), &lst); code != 200 || err != nil {
		t.Fatalf("the door asks for the homes: HTTP %d %v %s", code, err, raw)
	}
	if len(lst.Homes) != 1 || lst.Homes[0].Login != "alice" || lst.Homes[0].Principal != pAlice || len(lst.Homes[0].Keys) != 1 {
		t.Fatalf("Homes %+v; want Alice's alone (Bob's home is a pod), her one key", lst.Homes)
	}
	if _, nl, raw := nodeList(t, r.h, r.homeTok0); nl.DoorCA == "" || nl.DoorCA == r.h.srv.SSHCA.PublicKey() || nl.DoorCA != r.h.srv.doorSessionCA().PublicKey() {
		t.Fatalf("the home's list: door_ca %q (%s)", nl.DoorCA, raw)
	}
}

// BREAK-IT door-session-no-sig: the door — even one taken over, holding its
// own token and its whole book — gets a certificate only for a signature the
// person made over THIS session as THIS user, by THEIR key, asked by the door.
// The certificate admits the person's home login alone, from loopback, for
// two minutes, signed by the door-session CA.
func TestDoorSessionNeedsTheirSignature(t *testing.T) {
	r := newDoorRig(t)
	session := randSession(t)
	req := doorSig(t, r.alice, session, "alice", r.doorKey)
	if code, _, raw := r.post(t, r.homeTok0, req); code != http.StatusForbidden {
		t.Fatalf("not the door's token: HTTP %d %s", code, raw)
	}
	if code, _, raw := r.post(t, r.dtok, doorSig(t, r.door, session, "alice", r.doorKey)); code != http.StatusForbidden {
		t.Fatalf("the door signing for Alice with its own key: HTTP %d %s", code, raw)
	}
	other := req
	other.SessionID = base64.StdEncoding.EncodeToString(randSession(t))
	if code, _, raw := r.post(t, r.dtok, other); code != http.StatusForbidden {
		t.Fatalf("her signature over another session: HTTP %d %s", code, raw)
	}
	if code, _, raw := r.post(t, r.dtok, doorSig(t, r.alice, randSession(t), "bob", r.doorKey)); code != http.StatusForbidden {
		t.Fatalf("her key as bob: HTTP %d %s", code, raw)
	}
	noSig := req
	noSig.Sig = ""
	if code, _, raw := r.post(t, r.dtok, noSig); code < 400 {
		t.Fatalf("no signature: HTTP %d %s", code, raw)
	}
	code, c, raw := r.post(t, r.dtok, req)
	if code != 200 || c.Login != "alice" || c.Principal != pAlice || c.Machine != "mac-e" {
		t.Fatalf("Alice's fresh signature: HTTP %d %s", code, raw)
	}
	pk, _, _, _, err := ssh.ParseAuthorizedKey([]byte(c.Cert))
	cert, ok := pk.(*ssh.Certificate)
	if err != nil || !ok {
		t.Fatalf("cert %q: %v", c.Cert, err)
	}
	if strings.TrimSpace(string(ssh.MarshalAuthorizedKey(cert.SignatureKey))) != r.h.srv.doorSessionCA().PublicKey() ||
		string(cert.Key.Marshal()) != string(r.door.PublicKey().Marshal()) || len(cert.ValidPrincipals) != 1 ||
		cert.ValidPrincipals[0] != "alice" || !strings.HasPrefix(cert.KeyId, "door:"+pAlice+":") ||
		cert.CriticalOptions["source-address"] != "127.0.0.1/32,::1/128" {
		t.Fatalf("the certificate: %+v", cert)
	}
	if left := time.Until(time.Unix(int64(cert.ValidBefore), 0)); left > control.DoorSessionTTL+time.Minute {
		t.Fatalf("lives %s", left)
	}
}

// BREAK-IT door-session-replay: a signature is good for one certificate — the
// same session handed in again is refused, on this replica and any other
// (the claim is the store's).
func TestDoorSessionOnce(t *testing.T) {
	r := newDoorRig(t)
	req := doorSig(t, r.alice, randSession(t), "alice", r.doorKey)
	if code, _, raw := r.post(t, r.dtok, req); code != 200 {
		t.Fatalf("first: HTTP %d %s", code, raw)
	}
	if code, _, raw := r.post(t, r.dtok, req); code != http.StatusConflict {
		t.Fatalf("the same signature twice: HTTP %d %s", code, raw)
	}
	again := req
	again.DoorKey = strings.TrimSpace(string(ssh.MarshalAuthorizedKey(newSigner(t).PublicKey())))
	if code, _, raw := r.post(t, r.dtok, again); code != http.StatusConflict {
		t.Fatalf("the same signature for another door key: HTTP %d %s", code, raw)
	}
	if ok, err := r.h.srv.Store.ClaimDoorSession("x", pAlice, time.Now()); !ok || err != nil {
		t.Fatalf("a new session: %v %v", ok, err)
	}
	if ok, _ := r.h.srv.Store.ClaimDoorSession("x", pAlice, time.Now().Add(time.Minute)); ok {
		t.Fatal("a session twice within the keep")
	}
}

// BREAK-IT door-home-not-door: the stream to a person's home opens only for
// the door, only to a home that is a machine, and lands on that home's entry
// port through its agent — never its sshd.
func TestDoorHomeStreamOnlyTheDoor(t *testing.T) {
	r := newDoorRig(t)
	hc, htok := rootNode(t, r.h, "homea", "mac-e", control.CapSSHRelay, control.CapEntryRelay)
	if _, code := doorHomeDial(t, r.h, htok, pAlice); !strings.HasPrefix(code, "HTTP Forbidden") {
		t.Fatalf("the home's own token: %s, want 403", code)
	}
	if _, code := doorHomeDial(t, r.h, r.dtok, pBob); code != "NOT_FOUND" {
		t.Fatalf("a pod's person: %s, want NOT_FOUND", code)
	}
	got := playEntryAgent(t, r.h, hc, htok)
	conn, why := doorHomeDial(t, r.h, r.dtok, pAlice)
	if conn == nil {
		t.Fatalf("the stream home refused: %s", why)
	}
	if g := <-got; g != "target=entry" {
		t.Fatalf("the agent was asked %s, want target=entry", g)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("SSH-2.0-door")); err != nil {
		t.Fatal(err)
	}
	_, b, err := conn.Read(ctx)
	if err != nil || string(b) != "home:SSH-2.0-door" {
		t.Fatalf("through the stream: %q %v", b, err)
	}
}

// The phone page leads with the door's one address (A5SQ ⑤) only when it is
// set, a door said it carries homes, and the person's home can take the
// stream: their own login, the DOOR's host key fingerprint, the code. Absent
// any of the three: no shared block, the page as before.
func TestPhonePageLeadsWithTheOneAddress(t *testing.T) {
	r := newDoorRig(t)
	now := time.Now()
	if d := entryDoor(t, r.h, pAlice); d.Shared != nil {
		t.Fatalf("no address set, yet %+v", d.Shared)
	}
	if err := r.h.srv.Store.SetFleetSetting(DoorAddressKey, "door.example.com", now); err != nil {
		t.Fatal(err)
	}
	if d := entryDoor(t, r.h, pAlice); d.Shared != nil {
		t.Fatalf("no door said it carries homes, yet %+v", d.Shared)
	}
	if code, raw := entryCall(t, r.h, http.MethodGet, control.EntryRoutesNodePath+"?home=1", asNode(r.dtok), nil); code != 200 {
		t.Fatalf("the door's pull: HTTP %d %s", code, raw)
	}
	if d := entryDoor(t, r.h, pAlice); d.Shared != nil {
		t.Fatalf("the home cannot take the stream, yet %+v", d.Shared)
	}
	dk := reachKeyLine(reachKey(t))
	if err := r.h.srv.Store.SetEntryHostKey("fleet-door", dk, now); err != nil {
		t.Fatal(err)
	}
	rootNode(t, r.h, "homea", "mac-e", control.CapSSHRelay, control.CapEntryRelay)
	d := entryDoor(t, r.h, pAlice)
	if d.Shared == nil || d.Shared.Address != "door.example.com" || d.Shared.Port != entryPort || d.Shared.Login != "alice" ||
		d.Shared.HostFP != r.h.srv.entryHostFP("fleet-door") || d.Shared.HostFP == "" || len(d.Shared.QR) < 21 {
		t.Fatalf("shared %+v", d.Shared)
	}
	// Bob's home is a pod: the one address does not take him (the jump does)
	if b := entryDoor(t, r.h, pBob); b.Shared != nil {
		t.Fatalf("a pod's person: %+v", b.Shared)
	}
	for v, ok := range map[string]bool{"door.example.com": true, "door.example.com:2222": true, "10.0.0.1:22022": true,
		"door..example.com": false, "door.example.com:0": false, "door.example.com:99999": false, "-x.example": false, "a b": false} {
		if _, _, got := doorAddress(v); got != ok {
			t.Errorf("doorAddress(%q) = %v, want %v", v, got, ok)
		}
	}
}
