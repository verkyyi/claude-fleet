package api

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The revocation list (claude-fleet#3560, EPIC #3500 C18): every revocation
// the hub records also lands on a versioned list the relay and the doors
// follow, so they refuse by themselves — at once, and with the hub away.

// revGet asks a list route with bearer tok; since < 0 sends none.
func revGet(t *testing.T, h *harness, path, tok string, since int64, wait int) (int, RevocationList) {
	t.Helper()
	q := ""
	if since >= 0 {
		q = "?since=" + strconv.FormatInt(since, 10)
		if wait > 0 {
			q += "&wait=" + strconv.Itoa(wait)
		}
	}
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path+q, nil)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out RevocationList
	b, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(b, &out)
	return res.StatusCode, out
}

func revHas(l RevocationList, jti string) bool {
	for _, e := range l.Entries {
		if e.JTI == jti {
			return true
		}
	}
	return false
}

const revTok = "rev-list-token"

// rawCheck is the relay check's whole answer: status, who and body.
func rawCheck(t *testing.T, h *harness, pass string) string {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+RelayCheckPath, nil)
	req.Header.Set(RelayHeader, pass)
	req.Header.Set("X-Forwarded-Uri", "/anthropic/v1/messages")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return strconv.Itoa(res.StatusCode) + " " + res.Header.Get("X-Fleet-Relay-Who") + " " + string(b)
}

// Off (no token): every list route is 404, a revocation writes no entry,
// and the relay check answers byte for byte as with the list on.
func TestRevocationsOffAddsNothing(t *testing.T) {
	answers := func(on bool) []string {
		h, m4, _ := newVaultHarness(t)
		if on {
			h.srv.RevocationsToken = revTok
		}
		tok := mustMintRelay(t, h, m4)
		live := rawCheck(t, h, tok)
		putSetting(t, h, NodeRelayPrefix+"m4", "", 200)
		dead := rawCheck(t, h, tok)
		forged := rawCheck(t, h, relayTokenPrefix+"forged")
		if !on {
			for _, p := range []string{RelayRevocationsPath, NodeRevocationsPath} {
				if code, _ := revGet(t, h, p, m4, -1, 0); code != http.StatusNotFound {
					t.Fatalf("off: %s = %d, want 404", p, code)
				}
			}
			if code := h.getCode(t, "/v1/fleet/revocations"); code != http.StatusNotFound {
				t.Fatalf("off: /v1/fleet/revocations = %d, want 404", code)
			}
			if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4", Reason: "lost"}); code != 200 {
				t.Fatalf("revoke: %d %v", code, out)
			}
			var n int
			_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_revocations`).Scan(&n)
			if v, _ := h.srv.Store.RevocationsVersion(); n != 0 || v != 0 {
				t.Fatalf("off: %d entries, version %d — the list wrote", n, v)
			}
		}
		return []string{live, dead, forged}
	}
	off, on := answers(false), answers(true)
	for i := range off {
		if off[i] != on[i] {
			t.Fatalf("relay check answer %d differs with the list on:\noff %s\non  %s", i, off[i], on[i])
		}
	}
}

func TestRevocationsRelayCred(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	h.srv.RevocationsToken = revTok
	if code, _ := revGet(t, h, RelayRevocationsPath, "", -1, 0); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d, want 401", code)
	}
	if code, _ := revGet(t, h, RelayRevocationsPath, "wrong", -1, 0); code != http.StatusUnauthorized {
		t.Fatalf("wrong token: %d, want 401", code)
	}
	code, l := revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	if code != 200 || l.V != 0 || len(l.Entries) != 0 {
		t.Fatalf("empty list: %d %+v", code, l)
	}
	tok := mustMintRelay(t, h, m4)
	putSetting(t, h, NodeRelayPrefix+"m4", "", 200)
	code, l = revGet(t, h, RelayRevocationsPath, revTok, 0, 0)
	if code != 200 || l.V != 1 || !revHas(l, "frl1:"+HashToken(tok)) {
		t.Fatalf("after the relay revoke: %d %+v", code, l)
	}
	for _, e := range l.Entries {
		if e.Src != "" || e.Reason != "" {
			t.Fatalf("the relay's list carries the operator's words: %+v", e)
		}
	}
	// The machine's door reads the same list with its node token.
	if code, nl := revGet(t, h, NodeRevocationsPath, m4, -1, 0); code != 200 || nl.V != 1 {
		t.Fatalf("node list: %d %+v", code, nl)
	}
	// At the version it holds and no wait: 304 at once.
	if code, _ := revGet(t, h, RelayRevocationsPath, revTok, 1, 0); code != http.StatusNotModified {
		t.Fatalf("since=v: %d, want 304", code)
	}
	// Held, and nothing moves: 304 at the deadline.
	t0 := time.Now()
	if code, _ := revGet(t, h, RelayRevocationsPath, revTok, 1, 1); code != http.StatusNotModified || time.Since(t0) < 900*time.Millisecond {
		t.Fatalf("held: %d after %s", code, time.Since(t0))
	}
}

// A held request answers the moment a revocation lands — the 10-second
// promise rides this, not a poll.
func TestRevocationsLongPollWakes(t *testing.T) {
	h, tok5, _, f5, _ := sessHarness(t)
	h.srv.RevocationsToken = revTok
	out := sessIssue(t, h, tok5, f5, map[string]any{"providers": []string{"claude"}})
	id := out["id"].(string)
	type res struct {
		code int
		l    RevocationList
		d    time.Duration
	}
	ch := make(chan res, 1)
	t0 := time.Now()
	go func() {
		code, l := revGet(t, h, RelayRevocationsPath, revTok, 0, 20)
		ch <- res{code, l, time.Since(t0)}
	}()
	time.Sleep(300 * time.Millisecond)
	if st, _ := sessDo(t, h, http.MethodDelete, "/v1/fleet/session-cred/"+id, tok5, "", nil); st != 200 {
		t.Fatalf("revoke: %d", st)
	}
	select {
	case r := <-ch:
		if r.code != 200 || !revHas(r.l, "fcp:"+id) || r.d > 5*time.Second {
			t.Fatalf("woke with %d after %s: %+v", r.code, r.d, r.l)
		}
		for _, e := range r.l.Entries {
			if e.JTI == "fcp:"+id && (e.Principal != "gh:1005" || e.Machine != "m5" || e.Exp <= time.Now().Unix()) {
				t.Fatalf("pass entry: %+v", e)
			}
		}
	case <-time.After(10 * time.Second):
		t.Fatal("a held list request did not wake on a revocation")
	}
}

// A credential revocation lands as its scope (plus a machine-wide one's relay
// hashes, a person's live certificates); lifting it lifts exactly those.
func TestRevocationsCredRevokeAndLift(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	h.srv.RevocationsToken = revTok
	tok := mustMintRelay(t, h, m4)
	now := time.Now()
	if err := h.srv.Store.RecordCert(store.FleetCert{Serial: "4242", PrincipalID: "gh:7", KeyID: "person:gh:7",
		Principals: []string{"alice"}, KeyFingerprint: "SHA256:x", Via: "device", IssuedAt: now,
		ValidAfter: now, ValidBefore: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4.local", Reason: "lost"}); code != 200 {
		t.Fatalf("revoke m4: %d %v", code, out)
	}
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{PrincipalID: "gh:7"}); code != 200 {
		t.Fatalf("revoke gh:7: %d %v", code, out)
	}
	_, l := revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	scope := false
	for _, e := range l.Entries {
		if e.JTI == "" && e.Machine == "m4" && e.Principal == "" && e.Before > 0 {
			scope = true
		}
	}
	if !scope || !revHas(l, "frl1:"+HashToken(tok)) || !revHas(l, "ssh:4242") {
		t.Fatalf("after the revocations: %+v", l)
	}
	v := l.V
	if code, out := h.post(t, "/v1/fleet/credentials/revoke", FleetRevokeRequest{Hostname: "m4.local", Lift: true}); code != 200 {
		t.Fatalf("lift: %d %v", code, out)
	}
	_, l = revGet(t, h, RelayRevocationsPath, revTok, -1, 0)
	if l.V <= v || revHas(l, "frl1:"+HashToken(tok)) || !revHas(l, "ssh:4242") {
		t.Fatalf("after the lift: %+v", l)
	}
	for _, e := range l.Entries {
		if e.Machine == "m4" && e.JTI == "" {
			t.Fatalf("the lifted scope is still listed: %+v", e)
		}
	}
}

// One connection certificate, by serial: the operator's.
func TestRevocationsCert(t *testing.T) {
	h, m4, _ := newVaultHarness(t)
	h.srv.RevocationsToken = revTok
	now := time.Now()
	for serial, before := range map[string]time.Time{"77": now.Add(time.Hour), "78": now.Add(-time.Minute)} {
		if err := h.srv.Store.RecordCert(store.FleetCert{Serial: serial, PrincipalID: "gh:9", KeyID: "person:gh:9",
			Principals: []string{"bob"}, KeyFingerprint: "SHA256:y", Via: "web", IssuedAt: now.Add(-time.Hour),
			ValidAfter: now.Add(-time.Hour), ValidBefore: before}); err != nil {
			t.Fatal(err)
		}
	}
	if code, _ := h.post(t, "/v1/fleet/revocations", FleetRevocationRequest{Serial: "999"}); code != http.StatusNotFound {
		t.Fatalf("unknown serial: %d", code)
	}
	if code, out := h.post(t, "/v1/fleet/revocations", FleetRevocationRequest{Serial: "77", Reason: "leaked"}); code != 200 || out["v"] != float64(1) {
		t.Fatalf("revoke 77: %d %v", code, out)
	}
	// An expired certificate needs no entry: nothing moves.
	if code, out := h.post(t, "/v1/fleet/revocations", FleetRevocationRequest{Serial: "78"}); code != 200 || out["expired"] != true || out["v"] != float64(1) {
		t.Fatalf("revoke 78: %d %v", code, out)
	}
	_, l := revGet(t, h, NodeRevocationsPath, m4, -1, 0)
	if !revHas(l, "ssh:77") || revHas(l, "ssh:78") {
		t.Fatalf("door's list: %+v", l)
	}
	// The operator's view keeps the reason.
	_, b := h.get(t, "/v1/fleet/revocations")
	var ol RevocationList
	_ = json.Unmarshal(b, &ol)
	if len(ol.Entries) != 1 || ol.Entries[0].Src != "cert:77" || ol.Entries[0].Reason == "" {
		t.Fatalf("operator's list: %s", b)
	}
	if code, _ := h.post(t, "/v1/fleet/revocations", FleetRevocationRequest{Serial: "77", Lift: true}); code != 200 {
		t.Fatalf("lift: %d", code)
	}
	if _, l = revGet(t, h, RelayRevocationsPath, revTok, -1, 0); revHas(l, "ssh:77") || l.V != 2 {
		t.Fatalf("after the lift: %+v", l)
	}
}

// Entries past their exp leave the list on the next write.
func TestRevocationsPrune(t *testing.T) {
	h, _, _ := newVaultHarness(t)
	now := time.Now()
	st := h.srv.Store
	if _, err := st.AddRevocations([]store.Revocation{{JTI: "fcp:old", Exp: now.Add(time.Second).Unix()}}, now); err != nil {
		t.Fatal(err)
	}
	later := now.Add(time.Minute)
	if _, err := st.AddRevocations([]store.Revocation{{JTI: "fcp:new", Exp: later.Add(time.Hour).Unix()}}, later); err != nil {
		t.Fatal(err)
	}
	var n int
	_ = st.DB().QueryRow(`SELECT COUNT(*) FROM fleet_revocations`).Scan(&n)
	v, l, _ := st.RevocationList(later)
	if n != 1 || v != 2 || len(l) != 1 || l[0].JTI != "fcp:new" {
		t.Fatalf("rows=%d v=%d list=%+v", n, v, l)
	}
}
