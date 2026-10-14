package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// The admin role account's token (claude-fleet#3724, BREAK-IT
// fleetadmin-token-misissued): only the machine asks, only for the admin
// role's name the hub counts as an admin, only on the asker's own machine;
// one audit line each; a second ask reissues the same endpoint.

func adminTokenCall(t *testing.T, h *harness, token, method string, body any) (int, AdminTokenResponse, string) {
	t.Helper()
	var rd *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+AdminTokenNodePath, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	_, _ = raw.ReadFrom(resp.Body)
	var out AdminTokenResponse
	if resp.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw.Bytes(), &out); err != nil {
			t.Fatalf("decode %s: %v", raw.String(), err)
		}
	}
	return resp.StatusCode, out, raw.String()
}

func adminTokenAudits(t *testing.T, h *harness) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'admin_token'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestNodeAdminToken(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.FleetAdmins = []string{"frank", "_fleetadmin"}
	mach := enrollAs(t, h, "mac-a-root", "mac-a", "root")
	frank := enrollAs(t, h, "mac-a-frank", "mac-a", "frank")
	other := enrollAs(t, h, "mac-b-root", "mac-b", "root")

	// the refusals, each before anything is minted
	if st, _, _ := adminTokenCall(t, h, mach, http.MethodGet, nil); st != http.StatusMethodNotAllowed {
		t.Fatalf("GET = %d; want 405", st)
	}
	if st, _, _ := adminTokenCall(t, h, "", http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != http.StatusUnauthorized {
		t.Fatalf("no token = %d; want 401", st)
	}
	if st, _, body := adminTokenCall(t, h, frank, http.MethodPost, map[string]string{"login": "_fleetadmin"}); st != http.StatusForbidden {
		t.Fatalf("a login's own token = %d %s; want 403", st, body)
	}
	if st, _, body := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "frank"}); st != http.StatusForbidden {
		t.Fatalf("a person's login = %d %s; want 403", st, body)
	}
	if st, _, body := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "fleetadmin"}); st != http.StatusForbidden {
		t.Fatalf("the role name the hub does not count as admin = %d %s; want 403", st, body)
	}
	if n := adminTokenAudits(t, h); n != 0 {
		t.Fatalf("refusals wrote %d audit lines", n)
	}

	// the machine's ask: a new endpoint of _fleetadmin pinned to mac-a
	st, out, body := adminTokenCall(t, h, mach, http.MethodPost, map[string]any{"login": "_fleetadmin", "machine": "mac-b"})
	if st != http.StatusOK || out.Outcome != "issued" || out.Login != "_fleetadmin" || out.Machine != "mac-a" || out.Token == "" {
		t.Fatalf("issue = %d %s", st, body)
	}
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(out.Token))
	if err != nil || ep.ID != out.EndpointID || ep.OSUser != "_fleetadmin" || h.srv.endpointHost(*ep) != "mac-a" {
		t.Fatalf("token resolves to %+v %v", ep, err)
	}
	// the machine link takes it as that login's hello — on mac-a, never mac-b
	machEP, err := h.srv.Store.EndpointByTokenHash(HashToken(mach))
	if err != nil {
		t.Fatal(err)
	}
	if got, _, why := h.srv.loginEndpoint(*machEP, "_fleetadmin", control.Hello{LoginToken: out.Token}); got == nil || got.ID != out.EndpointID {
		t.Fatalf("mac-a's link refuses the seat's token: %s", why)
	}
	otherEP, err := h.srv.Store.EndpointByTokenHash(HashToken(other))
	if err != nil {
		t.Fatal(err)
	}
	if got, _, _ := h.srv.loginEndpoint(*otherEP, "_fleetadmin", control.Hello{LoginToken: out.Token}); got != nil {
		t.Fatalf("mac-b's link took mac-a's admin token")
	}
	if n := adminTokenAudits(t, h); n != 1 {
		t.Fatalf("issue wrote %d audit lines; want 1", n)
	}

	// asked again: the same endpoint, a new token
	st, again, body := adminTokenCall(t, h, mach, http.MethodPost, map[string]string{"login": "_fleetadmin"})
	if st != http.StatusOK || again.Outcome != "reissued" || again.EndpointID != out.EndpointID || again.Token == out.Token {
		t.Fatalf("reissue = %d %s", st, body)
	}
	if ep, err := h.srv.Store.EndpointByTokenHash(HashToken(again.Token)); err != nil || ep.ID != out.EndpointID {
		t.Fatalf("the reissued token resolves to %+v %v", ep, err)
	}
	if n := adminTokenAudits(t, h); n != 2 {
		t.Fatalf("reissue: %d audit lines; want 2", n)
	}
}
