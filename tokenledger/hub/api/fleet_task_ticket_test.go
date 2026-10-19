package api

import (
	"net/http"
	"testing"
)

func TestNodeTaskTicketBoundary(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	token := nodes["bob4"].token
	input := map[string]any{"authority_version": 1, "token": "ticket-boundary", "title": "ticket", "repo": "org/repo", "requested_agent": "codex", "resolved_agent": "codex", "request_payload": map[string]any{"rule": "n=1 v=abcd"}}
	code, rec := nodeTaskCall(t, h, token, http.MethodPost, NodeTasksPath, input)
	if code != 200 {
		t.Fatal(code, rec)
	}
	path := NodeTasksPath + "/" + rec["id"].(string)
	prepare := map[string]any{"kind": "ticket_prepare", "idempotency_key": "ticket-file:g1", "generation": 1, "filing_id": "11111111-1111-4111-8111-111111111111"}
	link := map[string]any{"kind": "ticket_link", "idempotency_key": "ticket-link:g1", "generation": 1, "filing_id": prepare["filing_id"], "ticket_ref": "gh:org/repo#71"}
	call := func(tok string, m map[string]any, want int) {
		t.Helper()
		code, out := nodeTaskCall(t, h, tok, http.MethodPost, path, map[string]any{"authority_version": 1, "mutation": m})
		if code != want {
			t.Fatalf("%v -> %d %v; want %d", m, code, out, want)
		}
	}
	call(token, prepare, 200)
	call(nodes["alice4"].token, link, 404)
	call("invalid-token", link, 401)
	link["ticket_ref"] = "gh:other/repo#71"
	call(token, link, 409)
	link["ticket_ref"] = "gh:org/repo#71"
	link["generation"] = 2
	link["idempotency_key"] = "ticket-link:g2"
	call(token, link, 409)
	link["generation"] = 1
	link["idempotency_key"] = "ticket-link:g1"
	link["resolved_agent"] = "claude"
	call(token, link, 400)
	delete(link, "resolved_agent")
	link["parent_session"] = "forged"
	call(token, link, 400)
	delete(link, "parent_session")
	call(token, link, 200)
	call(token, link, 200)
	for _, legacy := range []map[string]any{{"issue": "org/repo#72"}, {"rule": "n=2 v=abcd"}, {"authority_version": 1, "rule": "n=1 v=abcd", "mutation": link}} {
		code, _ := nodeTaskCall(t, h, token, http.MethodPost, path, legacy)
		if code != 400 && code != 409 {
			t.Fatalf("legacy bypass: %d", code)
		}
	}
	input["rule"] = "n=1 v=abcd"
	if code, _ := nodeTaskCall(t, h, token, http.MethodPost, NodeTasksPath, input); code != 400 {
		t.Fatalf("top-level rule widened: %d", code)
	}
}
