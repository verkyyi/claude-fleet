package api

import (
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

func TestSvcScopesRewrite(t *testing.T) {
	h, _, tok := svcRunsHarness(t)
	other := svcIssue(t, h, "livepage")
	// Use the same tokens and HTTP server before and after changing the principal.
	for _, key := range []string{tok, other} {
		if st, _ := svcPutTemplate(t, h, key, SvcTemplateRequest{AgentMD: svcTestAgent}); st != 200 {
			t.Fatalf("templates before: %d", st)
		}
	}
	for _, key := range []string{"", tok, other} {
		if st, _ := svcDo(t, h, http.MethodPost, SvcAdminPath, key, SvcAdminRequest{Op: "scopes", Principal: "livepage", Scopes: "runs:read"}); st < 400 {
			t.Fatal("non-admin rewrote scopes")
		}
	}
	if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "scopes", Principal: "livepage", Scopes: "runs:read,runs:write,runs:read"}); st != 200 {
		t.Fatalf("rewrite: %d %v", st, out)
	}
	for i, key := range []string{tok, other} {
		if st, _ := svcPutTemplate(t, h, key, SvcTemplateRequest{AgentMD: svcTestAgent}); st != 403 {
			t.Fatalf("templates after: %d", st)
		}
		if st := svcCall(t, h, http.MethodGet, SvcRunsPath, key); st != 200 {
			t.Fatalf("runs read after: %d", st)
		}
		svcSubmit(t, h, key, svcReq("space:ws:1", []string{"first", "second"}[i]))
	}
	for _, body := range []map[string]any{{"op": "scopes", "principal": "livepage"}, {"op": "scopes", "principal": "livepage", "scopes": nil}} {
		if st, _ := svcDo(t, h, http.MethodPost, SvcAdminPath, viewerToken, body); st != 400 {
			t.Fatalf("missing scopes: %d", st)
		}
	}
	if st, _ := svcAdmin(t, h, SvcAdminRequest{Op: "scopes", Principal: "livepage", Scopes: "admin"}); st != 400 {
		t.Fatalf("unknown scope: %d", st)
	}
	p, _ := h.srv.Store.SvcPrincipal("livepage")
	if strings.Join(p.Scopes, ",") != "runs:write,runs:read" {
		t.Fatalf("invalid update changed scopes: %+v", p)
	}
	if st, _ := svcAdmin(t, h, SvcAdminRequest{Op: "scopes", Principal: "missing", Scopes: "runs:read"}); st != 404 {
		t.Fatalf("missing principal: %d", st)
	}
	// Administrators can restore scopes or deliberately remove every scope.
	for _, scopes := range []string{"templates:write", ""} {
		if st, out := svcAdmin(t, h, SvcAdminRequest{Op: "scopes", Principal: "svc:livepage", Scopes: scopes}); st != 200 {
			t.Fatalf("rewrite %q: %d %v", scopes, st, out)
		}
		want := 200
		if scopes == "" {
			want = 403
		}
		if st, _ := svcPutTemplate(t, h, tok, SvcTemplateRequest{AgentMD: svcTestAgent}); st != want {
			t.Fatalf("templates: %d want %d", st, want)
		}
	}
	if st := svcCall(t, h, http.MethodGet, SvcWhoamiPath, tok); st != 200 {
		t.Fatalf("empty scopes revoked token: %d", st)
	}
	rows, err := h.srv.Store.FleetAuditLog(500)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, a := range rows {
		if a.Action == "svc.scopes" && a.Outcome == "ok" {
			count++
			if a.Actor == "" || a.FleetID != "svc:livepage" {
				t.Fatalf("audit: %+v", a)
			}
		}
	}
	if count != 3 {
		t.Fatalf("scope change audits = %d, want 3", count)
	}
}

func TestSvcRunTenantAllowlist(t *testing.T) {
	h, fr, tok := svcRunsHarness(t)
	// Unconfigured services keep the legacy SPACE tenant grammar.
	svcSubmit(t, h, tok, svcReq("space:ws:1", "legacy"))
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-a, app-b", http.StatusOK)
	other := svcSetup(t, h, "other", "runs:write,runs:read")
	svcSubmit(t, h, other, svcReq("space:ws:other", "unconfigured-other"))

	svcSubmit(t, h, tok, svcReq("app-a", "allowed"))
	before, _ := h.srv.Store.SvcRuns(store.SvcRunFilter{})
	fr.mu.Lock()
	starts := len(fr.started)
	fr.mu.Unlock()
	for _, req := range []SvcRunRequest{svcReq("space:ws:1", "legacy"), svcReq("app-c", "denied"), svcReq("", "empty"), svcReq("APP-A", "case"), svcReq("app-a-extra", "prefix")} {
		st, out := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, req)
		if st != 403 || out["error_code"] != "tenant_not_allowed" {
			t.Fatalf("tenant %s: %d %v", req.Tenant, st, out)
		}
	}
	after, _ := h.srv.Store.SvcRuns(store.SvcRunFilter{})
	fr.mu.Lock()
	afterStarts := len(fr.started)
	fr.mu.Unlock()
	if len(before) != len(after) || starts != afterStarts {
		t.Fatal("refused tenant queued or started a run")
	}
	rows, err := h.srv.Store.FleetAuditLog(500)
	if err != nil {
		t.Fatal(err)
	}
	refused := 0
	for _, a := range rows {
		if a.Action == "svc.run.submit" && a.Outcome == "REFUSED" && strings.Contains(a.OperationID, "tenant_not_allowed") {
			refused++
			if a.Actor != "svc:livepage" {
				t.Fatalf("audit: %+v", a)
			}
		}
	}
	if refused != 5 {
		t.Fatalf("refusal audits = %d", refused)
	}
	// Policy changes apply to replays as well, without restarting the hub.
	putSetting(t, h, svcTenantsKey("svc:livepage"), "app-b", http.StatusOK)
	if st, _ := svcDo(t, h, http.MethodPost, SvcRunsPath, tok, svcReq("app-a", "allowed")); st != 403 {
		t.Fatalf("removed tenant replay: %d", st)
	}
	svcSubmit(t, h, tok, svcReq("app-b", "still-allowed"))
	// Removing the setting restores runs' legacy behavior (passes remain stricter).
	putSetting(t, h, svcTenantsKey("svc:livepage"), "", http.StatusOK)
	svcSubmit(t, h, tok, svcReq("space:ws:1", "legacy"))
}
