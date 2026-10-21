package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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

// An accepted dispatch (a task) is tried on the next machine too (claude-fleet
// T672): mac-c's spawn declines, m3 opens it as its own operation of the same
// task; the answer names mac-c's try.
func TestNodePlaceDispatchDeclinedTriesNext(t *testing.T) {
	h, macD, macC, f5, _ := twoNodesCaps(t, control.CapLaunch)
	m3 := connectWriteNodeCaps(t, h, h.enroll(t, "m3"), control.CapRead, control.CapWrite, control.CapLaunch)
	f3 := fakeFleet(t, machineC, "fleet-m3", writeRepo, "/u/frank/claude-fleet", 3)
	m3.beatLoad("m3", "frank", machineC, 6, 1, f3)
	waitFor(t, 3*time.Second, "three fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 3
	})
	waitLoad(t, h, "m3", 6)
	macC.setOpGet(declines(2, "暂停开新：内存紧张"))
	m3.setOpGet(startedFixture)
	st, out := placeCall(t, h, h.tokens["mac-d"], map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f5.FleetID,
		"coding_agent": "claude", "idempotency_key": "task-retry-1", "tries": 3})
	if st != 200 || out["placement"].(map[string]any)["machine"] != "m3" {
		t.Fatalf("place = %d %v; want the task on m3 after mac-c declined", st, out)
	}
	if as := attemptsOf(t, out); len(as) != 1 || as[0]["machine"] != "mac-c" {
		t.Fatalf("attempts = %v; want mac-c's decline", as)
	}
	if macD.count() != 0 || macC.count() != 1 || m3.count() != 1 {
		t.Fatalf("writes mac-d=%d mac-c=%d m3=%d", macD.count(), macC.count(), m3.count())
	}
	d := out["dispatch"].(map[string]any)
	if m3.writes[0]["params"].(map[string]any)["task"] != d["task"] || macC.writes[0]["params"].(map[string]any)["task"] != d["task"] {
		t.Fatal("both tries must carry the one accepted task")
	}
	if m3.writes[0]["operation_id"] == macC.writes[0]["operation_id"] {
		t.Fatal("the next try is its own operation")
	}
	if !retryKeyOf("task-retry-1:try2", "task-retry-1") || retryKeyOf("task-retry-1:tryx", "task-retry-1") || retryKeyOf("other:try2", "task-retry-1") {
		t.Fatal("retryKeyOf")
	}
}

// A task whose repo has capitals (claude-fleet T672: GuangZhouShanyouGame/…):
// its record keeps the repo lower-cased, the start names it as the fleet
// registered it — one repo, so the placement goes ahead (it answered 409
// «owner, generation or provider does not match» before).
func TestNodePlaceTaskRepoCase(t *testing.T) {
	mixed := "Verkyyi/Claude-Fleet" // as the fleets registered it
	h := newFleetHarness(t)
	caps := []string{control.CapRead, control.CapWrite, control.CapLaunch}
	macD := connectWriteNodeCaps(t, h, h.enroll(t, "mac-d"), caps...)
	macC := connectWriteNodeCaps(t, h, h.enroll(t, "mac-c"), caps...)
	f5 := fakeFleet(t, machineA, "fleet-mac-d", mixed, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", mixed, "/u/frank/claude-fleet", 2)
	macD.beatLoad("mac-d", "frank", machineA, 10, 3, f5)
	macC.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	macC.setOpGet(startedFixture)
	tok := h.tokens["mac-d"]
	d := map[string]any{"version": 1, "request_id": "case-1", "requested_agent": "claude", "resolved_agent": "claude", "agent_source": "explicit"}
	st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": "case-1",
		"title": "case", "repo": writeRepo, "requested_agent": "claude", "resolved_agent": "claude",
		"request_payload": map[string]any{"dispatch": d, "title": "case", "repo": writeRepo}})
	if st != 200 {
		t.Fatalf("accept: %d %v", st, rec)
	}
	d["task"], d["generation"], d["attempt_id"] = rec["id"], rec["generation"], rec["attempt_id"]
	st, out := placeCall(t, h, tok, map[string]any{"repo": mixed, "kind": "scratch", "fleet_id": f5.FleetID,
		"dispatch": d, "idempotency_key": "case-1"})
	if st != 200 || macC.count() != 1 {
		t.Fatalf("place(%s) = %d %v; want the task placed", mixed, st, out)
	}
}

// A no-repo session is placed like any other (claude-fleet T742): a scratch
// that names no repo is a candidate on every machine of the person's — even
// one hosting none of the asker's repos — and the start that goes there says
// no_repo, never a repo; a no-repo task's record travels with it.
func TestNodePlaceNoRepoScratch(t *testing.T) {
	h := newFleetHarness(t)
	caps := []string{control.CapRead, control.CapWrite, control.CapLaunch}
	macD := connectWriteNodeCaps(t, h, h.enroll(t, "mac-d"), caps...)
	macC := connectWriteNodeCaps(t, h, h.enroll(t, "mac-c"), caps...)
	f5 := fakeFleet(t, machineA, "fleet-mac-d", writeRepo, "/u/frank/claude-fleet", 1)
	f4 := fakeFleet(t, machineB, "fleet-mac-c", "acme/other", "/u/frank/other", 2)
	macD.beatLoad("mac-d", "frank", machineA, 10, 3, f5) // busy
	macC.beatLoad("mac-c", "frank", machineB, 1, 1, f4)  // idle, hosts none of mac-d's repos
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	macC.setOpGet(startedFixture)
	tok := h.tokens["mac-d"]

	// A repo'd scratch never leaves the machines that host the repo.
	if st, out := placeCall(t, h, tok, map[string]any{"repo": writeRepo, "kind": "scratch", "fleet_id": f5.FleetID}); st != 200 || out["local"] != true {
		t.Fatalf("place(repo) = %d %v; want LOCAL mac-d (mac-c hosts no %s)", st, out, writeRepo)
	}
	// No repo: the idle machine, whatever it hosts.
	st, out := placeCall(t, h, tok, map[string]any{"repo": "", "kind": "scratch", "fleet_id": f5.FleetID,
		"body": "drive the batch", "as": "epic-driver", "idempotency_key": "nr-1"})
	if st != 200 || out["local"] != false || out["placement"].(map[string]any)["machine"] != "mac-c" {
		t.Fatalf("place(no repo) = %d %v; want REMOTE mac-c", st, out)
	}
	if macC.count() != 1 || macD.count() != 0 {
		t.Fatalf("writes mac-c=%d mac-d=%d; want one start, mac-c's", macC.count(), macD.count())
	}
	params := macC.writes[0]["params"].(map[string]any)
	if params["no_repo"] != true || params["repo"] != nil || params["kind"] != "scratch" || params["as"] != "epic-driver" || params["body"] != "drive the batch" {
		t.Fatalf("mac-c was sent %v; want a no_repo scratch with its seed and agent file", params)
	}
	// A no-repo task: its record (no repo) is accepted and rides the start.
	d := map[string]any{"version": 1, "request_id": "nr-task-1", "requested_agent": "claude", "resolved_agent": "claude", "agent_source": "explicit"}
	st, rec := nodeTaskCall(t, h, tok, http.MethodPost, NodeTasksPath, map[string]any{"authority_version": 1, "token": "nr-task-1",
		"title": "EPIC: x", "requested_agent": "claude", "resolved_agent": "claude",
		"request_payload": map[string]any{"dispatch": d, "title": "EPIC: x"}})
	if st != 200 {
		t.Fatalf("accept: %d %v", st, rec)
	}
	d["task"], d["generation"], d["attempt_id"] = rec["id"], rec["generation"], rec["attempt_id"]
	st, out = placeCall(t, h, tok, map[string]any{"repo": "", "kind": "scratch", "fleet_id": f5.FleetID,
		"dispatch": d, "idempotency_key": "nr-task-1"})
	if st != 200 || macC.count() != 2 {
		t.Fatalf("place(no-repo task) = %d %v; want it sent to mac-c", st, out)
	}
	params = macC.writes[1]["params"].(map[string]any)
	if params["no_repo"] != true || params["repo"] != nil || params["task"] != rec["id"] {
		t.Fatalf("mac-c was sent %v; want the no-repo task %v", params, rec["id"])
	}
	// An issue start still names its repo.
	if st, _ := placeCall(t, h, tok, map[string]any{"repo": "", "issue": 9, "worker_id": issueWID(f5.FleetID, 9)}); st != 400 {
		t.Fatalf("issue with no repo = %d; want 400", st)
	}
}
