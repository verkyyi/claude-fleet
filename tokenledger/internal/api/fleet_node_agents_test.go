package api

import (
	"encoding/json"
	"net/http"
	"testing"
)

// claude-fleet#3826: the pickers learn which agents the allowlists leave
// nothing for; no policy ⇒ every agent usable.
func nodeAgents(t *testing.T, h *harness, tok string) map[string]NodeAgent {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+NodeAgentsPath, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("agents: %d", res.StatusCode)
	}
	var out NodeAgentsResponse
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	m := map[string]NodeAgent{}
	for _, a := range out.Agents {
		m[a.Agent] = a
	}
	if len(out.Agents) != 2 || out.Agents[0].Agent != "claude" {
		t.Fatalf("agents: %+v", out.Agents)
	}
	return m
}

func TestNodeAgentsFollowAllowlists(t *testing.T) {
	h, alice, bob := policyRig(t)
	if m := nodeAgents(t, h, alice); m["claude"].Blocked || m["codex"].Blocked {
		t.Fatalf("no policy blocks nothing: %+v", m)
	}
	// alice: Codex only (the arvin case) — Claude greyed for the policy.
	setPolicy(t, h, "user", pAlice, []string{uuidCodex})
	m := nodeAgents(t, h, alice)
	if !m["claude"].Blocked || m["claude"].Reason != "policy" || m["codex"].Blocked {
		t.Fatalf("codex only: %+v", m)
	}
	// bob on the same machine has no list of his own: both.
	if m := nodeAgents(t, h, bob); m["claude"].Blocked || m["codex"].Blocked {
		t.Fatalf("bob: %+v", m)
	}
	// the machine's list takes Codex away from everyone there.
	setPolicy(t, h, "node", "mac-c", []string{uuidGmail})
	if m := nodeAgents(t, h, bob); m["claude"].Blocked || !m["codex"].Blocked {
		t.Fatalf("bob under mac-c's list: %+v", m)
	}
}
