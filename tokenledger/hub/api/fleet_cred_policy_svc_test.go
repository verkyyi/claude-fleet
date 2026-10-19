package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/credvault"
)

// A service principal under the subscription allowlists (claude-fleet#4085):
// an administrator lists the subscriptions svc:<name> may use; with no list
// it may use none, in every mode; no machine list applies to it.

func svcPolicyRig(t *testing.T, mode string) *harness {
	t.Helper()
	h, _, _ := policyRig(t)
	if mode != "" {
		if err := h.srv.Store.SetFleetSetting(CredPolicyModeKey, mode, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.srv.Store.CreateSvcPrincipal("livepage", []string{"svc.run"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	return h
}

func svcChoices(t *testing.T, h *harness) []string {
	t.Helper()
	// a service pass carries no endpoint: "" is what passEndpoint answers
	rows, err := h.srv.sessionBindChoices("svc:livepage", "", credvault.Claude)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, c := range rows {
		out = append(out, c.Account)
	}
	return out
}

func TestCredPolicySvcSetLeaseRefuse(t *testing.T) {
	for _, mode := range []string{"strict", "legacy"} {
		t.Run(mode, func(t *testing.T) {
			h := svcPolicyRig(t, mode)
			// strict mode with a machine list in force: the service is still
			// judged by its own list alone
			setPolicy(t, h, "node", "mac-c", []string{uuidGmail})

			// no list ⇒ none, in either mode, and the reason says so
			if got := svcChoices(t, h); len(got) != 0 {
				t.Fatalf("unlisted service leased %v", got)
			}
			if why := h.srv.noBindWhy("svc:livepage", "", credvault.Claude); !strings.Contains(why, "service svc:livepage has no allowlist") {
				t.Fatalf("refusal reason: %q", why)
			}

			// an unknown service is refused at the write
			code, out := h.post(t, CredPolicyPath, map[string]any{"scope": "user", "id": "svc:nosuch", "allow": []string{uuidGmail}})
			if code != http.StatusBadRequest || !strings.Contains(strings.ToLower(jsonString(out)), "unknown principal svc:nosuch") {
				t.Fatalf("unknown service: %d %v", code, out)
			}

			// listed: exactly its list, whatever the machine list says
			setPolicy(t, h, "user", "svc:livepage", []string{uuidICloud})
			if got := svcChoices(t, h); !eq(got, "icloud") {
				t.Fatalf("listed icloud, leased %v", got)
			}
			if why := h.srv.noBindWhy("svc:livepage", "", credvault.Claude); !strings.Contains(why, "not in service svc:livepage's allowlist") {
				t.Fatalf("narrowed reason: %q", why)
			}
			// all: the whole pool (a person's own subscription is never its)
			if code, out := h.post(t, CredPolicyPath, map[string]any{"scope": "user", "id": "svc:livepage", "all": true}); code != 200 {
				t.Fatalf("grant all: %d %v", code, out)
			}
			if got := svcChoices(t, h); !eq(got, "gmail", "icloud", "legacy") {
				t.Fatalf("all: %v", got)
			}
			// cleared ⇒ none again
			setPolicy(t, h, "user", "svc:livepage", nil)
			if got := svcChoices(t, h); len(got) != 0 {
				t.Fatalf("cleared service leased %v", got)
			}

			// the admin view lists the service, and its list once written
			setPolicy(t, h, "user", "svc:livepage", []string{uuidGmail})
			var view struct {
				Services []struct {
					ID      string `json:"id"`
					Enabled bool   `json:"enabled"`
				} `json:"services"`
				Users []struct {
					ID    string   `json:"id"`
					Allow []string `json:"allow"`
				} `json:"users"`
			}
			h.getJSON(t, CredPolicyPath, &view)
			if len(view.Services) != 1 || view.Services[0].ID != "svc:livepage" || !view.Services[0].Enabled {
				t.Fatalf("services: %+v", view.Services)
			}
			found := false
			for _, u := range view.Users {
				found = found || (u.ID == "svc:livepage" && eq(u.Allow, uuidGmail))
			}
			if !found {
				t.Fatalf("users: %+v", view.Users)
			}
		})
	}
}

// A person, not an administrator, cannot write a service's list.
func TestCredPolicySvcAdminOnly(t *testing.T) {
	h, admin, user := rolesHarness(t)
	if _, err := h.srv.Store.CreateSvcPrincipal("livepage", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	put := func(c *http.Cookie) int {
		b, _ := json.Marshal(map[string]any{"scope": "user", "id": "svc:livepage", "all": true})
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		req, _ := http.NewRequestWithContext(ctx, http.MethodPut, h.http.URL+CredPolicyPath, bytes.NewReader(b))
		req.Header.Set("Accept", "application/json")
		req.Header.Set("Content-Type", "application/json")
		req.AddCookie(c)
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if code := put(user); code != http.StatusForbidden {
		t.Fatalf("a person wrote a service's list: %d", code)
	}
	set, _ := h.srv.Store.FleetSettings()
	if _, ok := set[credUserKey("svc:livepage")]; ok {
		t.Fatal("the refused write was stored")
	}
	if code := put(admin); code != http.StatusOK {
		t.Fatalf("admin: %d", code)
	}
	set, _ = h.srv.Store.FleetSettings()
	if set[credUserKey("svc:livepage")] != `"*"` {
		t.Fatalf("admin's write: %q", set[credUserKey("svc:livepage")])
	}
}

func jsonString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
