package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

// The person's ONE orchestrator (claude-fleet#2117): every machine asks, one is
// named, the holder sticks until it goes 维护中 / lost / says "not here".

func orchAsk(t *testing.T, h *harness, machine string, eligible *bool) OrchestratorResponse {
	t.Helper()
	method, body := http.MethodGet, []byte(nil)
	if eligible != nil {
		method = http.MethodPost
		body, _ = json.Marshal(map[string]bool{"eligible": *eligible})
	}
	req, _ := http.NewRequest(method, h.http.URL+"/v1/node/orchestrator", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+h.tokens[machine])
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("%s %s: HTTP %d", method, machine, resp.StatusCode)
	}
	var out OrchestratorResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestOrchestratorOneHolder(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	want := func(step string, got OrchestratorResponse, machine string, here bool) {
		t.Helper()
		if got.Machine != machine || got.Here != here {
			t.Fatalf("%s: %+v; want machine=%s here=%v", step, got, machine, here)
		}
	}
	// The first machine to ask holds it; the other one is told it is not here.
	want("m5 asks first", orchAsk(t, h, "m5", nil), "m5", true)
	want("m4 asks", orchAsk(t, h, "m4", nil), "m5", false)
	want("m5 again (sticky)", orchAsk(t, h, "m5", nil), "m5", true)

	// The holder goes 维护中: the next ask hands it to the other machine, and
	// the old holder is then told it is not here.
	putSetting(t, h, NodeMaintenancePrefix+"m5", "升级", 200)
	want("m4 asks, m5 维护中", orchAsk(t, h, "m4", nil), "m4", true)
	want("m5 asks, 维护中", orchAsk(t, h, "m5", nil), "m4", false)

	// Back from maintenance: the holder stays where it went.
	putSetting(t, h, NodeMaintenancePrefix+"m5", "", 200)
	want("m5 back", orchAsk(t, h, "m5", nil), "m4", false)

	// The holder says "not here" (FLEET_ORCHESTRATOR=0 there): it moves.
	no := false
	want("m4 says no", orchAsk(t, h, "m4", &no), "m5", false)
	want("m5 asks after", orchAsk(t, h, "m5", nil), "m5", true)
	want("m4 again", orchAsk(t, h, "m4", nil), "m5", false)
}

// Every online machine 维护中: one of them still holds it, never none, never two.
func TestOrchestratorAllMaintenance(t *testing.T) {
	h, _, _, _, _ := twoNodes(t)
	putSetting(t, h, NodeMaintenancePrefix+"m5", "x", 200)
	putSetting(t, h, NodeMaintenancePrefix+"m4", "y", 200)
	a := orchAsk(t, h, "m4", nil)
	b := orchAsk(t, h, "m5", nil)
	if a.Machine == "" || a.Machine != b.Machine || a.Here == b.Here {
		t.Fatalf("all 维护中: m4=%+v m5=%+v; want one holder named to both", a, b)
	}
}
