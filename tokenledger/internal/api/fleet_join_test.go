package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

func mintJoinCode(t *testing.T, h *harness, label string) JoinCodeView {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"label": label})
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/join-codes", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("mint join code: HTTP %d %s", resp.StatusCode, b)
	}
	var v JoinCodeView
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func joinWith(t *testing.T, h *harness, code, host, osUser string) (int, NodeJoinResponse) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"code": code, "hostname": host, "os_user": osUser})
	resp, err := http.Post(h.http.URL+"/v1/node/join", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out NodeJoinResponse
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func getWithToken(t *testing.T, h *harness, path, tok string) (*http.Response, []byte) {
	t.Helper()
	r, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	if tok != "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

// A code redeems exactly once, into a working agent token; the command the
// operator pastes names this hub and that code.
func TestJoinCodeRedeemsOnce(t *testing.T) {
	h := newFleetHarness(t)
	v := mintJoinCode(t, h, "")
	if !joinCodeRE.MatchString(v.Code) {
		t.Fatalf("code %q does not match the documented format", v.Code)
	}
	if d := time.Until(v.ExpiresAt); d < 9*time.Minute || d > JoinCodeTTL {
		t.Fatalf("expires in %s; want ~10 minutes", d)
	}
	if !strings.Contains(v.Command, "--hub "+h.http.URL) || !strings.Contains(v.Command, "--token "+v.Code) ||
		!strings.Contains(v.Command, DefaultJoinScriptURL) {
		t.Fatalf("command %q does not carry the hub, the code and the script", v.Command)
	}

	code, out := joinWith(t, h, v.Code, "spot-1.local", "verkyyi")
	if code != 200 || !strings.HasPrefix(out.Token, "ccq_") || out.EndpointID == "" {
		t.Fatalf("join: HTTP %d %+v", code, out)
	}
	if out.Label != "spot-1-verkyyi" {
		t.Fatalf("label %q; want the reported host + login", out.Label)
	}
	if kind, _ := h.srv.Store.EndpointKind(out.EndpointID); kind != "agent" {
		t.Fatalf("enrolled as kind %q; want agent", kind)
	}
	resp, body := getWithToken(t, h, "/v1/node/self", out.Token)
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"never"`) {
		t.Fatalf("self before connecting: HTTP %d %s", resp.StatusCode, body)
	}

	if code, _ := joinWith(t, h, v.Code, "spot-2", "verkyyi"); code != http.StatusUnauthorized {
		t.Fatalf("second redemption: HTTP %d; want 401", code)
	}
	if code, _ := joinWith(t, h, "fj_aaaaaaaaaaaaaaaaaaaaaaaaaa", "x", "y"); code != http.StatusUnauthorized {
		t.Fatalf("unknown code: HTTP %d; want 401", code)
	}
	if code, _ := joinWith(t, h, "nonsense", "x", "y"); code != http.StatusUnauthorized {
		t.Fatalf("malformed code: HTTP %d; want 401", code)
	}

	// The operator's list shows the redemption but never a code.
	resp, body = getWithToken(t, h, "/v1/fleet/join-codes", viewerToken)
	if resp.StatusCode != 200 || strings.Contains(string(body), v.Code) || !strings.Contains(string(body), out.EndpointID) {
		t.Fatalf("join-codes list: HTTP %d %s", resp.StatusCode, body)
	}
}

// Ten minutes, then nothing — and a code minted with a label names the endpoint.
func TestJoinCodeExpires(t *testing.T) {
	h := newFleetHarness(t)
	t0 := time.Now()
	now := t0
	h.srv.joinClock = func() time.Time { return now }
	late := mintJoinCode(t, h, "")
	onTime := mintJoinCode(t, h, "m6")

	now = t0.Add(JoinCodeTTL + time.Second)
	if code, _ := joinWith(t, h, late.Code, "m5", "verkyyi"); code != http.StatusUnauthorized {
		t.Fatalf("expired code: HTTP %d; want 401", code)
	}
	now = t0.Add(JoinCodeTTL - time.Second)
	code, out := joinWith(t, h, onTime.Code, "m5", "verkyyi")
	if code != 200 || out.Label != "m6" {
		t.Fatalf("code with a label: HTTP %d label %q; want 200 m6", code, out.Label)
	}
}

// Minting is the operator's: no credential → 401, a WeCom person → 403.
func TestJoinCodesOperatorOnly(t *testing.T) {
	h := newFleetHarness(t)
	enableSSO(h)
	resp, err := http.Post(h.http.URL+"/v1/fleet/join-codes", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous mint: HTTP %d; want 401", resp.StatusCode)
	}
	if code, _ := asPerson(t, h, http.MethodPost, "/v1/fleet/join-codes", "Alice", []byte("{}")); code != http.StatusForbidden {
		t.Fatalf("person mint: HTTP %d; want 403", code)
	}
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/join-codes", strings.NewReader(`{"label":"bad label!"}`))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err = http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad label: HTTP %d; want 400", resp.StatusCode)
	}
}

// The admin flag in the answer is the hub's list, not the machine's claim.
func TestJoinReportsAdminFromHubList(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	if _, out := joinWith(t, h, mintJoinCode(t, h, "").Code, "m6", "verkyyi"); !out.Admin {
		t.Fatalf("operator login joined without admin: %+v", out)
	}
	if _, out := joinWith(t, h, mintJoinCode(t, h, "").Code, "m6", "alice"); out.Admin {
		t.Fatalf("non-admin login reported as admin: %+v", out)
	}
}

// The hub serves the agent binary to an enrolled machine only, with a hash.
func TestNodeDistServesBinaryToEnrolledNode(t *testing.T) {
	h := newFleetHarness(t)
	dir := t.TempDir()
	bin := []byte("#!/bin/sh\necho fake ccquota\n")
	if err := os.WriteFile(filepath.Join(dir, "ccquota-linux-amd64"), bin, 0o755); err != nil {
		t.Fatal(err)
	}
	h.srv.FleetDistDir = dir
	_, out := joinWith(t, h, mintJoinCode(t, h, "").Code, "m6", "verkyyi")
	if len(out.Dist) != 1 || out.Dist[0] != "linux-amd64" {
		t.Fatalf("dist %v; want [linux-amd64]", out.Dist)
	}
	if resp, _ := getWithToken(t, h, "/v1/node/dist/linux-amd64", ""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous download: HTTP %d; want 401", resp.StatusCode)
	}
	resp, body := getWithToken(t, h, "/v1/node/dist/linux-amd64", out.Token)
	sum := sha256.Sum256(bin)
	if resp.StatusCode != 200 || !bytes.Equal(body, bin) || resp.Header.Get("X-Ccquota-Sha256") != hex.EncodeToString(sum[:]) {
		t.Fatalf("download: HTTP %d sha %q body %q", resp.StatusCode, resp.Header.Get("X-Ccquota-Sha256"), body)
	}
	for _, p := range []string{"/v1/node/dist/darwin-arm64", "/v1/node/dist/linux-amd64x", "/v1/node/dist/windows-amd64"} {
		if resp, _ := getWithToken(t, h, p, out.Token); resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s: HTTP %d; want 404", p, resp.StatusCode)
		}
	}
}

// Once the joined agent says hello and beats, /v1/node/self reads online —
// the signal the join script waits for.
func TestNodeSelfOnlineAfterConnect(t *testing.T) {
	h := newFleetHarness(t)
	_, out := joinWith(t, h, mintJoinCode(t, h, "").Code, "m6", "verkyyi")
	c := dialNode(t, h, out.Token)
	hello(t, c, control.Proto, 1000)
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m6", OSUser: "verkyyi"})
	waitFor(t, 3*time.Second, "self online", func() bool {
		_, body := getWithToken(t, h, "/v1/node/self", out.Token)
		var v NodeView
		return json.Unmarshal(body, &v) == nil && v.Status == "online" && v.EndpointID == out.EndpointID
	})
}

func TestJoinRoutesOffWithoutFleet(t *testing.T) {
	h := newHarness(t)
	for _, p := range []string{"/v1/node/join", "/v1/node/self", "/v1/node/dist/linux-amd64"} {
		resp, _ := getWithToken(t, h, p, "")
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s with the fleet module off: HTTP %d", p, resp.StatusCode)
		}
	}
	resp, err := http.Post(h.http.URL+"/v1/node/join", "application/json", strings.NewReader(`{"code":"fj_aaaaaaaaaaaaaaaaaaaaaaaaaa"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		t.Fatal("join answered 200 with the fleet module off")
	}
}

// The joined operator login's FIRST connection is already the admin agent: the
// join recorded its login on the endpoint, so the admin gate does not wait for
// a usage report (and the SSH CA is not held back until some reconnect).
func TestJoinedAgentIsAdminOnFirstConnect(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"verkyyi"}
	_, out := joinWith(t, h, mintJoinCode(t, h, "").Code, "m6", "verkyyi")
	n := dialAdmin(t, h, out.Token, true)
	beat(t, n.c, control.Proto, control.Heartbeat{Hostname: "m6", OSUser: "verkyyi"})
	waitFor(t, 3*time.Second, "joined node is admin", func() bool {
		for _, v := range roster(t, h).Nodes {
			if v.EndpointID == out.EndpointID {
				return v.Admin
			}
		}
		return false
	})
}
