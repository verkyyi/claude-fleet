package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"encoding/pem"
	"log"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The direct door's book (claude-fleet#3068, EPIC #3067 C1).

func entryCall(t *testing.T, h *harness, method, path string, auth func(http.Header), body any) (int, string) {
	t.Helper()
	rd := bytes.NewReader(nil)
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
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
	return resp.StatusCode, raw.String()
}

func entryKeyLine(t *testing.T, comment string) string {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	pk, _ := ssh.NewPublicKey(pub)
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pk))) + " " + comment
}

// rootNode is a machine's node program on host: its own token, a root
// heartbeat, the hello listing caps.
func rootNode(t *testing.T, h *harness, label, host string, caps ...string) (*websocket.Conn, string) {
	t.Helper()
	tok := h.enroll(t, label)
	c := teamNode(t, h, tok, caps...)
	beat(t, c, control.Proto, control.Heartbeat{Hostname: host, OSUser: "root"})
	waitFor(t, 3*time.Second, label+" on the roster", func() bool {
		n := h.srv.nodeRow("ep_" + label)
		return n != nil && n.Hostname == host && n.OSUser == "root"
	})
	return c, tok
}

// nextEntry reads the next message and wants entry_keys carrying v.
func nextEntry(t *testing.T, c *websocket.Conn, v int, what string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var m control.Message
		if err := wsjson.Read(ctx, c, &m); err != nil {
			t.Fatalf("%s: no message: %v", what, err)
		}
		var e control.EntryKeys
		_ = json.Unmarshal(m.Payload, &e)
		// an earlier version's push may still be in flight (the connect's, a previous
		// change's — claude-fleet#3703): pass over it; a newer one or anything else is wrong
		if m.Type == control.TypeEntryKeys && e.Version < v {
			continue
		}
		if m.Type != control.TypeEntryKeys || e.Version != v {
			t.Fatalf("%s: got %s %s, want entry_keys v%d", what, m.Type, m.Payload, v)
		}
		return
	}
}

func nodeList(t *testing.T, h *harness, tok string) (int, control.EntryNodeList, string) {
	t.Helper()
	code, raw := entryCall(t, h, http.MethodGet, control.EntryKeysNodePath, asNode(tok), nil)
	var out control.EntryNodeList
	_ = json.Unmarshal([]byte(raw), &out)
	return code, out, raw
}

// entryHarness: Alice has logins with a live fleet on macmini and
// macmini-m4, Bob on macmini-m4; the door is on.
func entryHarness(t *testing.T) *harness {
	t.Helper()
	h, _ := certHarness(t)
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pBob, Hostname: "macmini-m4", Login: "bob"}); code != 200 {
		t.Fatalf("adopt bob: HTTP %d", code)
	}
	loginReportsFleet(t, h, "macmini", "alice", "00000000-0000-4000-8000-000000000005")
	loginReportsFleet(t, h, "macmini-m4", "alice", "00000000-0000-4000-8000-000000000004")
	loginReportsFleet(t, h, "macmini-m4", "bob", "00000000-0000-4000-8000-0000000000b4")
	if err := h.srv.Store.SetFleetSetting(EntryKey, "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	return h
}

// The completion criterion: keys are their owner's alone (another person
// reads and writes 404, the same key for two people is 409); a revoke moves
// the version and reaches the person's home machine, no other machine and no
// machine without the capability; a home moves only to a login with a live
// fleet, and both machines hear it.
func TestEntryKeysPushToHomeOnly(t *testing.T) {
	h := entryHarness(t)
	m5, tok5 := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	m4, tok4 := rootNode(t, h, "root4", "macmini-m4", control.CapEntryKeys)
	old, _ := rootNode(t, h, "root-old", "macmini", control.CapRead) // an older agent

	// Alice makes macmini her home, and gets her suggested name with it
	// (#3337): only macmini hears it, once.
	code, raw := entryCall(t, h, http.MethodPut, control.EntryHomePath, asSession(pAlice), map[string]any{"machine": "macmini"})
	if code != 200 || !strings.Contains(raw, `"login":"alice"`) || !strings.Contains(raw, `"version":2`) {
		t.Fatalf("Alice's home → macmini: HTTP %d %s", code, raw)
	}
	nextEntry(t, m5, 2, "macmini after the home is set and her suggested name claimed (#3337)")

	// A key: added (201), the version moves, the home hears it.
	line := entryKeyLine(t, "alice-phone")
	code, raw = entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line})
	if code != http.StatusCreated {
		t.Fatalf("Alice adds a key: HTTP %d %s", code, raw)
	}
	var k store.EntryKey
	_ = json.Unmarshal([]byte(raw), &k)
	if k.ID == "" || !strings.HasPrefix(k.FP, "SHA256:") || k.Type != ssh.KeyAlgoED25519 || k.Name != "alice-phone" {
		t.Fatalf("added key %+v", k)
	}
	nextEntry(t, m5, 3, "macmini after the key")
	// The same key again is hers already: 200, the version stays.
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line}); code != 200 || !strings.Contains(raw, k.ID) {
		t.Fatalf("Alice adds the same key again: HTTP %d %s, want 200 with the same key", code, raw)
	}

	// The machine reads it with its own token; a login's token cannot.
	code, list, raw := nodeList(t, h, tok5)
	if code != 200 || list.Version != 3 || len(list.Logins) != 1 || list.Logins["alice"].Person != pAlice ||
		len(list.Logins["alice"].Keys) != 1 || list.Logins["alice"].Keys[0].FP != k.FP || !strings.Contains(line, list.Logins["alice"].Keys[0].B64) {
		t.Fatalf("macmini's list: HTTP %d %s", code, raw)
	}
	// The label rides along (claude-fleet#3071: the home's 看台 names the device
	// by it); the key's comment never does.
	if list.Logins["alice"].Keys[0].Name != "alice-phone" {
		t.Fatalf("the node's list lacks the key's label: %s", raw)
	}
	if code, _, raw := nodeList(t, h, h.tokens["macmini-alice"]); code != http.StatusForbidden {
		t.Fatalf("a login's token reads the list: HTTP %d %s, want 403", code, raw)
	}

	// Bob: the same key is 409; Alice's key, read or written by Bob, is 404.
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pBob), map[string]any{"public_key": line}); code != http.StatusConflict {
		t.Fatalf("Bob adds Alice's key: HTTP %d %s, want 409", code, raw)
	}
	if code, raw := entryCall(t, h, http.MethodDelete, control.EntryKeysPath+"/"+k.ID, asSession(pBob), nil); code != http.StatusNotFound {
		t.Fatalf("Bob revokes Alice's key: HTTP %d %s, want 404", code, raw)
	}
	if code, raw := entryCall(t, h, http.MethodPatch, control.EntryKeysPath+"/"+k.ID, asSession(pBob), map[string]any{"name": "mine"}); code != http.StatusNotFound {
		t.Fatalf("Bob renames Alice's key: HTTP %d %s, want 404", code, raw)
	}
	if code, raw := entryCall(t, h, http.MethodGet, control.EntryKeysPath+"?principal="+pAlice, asSession(pBob), nil); code != http.StatusNotFound {
		t.Fatalf("Bob reads Alice's keys: HTTP %d %s, want 404", code, raw)
	}
	// Bob's first visit gives him his one live fleet as home: macmini-m4 hears it.
	code, raw = entryCall(t, h, http.MethodGet, control.EntryKeysPath, asSession(pBob), nil)
	if code != 200 || strings.Contains(raw, k.ID) || !strings.Contains(raw, `"machine":"macmini-m4","login":"bob","set_by":"auto"`) {
		t.Fatalf("Bob's own view: HTTP %d %s", code, raw)
	}
	nextEntry(t, m4, 5, "macmini-m4 after Bob's first home and his name, in one push")

	// Alice revokes: v6 reaches macmini, and her key is gone from its list.
	code, raw = entryCall(t, h, http.MethodDelete, control.EntryKeysPath+"/"+k.ID, asSession(pAlice), nil)
	if code != 200 || !strings.Contains(raw, `"revoked_at"`) {
		t.Fatalf("Alice revokes: HTTP %d %s", code, raw)
	}
	nextEntry(t, m5, 6, "macmini after the revoke")
	if _, list, raw := nodeList(t, h, tok5); list.Version != 6 || len(list.Logins["alice"].Keys) != 0 {
		t.Fatalf("macmini's list after the revoke: %s", raw)
	}
	// Revoked once is revoked: no new version.
	if code, _ := entryCall(t, h, http.MethodDelete, control.EntryKeysPath+"/"+k.ID, asSession(pAlice), nil); code != 200 {
		t.Fatalf("revoke twice: HTTP %d", code)
	}
	// A revoked key holds no one: Bob may add it now.
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pBob), map[string]any{"public_key": line}); code != http.StatusCreated {
		t.Fatalf("Bob adds the key Alice revoked: HTTP %d %s, want 201", code, raw)
	}
	nextEntry(t, m4, 7, "macmini-m4 after Bob's key (and nothing for Alice's revoke before it)")

	// A home only goes where a live fleet is; a move reaches both machines.
	for name, body := range map[string]map[string]any{
		"no login there":       {"machine": "spare"},
		"someone else's login": {"machine": "macmini-m4", "login": "bob"},
	} {
		if code, raw := entryCall(t, h, http.MethodPut, control.EntryHomePath, asSession(pAlice), body); code != http.StatusUnprocessableEntity {
			t.Fatalf("Alice's home → %s: HTTP %d %s, want 422", name, code, raw)
		}
	}
	if code, raw := entryCall(t, h, http.MethodPut, control.EntryHomePath, asSession(pAlice), map[string]any{"machine": "m4"}); code != 200 || !strings.Contains(raw, `"version":8`) {
		t.Fatalf("Alice's home → m4: HTTP %d %s", code, raw)
	}
	nextEntry(t, m5, 8, "the old home after the move")
	nextEntry(t, m4, 8, "the new home after the move")
	if _, list, raw := nodeList(t, h, tok5); len(list.Logins) != 0 {
		t.Fatalf("macmini still lists someone after Alice moved away: %s", raw)
	}
	if _, list, raw := nodeList(t, h, tok4); len(list.Logins) != 2 || list.Logins["alice"].Person != pAlice || list.Logins["bob"].Person != pBob {
		t.Fatalf("macmini-m4's list after the move: %s", raw)
	}

	// The node without the capability heard nothing, ever.
	silent(t, old, "no CapEntryKeys")
	// A machine that reconnects hears the current version on its first beat.
	m5.CloseNow()
	m5b := teamNode(t, h, tok5, control.CapEntryKeys)
	beat(t, m5b, control.Proto, control.Heartbeat{Hostname: "macmini", OSUser: "root"})
	nextEntry(t, m5b, 8, "macmini reconnects")
}

// A private key pasted by mistake is refused, not stored, and appears in no
// log line — nor does the request body.
func TestEntryRefusesPrivateKeyAndLogsNothingOfIt(t *testing.T) {
	h := entryHarness(t)
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	blk, err := ssh.MarshalPrivateKey(priv, "phone")
	if err != nil {
		t.Fatal(err)
	}
	pemText := string(pem.EncodeToMemory(blk))
	secret := strings.Split(pemText, "\n")[2] // a line of the key's body

	var buf bytes.Buffer
	var mu sync.Mutex
	log.SetOutput(&lockedWriter{w: &buf, mu: &mu})
	t.Cleanup(func() { log.SetOutput(logDefault) })

	for name, body := range map[string]string{"PEM": pemText, "PEM after a public key": entryKeyLine(t, "x") + "\n" + pemText} {
		code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": body, "name": "phone"})
		if code != http.StatusUnprocessableEntity || !strings.Contains(raw, "私钥") || strings.Contains(raw, secret) {
			t.Fatalf("%s: HTTP %d %s, want 422 naming a private key and echoing none of it", name, code, raw)
		}
	}
	if keys, _ := h.srv.Store.EntryKeys(pAlice, true); len(keys) != 0 {
		t.Fatalf("a private key left %d rows", len(keys))
	}
	if v, _ := h.srv.Store.EntryVersion(); v != 0 {
		t.Fatalf("a refused key moved the version to %d", v)
	}
	audits, _ := h.srv.Store.EntryAudits(pAlice, 10)
	if len(audits) != 2 || audits[0].Result != "refused: private key" {
		t.Fatalf("audit %+v, want two refusals", audits)
	}
	for _, a := range audits {
		if b, _ := json.Marshal(a); strings.Contains(string(b), secret) {
			t.Fatalf("the audit holds the key: %s", b)
		}
	}
	mu.Lock()
	logged := buf.String()
	mu.Unlock()
	if strings.Contains(logged, secret) || strings.Contains(logged, "PRIVATE KEY") {
		t.Fatalf("the log holds the private key:\n%s", logged)
	}

	// The other refusals: short RSA, options, a certificate, nonsense.
	rk, _ := rsa.GenerateKey(rand.Reader, 2048)
	rpub, _ := ssh.NewPublicKey(&rk.PublicKey)
	for name, line := range map[string]string{
		"rsa 2048": strings.TrimSpace(string(ssh.MarshalAuthorizedKey(rpub))),
		"options":  `command="/bin/sh" ` + entryKeyLine(t, "x"),
		"nonsense": "hello",
	} {
		if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line}); code != http.StatusUnprocessableEntity {
			t.Fatalf("%s: HTTP %d %s, want 422", name, code, raw)
		}
	}
}

type lockedWriter struct {
	w  *bytes.Buffer
	mu *sync.Mutex
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

var logDefault = log.Writer()

// Address names: the rule, the reserved words, one person per name, and a
// retired name kept 7 days.
func TestEntryNames(t *testing.T) {
	h := entryHarness(t)
	put := func(p, name string) (int, string) {
		return entryCall(t, h, http.MethodPut, control.EntryNamePath, asSession(p), map[string]any{"name": name})
	}
	for _, bad := range []string{"ab", "-alice", "alice-", "Alice!", "a_b", "abcdefghijklmnopqrstu", "ssh", "admin", "fleet", "root"} {
		if code, raw := put(pAlice, bad); code != http.StatusUnprocessableEntity {
			t.Fatalf("name %q: HTTP %d %s, want 422", bad, code, raw)
		}
	}
	if code, raw := put(pAlice, "alice"); code != 200 {
		t.Fatalf("alice: HTTP %d %s", code, raw)
	}
	if code, raw := put(pBob, "alice"); code != http.StatusConflict {
		t.Fatalf("Bob takes alice: HTTP %d %s, want 409", code, raw)
	}
	if code, raw := put(pAlice, "alice2"); code != 200 {
		t.Fatalf("rename: HTTP %d %s", code, raw)
	}
	if code, raw := put(pBob, "alice"); code != http.StatusConflict {
		t.Fatalf("Bob takes a name retired today: HTTP %d %s, want 409", code, raw)
	}
	names, _ := h.srv.Store.EntryNames(time.Now())
	if len(names) != 2 {
		t.Fatalf("names answering now: %+v, want alice (retired) and alice2", names)
	}
	// Eight days on, the old name is free.
	if _, err := h.srv.Store.SetEntryName(pBob, "alice", time.Now().Add(8*24*time.Hour)); err != nil {
		t.Fatalf("Bob takes alice after 8 days: %v", err)
	}
	// The operator picks no one's name.
	if code, raw := entryCall(t, h, http.MethodPut, control.EntryNamePath+"?principal="+pAlice, asOperator, map[string]any{"name": "zzz"}); code != http.StatusForbidden {
		t.Fatalf("operator names Alice: HTTP %d %s, want 403", code, raw)
	}
	// A first visit suggests a name from the sign-in.
	if got := entrySuggestName("Verky.Yi_99"); got != "verky-yi-99" {
		t.Fatalf("suggest: %q", got)
	}
}

// The door's record: a machine sends its backlog, sending it twice records
// it once, and an accepted entry stamps the key's last use.
func TestEntryAuditBackfill(t *testing.T) {
	h := entryHarness(t)
	_, tok5 := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	if code, raw := entryCall(t, h, http.MethodPut, control.EntryHomePath, asSession(pAlice), map[string]any{"machine": "macmini"}); code != 200 {
		t.Fatalf("home: HTTP %d %s", code, raw)
	}
	code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": entryKeyLine(t, "x")})
	var k store.EntryKey
	_ = json.Unmarshal([]byte(raw), &k)
	if code != http.StatusCreated {
		t.Fatalf("add: HTTP %d %s", code, raw)
	}
	at := time.Now().Add(-time.Hour).UTC().Truncate(time.Second)
	body := map[string]any{"lines": []map[string]any{
		{"id": "e1", "at": at, "person": pAlice, "login": "alice", "fp": k.FP, "source_ip": "198.51.100.7", "result": "ok"},
		{"id": "e2", "at": at, "login": "alice", "source_ip": "198.51.100.8", "result": "refused: no such key"},
	}}
	for i, want := range []string{`"stored":2`, `"stored":0`} {
		if code, raw := entryCall(t, h, http.MethodPost, control.EntryAuditNodePath, asNode(tok5), body); code != 200 || !strings.Contains(raw, want) {
			t.Fatalf("send %d: HTTP %d %s, want %s", i+1, code, raw, want)
		}
	}
	keys, _ := h.srv.Store.EntryKeys(pAlice, false)
	if len(keys) != 1 || keys[0].LastUsed == nil || !keys[0].LastUsed.Equal(at) {
		t.Fatalf("last used: %+v, want %v", keys, at)
	}
	all, _ := h.srv.Store.EntryAudits("", 50)
	n := 0
	for _, a := range all {
		if a.Actor == "node" {
			n++
			if a.Machine != "macmini" {
				t.Fatalf("a node line's machine is %q, want the token's own", a.Machine)
			}
		}
	}
	if n != 2 {
		t.Fatalf("node lines: %d, want 2", n)
	}
}

// Off (the default): every door is 404, the version never moves, and no
// machine is ever sent entry_keys.
func TestEntryOffAddsNothing(t *testing.T) {
	h, _ := certHarness(t)
	loginReportsFleet(t, h, "macmini", "alice", "00000000-0000-4000-8000-000000000005")
	m5, tok5 := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	for _, c := range []struct {
		method, path string
		body         any
	}{
		{http.MethodGet, control.EntryKeysPath, nil},
		{http.MethodPost, control.EntryKeysPath, map[string]any{"public_key": entryKeyLine(t, "x")}},
		{http.MethodPut, control.EntryNamePath, map[string]any{"name": "alice"}},
		{http.MethodPut, control.EntryHomePath, map[string]any{"machine": "macmini"}},
	} {
		if code, raw := entryCall(t, h, c.method, c.path, asSession(pAlice), c.body); code != http.StatusNotFound {
			t.Fatalf("off: %s %s: HTTP %d %s, want 404", c.method, c.path, code, raw)
		}
	}
	if code, _, raw := nodeList(t, h, tok5); code != http.StatusNotFound {
		t.Fatalf("off: the node's list: HTTP %d %s, want 404", code, raw)
	}
	if v, _ := h.srv.Store.EntryVersion(); v != 0 {
		t.Fatalf("off: version %d", v)
	}
	// Even a version written behind the doors' back is never pushed.
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini", Login: "alice", SetBy: "t", SetAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	h.srv.broadcastEntry(1, "macmini")
	beat(t, m5, control.Proto, control.Heartbeat{Hostname: "macmini", OSUser: "root"})
	silent(t, m5, "off")
}
