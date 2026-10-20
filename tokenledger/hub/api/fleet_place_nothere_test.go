package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The asker's own admission says no (claude-fleet T672): an idle mac-c that
// would be placement's pick says «not here» — the hub sends the scratch to
// m3 in the same round trip, carrying its seed and agent file, and keeps
// mac-c out of the next auto placement until mac-c asks again without one.
func TestNodePlaceNotHereGoesElsewhere(t *testing.T) {
	h, macD, macC, m3, _, f4, f3 := threeNodes(t)
	tok4 := h.tokens["mac-c"]
	m3.setOpGet(finished("succeeded", map[string]any{"exit": 0, "window": "@61",
		"workers": []any{map[string]any{"window_id": "@61", "scratch": true}}}))

	// Without it, mac-c (0.1/core) keeps its own scratch.
	st, out := placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f4.FleetID})
	if st != 200 || out["local"] != true {
		t.Fatalf("place = %d %v; want LOCAL mac-c", st, out)
	}
	st, out = placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f4.FleetID,
		"not_here": "暂停开新：内存紧张", "body": "做 T672\n\n全文", "as": "fleet-worker", "idempotency_key": "nh-1"})
	if st != 200 || out["local"] != false || out["placement"].(map[string]any)["machine"] != "m3" {
		t.Fatalf("place(not_here) = %d %v; want REMOTE m3", st, out)
	}
	if oc := placeOutcomeOf(t, out); oc["state"] != "done" || oc["window"] != "@61" {
		t.Fatalf("outcome = %v; want done on m3", oc)
	}
	if macC.count() != 0 || macD.count() != 0 || m3.count() != 1 {
		t.Fatalf("writes mac-c=%d mac-d=%d m3=%d; want one start, m3's", macC.count(), macD.count(), m3.count())
	}
	if m3.writes[0]["fleet_id"] != f3.FleetID {
		t.Fatalf("sent to %v; want m3's fleet", m3.writes[0]["fleet_id"])
	}
	params := m3.writes[0]["params"].(map[string]any)
	if params["body"] != "做 T672\n\n全文" || params["as"] != "fleet-worker" || params["kind"] != "scratch" {
		t.Fatalf("m3 was sent %v; want the seed and the agent file", params)
	}
	reason := out["placement"].(map[string]any)["reason"].(string)
	if !strings.Contains(reason, "本机准入不过：暂停开新：内存紧张") {
		t.Fatalf("reason = %q; want mac-c's own refusal named", reason)
	}

	// The hold: mac-d asking now does not land on mac-c.
	pl, err := h.srv.pickNode(fleetPrincipal{Actor: "t", scope: func(_, u string) bool { return u == "frank" }}, writeRepo, "auto", "", time.Now())
	if err != nil || pl.Machine == "mac-c" {
		t.Fatalf("pick while mac-c is held = %v %v; want another machine", pl.Machine, err)
	}
	// mac-c asking again without one lifts it.
	if st, out := placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f4.FleetID}); st != 200 || out["local"] != true {
		t.Fatalf("place after the hold = %d %v; want LOCAL mac-c again", st, out)
	}

	// An agent file's name is checked.
	if st, _ := placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f4.FleetID, "as": "../x"}); st != 400 {
		t.Fatalf("as=../x = %d; want 400", st)
	}
	// A seed belongs to a scratch.
	if st, _ := placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "issue": 9, "worker_id": issueWID(f4.FleetID, 9), "body": "x"}); st != 400 {
		t.Fatalf("issue with body = %d; want 400", st)
	}
}

// Every machine full (claude-fleet T672): the asker says «not here», the only
// other eligible one declines too — refused, each machine's reason named,
// never LOCAL.
func TestNodePlaceNotHereAllFullNamesEach(t *testing.T) {
	h, _, macC, m3, _, f4, _ := threeNodes(t)
	tok4 := h.tokens["mac-c"]
	m3.setOpGet(declines(2, "fleet-m3 is full: 8/8"))
	st, out := placeCall(t, h, tok4, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f4.FleetID,
		"not_here": "暂停开新：负载过高", "tries": 3})
	e, _ := out["error"].(map[string]any)
	msg, _ := e["message"].(string)
	if st != 409 || e["code"] != "ALL_DECLINED" || !strings.Contains(msg, "mac-c: 本机准入不过：暂停开新：负载过高") ||
		!strings.Contains(msg, "m3: declined: fleet-m3 is full: 8/8") || !strings.Contains(msg, "mac-d:") {
		t.Fatalf("place = %d %v; want ALL_DECLINED naming every machine", st, out)
	}
	if macC.count() != 0 {
		t.Fatal("the asker that said «not here» was sent a start")
	}
}

// The answer says how long the hub spent after its pick (claude-fleet T672):
// the asker's place_ms is its wait less this.
func TestNodePlaceSaysAfterPick(t *testing.T) {
	h, _, _, f5, _ := twoNodes(t)
	b, _ := json.Marshal(map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f5.FleetID, "wait": 0})
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/node/place", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+h.tokens["mac-d"])
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if v := resp.Header.Get(AfterPickHeader); resp.StatusCode != 200 || v == "" {
		t.Fatalf("= %d, %s %q; want the after-pick time", resp.StatusCode, AfterPickHeader, v)
	}
}
