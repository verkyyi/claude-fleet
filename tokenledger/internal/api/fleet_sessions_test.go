package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// The sidebar's session list by connection certificate (claude-fleet#1475).

func postSessions(t *testing.T, h *harness, auth func(http.Header), body any) (int, map[string]any, string) {
	t.Helper()
	var rd *bytes.Reader
	method := http.MethodGet
	if body != nil {
		b, _ := json.Marshal(body)
		rd, method = bytes.NewReader(b), http.MethodPost
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.SessionsPath, rd)
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String()
}

func nodeRows(out map[string]any) map[string]map[string]any {
	rows := map[string]map[string]any{}
	ns, _ := out["nodes"].([]any)
	for _, n := range ns {
		m := n.(map[string]any)
		rows[m["machine_name"].(string)] = m
	}
	return rows
}

// A connection certificate, proven by signing a fresh timestamp, reads its
// holder's own sessions and machines and nothing else — no token involved;
// the operator's token still reads everyone's; a bad proof is refused. The
// answer carries one node per visible machine, for the sidebar's status line.
func TestFleetSessionsByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	a := connectFakeNode(t, h, "m5", false)
	b := connectFakeNode(t, h, "m4", false)
	fa := fakeFleet(t, machineA, "alice-fleet", "", "", 1, 2)
	fb := fakeFleet(t, machineB, "bob-fleet", "", "", 7)
	a.beat("m5", "alice", machineA, fa)
	b.beat("m4", "bob", machineB, fb)
	waitFor(t, 3*time.Second, "registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", time.Now())
	h.srv.Store.AdoptAccount(p, "m5", time.Now())

	now := time.Now()
	good := k.cert(t, "wecom:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	signed := func(c *ssh.Certificate, ns string, ts int64) SessionsRequest {
		return SessionsRequest{Cert: string(ssh.MarshalAuthorizedKey(c)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(control.SessionsSigMessage(ts)))}
	}

	code, out, raw := postSessions(t, h, nil, signed(good, control.SessionsSigNamespace, now.Unix()))
	if code != 200 {
		t.Fatalf("a valid certificate: HTTP %d %s", code, raw)
	}
	if out["count"].(float64) != 2 {
		t.Fatalf("alice's sessions = %v, want her two on m5", out["count"])
	}
	if ms := out["machines"].([]any); len(ms) != 1 || ms[0] != "m5" {
		t.Fatalf("alice's machines = %v, want [m5]", ms)
	}
	nodes := nodeRows(out)
	if len(nodes) != 1 || nodes["m5"] == nil || nodes["m5"]["availability"] != "online" || nodes["m5"]["sessions"].(float64) != 2 {
		t.Fatalf("alice's nodes = %v, want m5 online with 2 sessions", out["nodes"])
	}
	if age, ok := nodes["m5"]["age_sec"].(float64); !ok || age < 0 {
		t.Fatalf("node m5: want a non-negative age_sec, got %v", nodes["m5"])
	}

	for name, req := range map[string]SessionsRequest{
		"stale timestamp":  signed(good, control.SessionsSigNamespace, now.Add(-10*time.Minute).Unix()),
		"routes namespace": signed(good, control.RoutesSigNamespace, now.Unix()),
		"expired cert":     signed(k.cert(t, "wx-alice", []string{"alice"}, now.Add(-13*time.Hour), now.Add(-time.Hour)), control.SessionsSigNamespace, now.Unix()),
		"no signature":     {Cert: string(ssh.MarshalAuthorizedKey(good)), TS: now.Unix()},
	} {
		if code, _, raw := postSessions(t, h, nil, req); code != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d %s, want 401", name, code, raw)
		}
	}
	if code, _, _ := postSessions(t, h, nil, nil); code != http.StatusUnauthorized {
		t.Errorf("no credential: HTTP %d, want 401", code)
	}

	// Someone with no account anywhere sees nothing — not someone else's.
	h.srv.Store.AdoptPrincipal("wx-bob", "bob", "Bob", time.Now())
	bob := k.cert(t, "wecom:wx-bob", []string{"bob"}, now.Add(-time.Minute), now.Add(time.Hour))
	if code, out, raw := postSessions(t, h, nil, signed(bob, control.SessionsSigNamespace, now.Unix())); code != 200 || out["count"].(float64) != 0 || len(nodeRows(out)) != 0 {
		t.Errorf("no account: HTTP %d %s, want 200 with nothing in it", code, raw)
	}

	// The operator's door is unchanged: a GET with the viewer token, everything.
	code, out, raw = postSessions(t, h, asOperator, nil)
	if code != 200 || out["count"].(float64) != 3 {
		t.Fatalf("operator: HTTP %d %s, want every session", code, raw)
	}
	nodes = nodeRows(out)
	if len(nodes) != 2 || nodes["m4"]["sessions"].(float64) != 1 || nodes["m5"]["sessions"].(float64) != 2 {
		t.Fatalf("operator's nodes = %v, want m4 (1) and m5 (2)", out["nodes"])
	}

	// A fleet the hub lost is still a node — lost, with its last observation.
	if err := h.srv.Store.NodeHeartbeat("ep_m4", "m4", "bob", machineB, control.Proto, `{"hostname":"m4"}`,
		time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	_, out, _ = postSessions(t, h, asOperator, nil)
	if n := nodeRows(out)["m4"]; n == nil || n["availability"] != "lost" {
		t.Fatalf("m4 after an hour of silence = %v, want lost", out["nodes"])
	}
}

// The shell on a person's own computer (claude-fleet#1484, EPIC #1479 C5) reads
// the list with the certificate `fleet login` REGISTERED on that device — the
// device flow (start / approve / poll), not a CA-minted test certificate — and
// gets exactly its person's rows: the sessions of every login they hold an
// ACTIVE account for, one node per such machine, and nothing of anyone else's
// (a third machine, another login's, is neither a row nor a node) — from both
// sides: that machine's person sees only theirs. A revoked device is refused.
func TestFleetSessionsByDeviceOwnRowsOnly(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	// A third machine, carol's: a login Alice holds no account for.
	const machineC = "33333333-3333-4333-8333-333333333333"
	carol := connectWriteNode(t, h, "m6")
	carol.beatLoad("m6", "carol", machineC, 1, 1,
		fakeFleet(t, machineC, "fleet-carol", writeRepo, "/u/carol/claude-fleet", 9))
	waitFor(t, 3*time.Second, "carol's fleet registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 3
	})

	signed := func(d *device, ts int64) map[string]any {
		return map[string]any{"cert": d.cert, "ts": ts,
			"sig": sshsig(t, d.signer, control.SessionsSigNamespace, []byte(control.SessionsSigMessage(ts)))}
	}
	read := func(d *device) (int, map[string]any, string) {
		code, body := postJSON(t, h, control.SessionsPath, signed(d, time.Now().Unix()))
		var out map[string]any
		_ = json.Unmarshal(body, &out)
		return code, out, string(body)
	}

	a := newDevice(t)
	a.scan(t, h, "Alice", "alices-mbp")
	code, out, raw := read(a)
	if code != 200 {
		t.Fatalf("alice's device: HTTP %d %s", code, raw)
	}
	// verk on m5 (issue 1) + verk on m4 (issue 2): hers; carol's issue 9 is not.
	if out["count"].(float64) != 2 {
		t.Fatalf("alice's device sees %v sessions %s, want her 2 (verk on m5 and m4)", out["count"], raw)
	}
	for _, s := range out["sessions"].([]any) {
		row := s.(map[string]any)
		if row["os_user"] != "verk" {
			t.Fatalf("alice's device sees %v's session: %v", row["os_user"], row)
		}
	}
	nodes := nodeRows(out)
	if len(nodes) != 2 || nodes["m5"] == nil || nodes["m4"] == nil {
		t.Fatalf("alice's nodes = %v, want m5 and m4", out["nodes"])
	}
	if nodes["m6"] != nil {
		t.Fatalf("alice's nodes list carol's machine: %v", out["nodes"])
	}
	// The ETag door works for a device too: the shell's loop sends it back.
	if et, _ := out["etag"].(string); et == "" {
		t.Fatalf("no etag on a device read: %s", raw)
	}

	// Bob, carol's person (a device scan needs an active login somewhere): his
	// device sees carol's one session on m6 and nothing of verk's.
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: "Bob", Hostname: "m6", Login: "carol"}); code != 200 {
		t.Fatalf("adopt bob as carol: HTTP %d", code)
	}
	b := newDevice(t)
	b.scan(t, h, "Bob", "bobs-laptop")
	code, out, raw = read(b)
	if code != 200 || out["count"].(float64) != 1 {
		t.Fatalf("bob's device: HTTP %d %s, want carol's one session", code, raw)
	}
	if row := out["sessions"].([]any)[0].(map[string]any); row["os_user"] != "carol" || row["machine_name"] != "m6" {
		t.Fatalf("bob's device sees %v, want carol on m6", row)
	}
	if nodes := nodeRows(out); len(nodes) != 1 || nodes["m6"] == nil {
		t.Fatalf("bob's nodes = %v, want m6 only", out["nodes"])
	}

	// A revoked device is refused at this door like at every other.
	body, _ := json.Marshal(map[string]string{"fingerprint": b.fp})
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("revoke bob's device: HTTP %d", resp.StatusCode)
	}
	if code, _, raw = read(b); code != http.StatusUnauthorized {
		t.Fatalf("a revoked device: HTTP %d %s, want 401", code, raw)
	}
}
