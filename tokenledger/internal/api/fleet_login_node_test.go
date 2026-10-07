package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// 登录即登记 (claude-fleet#2212).

// loginNode is `fleet-login.py node-pass`: the device key signs a timestamp
// and asks for its node pass.
func (d *device) loginNode(t *testing.T, h *harness, host, osUser string) (int, map[string]any) {
	t.Helper()
	ts := time.Now().Unix()
	code, body := postJSON(t, h, control.LoginNodePath, map[string]any{"public_key": d.pub, "ts": ts,
		"hostname": host, "os_user": osUser,
		"sig": sshsig(t, d.signer, control.LoginNodeSigNamespace, []byte(control.LoginNodeSigMessage(ts)))})
	var out map[string]any
	_ = json.Unmarshal(body, &out)
	return code, out
}

func loginNodeSelf(t *testing.T, h *harness, tok string) (int, map[string]any) {
	t.Helper()
	resp, b := getWithToken(t, h, "/v1/node/self", tok)
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return resp.StatusCode, out
}

// One scan (`fleet login`) is all a computer needs to be a node: the device
// signature buys the pass, the node is untrusted, the same device is never
// enrolled twice, and a retired node is enrolled anew.
func TestLoginNodeEnrollsOnceUntrusted(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)

	if code, out := a.loginNode(t, h, "mbp", "alice"); code != 404 || out["code"] != "unknown_device" {
		t.Fatalf("before any login: %d %v; want 404 unknown_device", code, out)
	}
	a.scan(t, h, pAlice, "mbp")

	code, out := a.loginNode(t, h, "mbp", "alice")
	if code != 200 {
		t.Fatalf("node pass: %d %v", code, out)
	}
	tok, ep := out["token"].(string), out["endpoint_id"].(string)
	if tok == "" || ep == "" || out["label"] != "mbp-alice" || out["kind"] != store.NodeKindFixed {
		t.Fatalf("node pass = %v", out)
	}
	if c, self := loginNodeSelf(t, h, tok); c != 200 || self["endpoint_id"] != ep || self["trust"] != TrustUntrusted {
		t.Fatalf("/v1/node/self with the pass: %d %v; want untrusted", c, self)
	}

	// Again (node.env lost): the SAME endpoint, a fresh token, the old one dead.
	code, out = a.loginNode(t, h, "mbp", "alice")
	if code != 200 || out["endpoint_id"] != ep || out["token"] == tok {
		t.Fatalf("second ask: %d %v; want endpoint %s with a new token", code, out, ep)
	}
	tok2 := out["token"].(string)
	if c, _ := loginNodeSelf(t, h, tok); c != 401 {
		t.Fatalf("the replaced token still works: %d", c)
	}
	if c, _ := loginNodeSelf(t, h, tok2); c != 200 {
		t.Fatalf("the reissued token: %d", c)
	}
	codes, _ := h.srv.Store.JoinCodes(20)
	if len(codes) != 1 {
		t.Fatalf("join codes = %d, want one enrollment for one device", len(codes))
	}

	// Audited, on both books.
	audits, _ := h.srv.Store.DeviceAuditLog(pAlice, 200)
	n := 0
	for _, r := range audits {
		if r.Action == store.DeviceNodePass && r.Fingerprint == a.fp && strings.Contains(r.Detail, "随登录登记") {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("node_pass device audits = %d, want 2: %+v", n, audits)
	}

	// A signature under another namespace (a renewal's) buys nothing.
	ts := time.Now().Unix()
	if c, _ := postJSON(t, h, control.LoginNodePath, map[string]any{"public_key": a.pub, "ts": ts, "hostname": "mbp",
		"sig": sshsig(t, a.signer, control.RenewSigNamespace, []byte(control.RenewSigMessage(ts)))}); c != 401 {
		t.Fatalf("renewal signature: %d, want 401", c)
	}

	// Retired (fleet node leave / the /nodes card): the next ask enrolls anew.
	if _, err := h.srv.Store.RetireEndpointAs(ep, "test", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	code, out = a.loginNode(t, h, "mbp", "alice")
	if code != 200 || out["endpoint_id"] == ep {
		t.Fatalf("after retire: %d %v; want a new endpoint", code, out)
	}
}

// The node side cannot make itself trusted: its token cannot write the trust
// setting, and a login cannot enroll under a name the hub already trusts.
func TestLoginNodeCannotSelfTrust(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)
	a.scan(t, h, pAlice, "mbp")
	code, out := a.loginNode(t, h, "mbp", "alice")
	if code != 200 {
		t.Fatalf("node pass: %d %v", code, out)
	}
	tok := out["token"].(string)

	body, _ := json.Marshal(map[string]string{"key": NodeTrustPrefix + "mbp", "value": TrustTrusted})
	req, _ := http.NewRequest(http.MethodPut, h.http.URL+"/v1/fleet/settings", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode == http.StatusOK {
		t.Fatal("a login-registered node's token set trust")
	}
	if _, self := loginNodeSelf(t, h, tok); self["trust"] != TrustUntrusted {
		t.Fatalf("trust = %v, want untrusted", self["trust"])
	}

	// The operator trusts a machine named m9; a new device reporting that
	// name is refused rather than inheriting it.
	putSetting(t, h, NodeTrustPrefix+"m9", TrustTrusted, 200)
	b := newDevice(t)
	b.scan(t, h, pAlice, "m9")
	if code, out := b.loginNode(t, h, "m9", "alice"); code != 409 || out["code"] != "trusted_name" {
		t.Fatalf("enrolling under a trusted name: %d %v; want 409 trusted_name", code, out)
	}

	// Only the operator's /nodes road sets it.
	putSetting(t, h, NodeTrustPrefix+"mbp", TrustTrusted, 200)
	if _, self := loginNodeSelf(t, h, tok); self["trust"] != TrustTrusted {
		t.Fatalf("after the operator: trust = %v", self["trust"])
	}
	// …and the device keeps its node (reissue, not a new enrollment).
	if code, out := a.loginNode(t, h, "mbp", "alice"); code != 200 {
		t.Fatalf("reissue for a now-trusted node: %d %v", code, out)
	}
}

// A revoked device gets no pass.
func TestLoginNodeRevokedDevice(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)
	a.scan(t, h, pAlice, "mbp")
	body, _ := json.Marshal(map[string]string{"fingerprint": a.fp})
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if code, out := a.loginNode(t, h, "mbp", "alice"); code != 403 || out["code"] != "device_revoked" {
		t.Fatalf("revoked device: %d %v; want 403 device_revoked", code, out)
	}
}
