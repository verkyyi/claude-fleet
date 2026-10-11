package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// There is no orchestrating seat (claude-fleet#3118): an older node that still
// asks /v1/node/orchestrator on its tick is told 「没有编排」 with no machine —
// rule none, never here, never a 500 — however it asks; no token is still 401.
func TestNoOrchestratorEndpoint(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	ask := func(machine, method string, body []byte) (int, OrchestratorResponse) {
		t.Helper()
		req, _ := http.NewRequest(method, h.http.URL+"/v1/node/orchestrator", bytes.NewReader(body))
		if machine != "" {
			req.Header.Set("Authorization", "Bearer "+h.tokens[machine])
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out OrchestratorResponse
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	for _, c := range []struct {
		machine, method string
		body            []byte
	}{{"m5", http.MethodGet, nil}, {"m4", http.MethodGet, nil},
		{"m5", http.MethodPost, []byte(`{"eligible":true}`)}, {"m4", http.MethodPost, []byte(`{"eligible":false}`)}} {
		st, out := ask(c.machine, c.method, c.body)
		if st != 200 || out.Machine != "" || out.Here || out.Rule != "none" || !strings.Contains(out.Reason, "没有编排") {
			t.Fatalf("%s %s: HTTP %d %+v; want 200 no machine, rule none, 没有编排", c.method, c.machine, st, out)
		}
	}
	if st, _ := ask("", http.MethodGet, nil); st != 401 {
		t.Fatalf("no token: HTTP %d; want 401", st)
	}
	if st, _ := ask("m5", http.MethodDelete, nil); st != 405 {
		t.Fatalf("DELETE: HTTP %d; want 405", st)
	}
}
