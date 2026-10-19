package api

import (
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func TestRepoAuthorityRecoveryScope(t *testing.T) {
	h, _, _, f5, _ := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(token string) func(http.Header) {
		return func(h http.Header) { h.Set("Authorization", "Bearer "+token) }
	}
	path := FleetTicketsPath + "/authority/start?repo=" + writeRepo
	worker := f5.FleetID + "/" + wrFid
	for _, action := range []string{"reserve", "begin"} {
		code, out := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path,
			map[string]any{"action": action, "reservation": "original", "worker_id": worker})
		if code != 200 {
			t.Fatalf("start %d %v", code, out)
		}
	}
	for _, token := range []string{viewerToken, h.tokens["mac-c"], "foreign"} {
		if code, _ := ticketCall(t, h, auth(token), http.MethodGet, path+"&reservation=original", nil); code == 200 {
			t.Fatal("foreign/observer caller read original reservation")
		}
	}
	code, before := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, path+"&reservation=original", nil)
	if code != 200 || before["phase"] != "starting" {
		t.Fatal(code, before)
	}
	proof := map[string]any{"worker_id": worker, "native_session": "original", "pid": 42, "birth": "birth", "executable": "/bin/codex"}
	request := map[string]any{"action": "recover-observe", "reservation": "original", "worker_id": worker, "native_identity": proof}
	code, ack := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request)
	if code != 200 || ack["phase"] != "observed" {
		t.Fatal(code, ack)
	}
	code, again := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request)
	if code != 200 || !reflect.DeepEqual(ack, again) {
		t.Fatal("exact replay", code, again)
	}
	request["worker_id"] = "foreign/worker"
	if code, _ := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request); code == 200 {
		t.Fatal("foreign worker accepted")
	}
}

func TestRepoAuthorityAPILocalFinalGateReservation(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+h.tokens["mac-d"]) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	start := FleetTicketsPath + "/authority/start?repo=" + writeRepo
	refresh := func() {
		for _, f := range []control.Fleet{f5, f4} {
			if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
		}
	}
	refresh()
	code, reservation := ticketCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "paused-after-final-gate"})
	if code != 200 {
		t.Fatalf("final gate: %d %v", code, reservation)
	}
	// Launcher deliberately stays paused here BEFORE new-window/native creation.
	code, frozen := ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "freeze-paused", "expected_revision": 0, "legacy_tickets": "github"})
	if code != 200 {
		t.Fatalf("freeze: %d %v", code, frozen)
	}
	refresh()
	code, refused := ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "apply-paused", "expected_revision": 1})
	if code != 409 {
		t.Fatalf("empty fresh snapshot erased a reserved start: %d %v", code, refused)
	}
	// The launcher resumes; native creation is behind begin's one-shot CAS.
	code, _ = ticketCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "begin", "reservation": "paused-after-final-gate", "worker_id": f5.FleetID + "/" + wrFid})
	if code != 409 {
		t.Fatal("frozen launcher resumed native execution", code)
	}
	code, _ = ticketCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "cancel", "reservation": "paused-after-final-gate"})
	if code != 200 {
		t.Fatal("never-begun reservation cannot reconcile", code)
	}
	code, applied := ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "apply-reconciled", "expected_revision": 1})
	if code != 200 || applied["mode"] != "hub" {
		t.Fatalf("reconciled: %d %v", code, applied)
	}
}

func TestRepoAuthorityAPIManifestCutoverAndCapabilities(t *testing.T) {
	h, first, target, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	before, _ := h.srv.Store.FleetSettings()
	code, manifest := ticketCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || manifest["dry_run"] != true || len(manifest["legacy_owners"].([]any)) != 2 {
		t.Fatalf("inventory: %d %v", code, manifest)
	}
	after, _ := h.srv.Store.FleetSettings()
	if !reflect.DeepEqual(before, after) {
		t.Fatal("GET mutated registry")
	}
	freeze := map[string]any{"action": "freeze", "idempotency_key": "freeze", "expected_revision": 0, "legacy_tickets": "github"}
	code, a := ticketCall(t, h, auth, http.MethodPost, path, freeze)
	if code != 409 {
		t.Fatalf("unbound old owners must drain before freeze: %d %v", code, a)
	}
	unchanged, _ := h.srv.Store.RepoAuthority(writeRepo)
	after, _ = h.srv.Store.FleetSettings()
	if unchanged.Mode != "legacy" || unchanged.Revision != 0 || !reflect.DeepEqual(before, after) {
		t.Fatal("unbound preflight changed authority", unchanged)
	}
	// A separately observed native launch supplies a trustworthy binding; an
	// arbitrary caller receipt above could not create one. Bound owners stage.
	for _, raw := range manifest["legacy_owners"].([]any) {
		o := raw.(map[string]any)
		worker, ep := o["worker_id"].(string), o["endpoint_id"].(string)
		native := &store.RepoNativeIdentity{WorkerID: worker, NativeSession: "fixture-native", PID: 123, Birth: "birth", Executable: "/bin/codex"}
		for _, action := range []string{"reserve", "begin", "observe"} {
			if _, err := h.srv.Store.RepoLocalStart(writeRepo, "operator", ep, "observed-"+ep, action, worker, native, time.Now()); err != nil {
				t.Fatal(action, err)
			}
		}
	}
	code, a = ticketCall(t, h, auth, http.MethodPost, path, freeze)
	if code != 200 || a["mode"] != "frozen" {
		t.Fatalf("freeze: %d %v", code, a)
	}
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "legacy-frozen"}, 409)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "coding_agent": "codex", "idempotency_key": "new-frozen"}, 409)
	if first.count()+target.count() != 0 {
		t.Fatal("freeze sent a start")
	}
	code, _ = ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "unsafe", "expected_revision": 1})
	if code != 409 {
		t.Fatal("active owners allowed cutover", code)
	}
	// Removing observations still does not clear captured owners.
	for _, f := range []control.Fleet{f5, f4} {
		if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	code, _ = ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "absent", "expected_revision": 1})
	if code != 409 {
		t.Fatal("disappearance cleared native owner", code)
	}
	t.Log("fixture GET wrote nothing; frozen legacy and accepted starts sent zero writes; vanished legacy owners still block")
}

func TestRepoAuthorityAPICleanCutoverNoGitHub(t *testing.T) {
	h, _, target, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	refresh := func() {
		for _, f := range []control.Fleet{f5, f4} {
			if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
		}
	}
	refresh()
	code, a := ticketCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "freeze-empty", "expected_revision": 0, "legacy_tickets": "github"})
	if code != 200 {
		t.Fatalf("freeze: %d %v", code, a)
	}
	refresh()
	apply := map[string]any{"action": "apply", "idempotency_key": "apply-empty", "expected_revision": 1}
	code, a = ticketCall(t, h, auth, http.MethodPost, path, apply)
	if code != 200 || a["mode"] != "hub" {
		t.Fatalf("apply: %d %v", code, a)
	}
	code, again := ticketCall(t, h, auth, http.MethodPost, path, apply)
	if code != 200 || !reflect.DeepEqual(a, again) {
		t.Fatalf("repeat apply: %d %v", code, again)
	}
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "old-after"}, 409)
	// Legacy/home refs remain explicit; no GitHub reader is involved in task
	// acceptance, launch journaling, or lifecycle writes.
	target.setOpGet(verifiedLaunchFixture)
	op := postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "coding_agent": "codex", "idempotency_key": "hub-start"}, 200)
	if target.count() != 1 {
		t.Fatal("accepted start missing")
	}
	params := target.writes[0]["params"].(map[string]any)
	d := params["dispatch"].(map[string]any)
	rec, err := h.srv.Store.FleetTask(store.ParseTaskRef(d["task"].(string)))
	if err != nil || rec.AuthorityVersion != 1 {
		t.Fatal(rec, err)
	}
	if rec.Outcome != "" {
		t.Fatal("PR/start invented success", rec)
	}
	// A downlevel node cannot receive migrated work even after the initial
	// canary check. This checks the destination again on every start.
	row, _ := h.srv.Store.Fleet(f4.FleetID)
	h.srv.nodes.get(row.EndpointID).canRepoAuthority = false
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "fleet_id": f4.FleetID, "coding_agent": "codex", "idempotency_key": "old-node"}, 503)
	if target.count() != 1 {
		t.Fatal("downlevel node received work")
	}
	encoded, _ := json.Marshal(map[string]any{"authority": a, "task": rec.Ref, "operation": op["operation_id"], "work_outcome": rec.Outcome, "pr_completion": "unverified"})
	t.Logf("fixture clean cutover: %s; no GitHub access used; live acceptance NOT RUN", encoded)
}

// claude-fleet#4730: a cutover run from one host tells EVERY capable host of the
// repo to re-read its overlay — freeze, apply and rollback alike — and a host
// that connects later hears the current one on its first beat.
func TestRepoAuthorityTransitionTellsEveryHost(t *testing.T) {
	h, macD, macC, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	refresh := func() {
		for _, f := range []control.Fleet{f5, f4} {
			if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if len(macD.authorityPushes())+len(macC.authorityPushes()) != 0 {
		t.Fatal("a repo that never moved was pushed")
	}
	steps := []struct {
		body map[string]any
		mode string
	}{
		{map[string]any{"action": "freeze", "idempotency_key": "f", "expected_revision": 0, "legacy_tickets": "github"}, "frozen"},
		{map[string]any{"action": "apply", "idempotency_key": "a", "expected_revision": 1}, "hub"},
		{map[string]any{"action": "freeze", "idempotency_key": "f2", "expected_revision": 2, "legacy_tickets": "github"}, "frozen"},
		{map[string]any{"action": "rollback", "idempotency_key": "r", "expected_revision": 3}, "legacy"},
	}
	for i, st := range steps {
		refresh()
		if code, out := ticketCall(t, h, auth, http.MethodPost, path, st.body); code != 200 || out["mode"] != st.mode {
			t.Fatalf("%s: %d %v", st.mode, code, out)
		}
		want := control.RepoAuthority{Repo: writeRepo, Mode: st.mode, Revision: int64(i + 1)}
		for name, n := range map[string]*writeNode{"mac-d": macD, "mac-c": macC} {
			waitFor(t, 3*time.Second, name+" told "+st.mode, func() bool {
				p := n.authorityPushes()
				return len(p) == i+1 && p[i] == want
			})
		}
	}
	// A host coming back hears the authority once, on its first beat.
	again := connectWriteNodeCaps(t, h, h.tokens["mac-c"], control.CapRead, control.CapWrite, control.CapLaunch, control.CapRepoAuthority)
	again.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "reconnected host told", func() bool {
		p := again.authorityPushes()
		return len(p) == 1 && p[0] == control.RepoAuthority{Repo: writeRepo, Mode: "legacy", Revision: 4}
	})
	again.beatLoad("mac-c", "frank", machineB, 1, 1, f4)
	time.Sleep(200 * time.Millisecond)
	if len(again.authorityPushes()) != 1 {
		t.Fatal("a later beat pushed again", again.authorityPushes())
	}
}

// Issue #4832: the manifest carries each retained start as fields beside its
// unchanged blocker string, and a node lists ONLY its own endpoint's open starts.
func TestRepoAuthorityStartsAsFields(t *testing.T) {
	h, _, _, f5, _ := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(token string) func(http.Header) {
		return func(h http.Header) { h.Set("Authorization", "Bearer "+token) }
	}
	start := FleetTicketsPath + "/authority/start?repo=" + writeRepo
	worker := f5.FleetID + "/" + wrFid
	for _, step := range [][2]string{{"reserve", "held"}, {"reserve", "begun"}, {"begin", "begun"}, {"reserve", "gone"}, {"cancel", "gone"}} {
		code, out := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, start,
			map[string]any{"action": step[0], "reservation": step[1], "worker_id": worker})
		if code != 200 {
			t.Fatalf("%v %d %v", step, code, out)
		}
	}
	code, list := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, start+"&list=1", nil)
	if code != 200 {
		t.Fatal(code, list)
	}
	rows, _ := list["starts"].([]any)
	phases := map[string]string{}
	for _, raw := range rows {
		r := raw.(map[string]any)
		phases[r["reservation"].(string)] = r["phase"].(string)
		if r["endpoint_id"] != list["endpoint_id"] || r["updated"] == "" {
			t.Fatal("row", r)
		}
		if r["reservation"] == "begun" && r["worker_id"] != worker {
			t.Fatal("worker", r)
		}
	}
	if !reflect.DeepEqual(phases, map[string]string{"held": "reserved", "begun": "starting"}) {
		t.Fatal("open starts", phases)
	}
	if code, other := ticketCall(t, h, auth(h.tokens["mac-c"]), http.MethodGet, start+"&list=1", nil); code == 200 {
		if rows, _ := other["starts"].([]any); len(rows) != 0 {
			t.Fatal("another node read this node's starts", other)
		}
	}
	code, m := ticketCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, FleetTicketsPath+"/authority?repo="+writeRepo, nil)
	if code != 200 {
		t.Fatal(code, m)
	}
	blockers := map[string]bool{}
	for _, b := range m["blockers"].([]any) {
		blockers[b.(string)] = true
	}
	if !blockers["local start retained: held"] || !blockers["local start retained: begun"] || blockers["local start retained: gone"] {
		t.Fatal("blocker strings changed", m["blockers"])
	}
	if starts, _ := m["starts"].([]any); len(starts) != 2 {
		t.Fatal("manifest starts", m["starts"])
	}
}

// claude-fleet#4831: a retired endpoint can never launch or observe again, so
// its fleet row is no host of the repo — listed under retired_hosts, never a
// blocker — while a live host's row and owners stay exactly as they were.
func TestRepoAuthorityRetiredHostBlocksNothing(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	row, _ := h.srv.Store.Fleet(f4.FleetID)
	if _, err := h.srv.Store.RepoLocalStart(writeRepo, "operator", row.EndpointID, "left-open", "reserve", "", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	mentions := func(m map[string]any, s string) bool {
		b, _ := json.Marshal(map[string]any{"b": m["blockers"], "o": m["legacy_owners"], "n": m["nodes"]})
		return strings.Contains(string(b), s)
	}
	code, before := ticketCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || !mentions(before, f4.FleetID) || !mentions(before, "left-open") || len(before["retired_hosts"].([]any)) != 0 {
		t.Fatalf("before: %d %v", code, before)
	}
	res, err := h.srv.Store.RetireEndpointAs(row.EndpointID, "operator", "drill", time.Now())
	if err != nil || !res.Retired || res.Settled.Starts != 1 {
		t.Fatal(res, err)
	}
	code, after := ticketCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || mentions(after, f4.FleetID) || mentions(after, row.EndpointID) || mentions(after, "left-open") {
		t.Fatalf("a retired host still blocks: %d %v", code, after)
	}
	retired := after["retired_hosts"].([]any)
	if len(retired) != 1 || retired[0].(map[string]any)["fleet_id"] != f4.FleetID {
		t.Fatalf("retired_hosts: %v", retired)
	}
	if !mentions(after, f5.FleetID) {
		t.Fatalf("the live host vanished: %v", after)
	}
	strip := func(m map[string]any) string {
		var keep []any
		for _, o := range m["legacy_owners"].([]any) {
			if o.(map[string]any)["endpoint_id"] != row.EndpointID {
				keep = append(keep, o)
			}
		}
		b, _ := json.Marshal(keep)
		return string(b)
	}
	if strip(before) != strip(after) {
		t.Fatalf("the live host's owners changed:\n%s\n%s", strip(before), strip(after))
	}
}

// A fleet row no machine reports any more, whose machine has since reported a
// newer row, is superseded (claude-fleet#4877): listed apart in
// superseded_hosts, no host, no blocker. An absent row with no successor still
// blocks; another repo's manifest stays byte for byte.
func TestRepoAuthoritySupersededFleetRowBlocksNothing(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetTicketsPath + "/authority?repo=" + writeRepo
	other := FleetTicketsPath + "/authority?repo=verkyyi/other-repo"
	st := h.srv.Store
	touch := func(ep, host, hw string) {
		if _, err := st.DB().Exec(`UPDATE endpoints SET hostname = ?, os_user = 'frank', machine_id = ? WHERE endpoint_id = ?`, host, hw, ep); err != nil {
			t.Fatal(err)
		}
	}
	h.enroll(t, "mac-c-old")
	h.enroll(t, "mac-z")
	touch("ep_mac-c", "mac-c", "hw-c")
	touch("ep_mac-c-old", "mac-c", "hw-c") // the same login, joined again
	touch("ep_mac-z", "mac-z", "hw-z")
	rep := func(f control.Fleet) store.FleetReport {
		return store.FleetReport{FleetID: f.FleetID, Name: f.Name, Repo: f.Repo, Checkout: f.Checkout,
			Agent: f.Agent, State: f.State, WorkerCount: f.Count, WorkersJSON: string(f.Workers)}
	}
	machineD := "44444444-4444-4444-8444-444444444444"
	sameMachine := fakeFleet(t, machineB, "fleet-old", writeRepo, "/u/frank/old")
	rejoined := fakeFleet(t, machineC, "fleet-rejoined", writeRepo, "/u/frank/claude-fleet")
	stranger := fakeFleet(t, machineD, "fleet-z", writeRepo, "/u/frank/claude-fleet")
	_, otherBefore := ticketCall(t, h, auth, http.MethodGet, other, nil)
	t0 := time.Now().Add(-time.Hour)
	snap := func(ep, host string, machine string, at time.Time, fs ...control.Fleet) {
		var reps []store.FleetReport
		for _, f := range fs {
			reps = append(reps, rep(f))
		}
		if _, err := st.RecordFleetSnapshot(ep, host, "frank", machine, reps, at); err != nil {
			t.Fatal(err)
		}
	}
	snap("ep_mac-c", "mac-c", machineB, t0, sameMachine, f4)
	snap("ep_mac-c-old", "mac-c", machineC, t0, rejoined)
	snap("ep_mac-c-old", "mac-c", machineC, t0.Add(time.Second))
	snap("ep_mac-z", "mac-z", machineD, t0, stranger)
	snap("ep_mac-z", "mac-z", machineD, t0.Add(time.Second))
	snap("ep_mac-c", "mac-c", machineB, time.Now(), f4)

	code, m := ticketCall(t, h, auth, http.MethodGet, path, nil)
	blockers, _ := json.Marshal(m["blockers"])
	if code != 200 || strings.Contains(string(blockers), sameMachine.FleetID) || strings.Contains(string(blockers), rejoined.FleetID) {
		t.Fatalf("a superseded row still blocks: %d %s", code, blockers)
	}
	if !strings.Contains(string(blockers), stranger.FleetID) {
		t.Fatalf("an absent row with no successor stopped blocking: %s", blockers)
	}
	got := map[string]string{}
	for _, x := range m["superseded_hosts"].([]any) {
		e := x.(map[string]any)
		got[e["fleet_id"].(string)] = e["superseded_by"].(string)
	}
	if len(got) != 2 || got[sameMachine.FleetID] != f4.FleetID || got[rejoined.FleetID] != f4.FleetID {
		t.Fatalf("superseded_hosts: %v", m["superseded_hosts"])
	}
	nodes, _ := json.Marshal(m["nodes"])
	if !strings.Contains(string(nodes), f5.FleetID) || !strings.Contains(string(nodes), f4.FleetID) || strings.Contains(string(nodes), sameMachine.FleetID) {
		t.Fatalf("nodes: %s", nodes)
	}
	_, otherAfter := ticketCall(t, h, auth, http.MethodGet, other, nil)
	for _, k := range []string{"blockers", "nodes", "retired_hosts", "superseded_hosts", "legacy_owners"} {
		if !reflect.DeepEqual(otherBefore[k], otherAfter[k]) {
			t.Fatalf("another repo's %s changed: %v → %v", k, otherBefore[k], otherAfter[k])
		}
	}
}

// supersededBy itself: a present row is never superseded (a live host that is
// not capable keeps blocking), and a successor observed earlier proves nothing.
func TestSupersededByRules(t *testing.T) {
	now := time.Now()
	eps := func(id string) *store.Endpoint {
		if id == "" {
			return nil
		}
		return &store.Endpoint{ID: id, MachineID: "hw", OSUser: "u"}
	}
	old := store.FleetRow{FleetID: "a", MachineID: "m", EndpointID: "e", ObservedAt: now.Add(-time.Hour)}
	succ := store.FleetRow{FleetID: "b", MachineID: "m", EndpointID: "e", Present: true, ObservedAt: now}
	if g, ok := supersededBy(old, []store.FleetRow{old, succ}, eps); !ok || g.FleetID != "b" {
		t.Fatal("same machine, newer present row: superseded")
	}
	live := old
	live.Present = true
	if _, ok := supersededBy(live, []store.FleetRow{live, succ}, eps); ok {
		t.Fatal("a present row was superseded")
	}
	early := succ
	early.ObservedAt = now.Add(-2 * time.Hour)
	if _, ok := supersededBy(old, []store.FleetRow{old, early}, eps); ok {
		t.Fatal("a successor observed before the row superseded it")
	}
	absent := succ
	absent.Present = false
	if _, ok := supersededBy(old, []store.FleetRow{old, absent}, eps); ok {
		t.Fatal("an absent successor superseded it")
	}
	retired := func(id string) *store.Endpoint {
		e := eps(id)
		if id == "e2" {
			at := now
			e.RetiredAt = &at
		}
		return e
	}
	gone := succ
	gone.MachineID, gone.EndpointID = "m2", "e2"
	if _, ok := supersededBy(old, []store.FleetRow{old, gone}, retired); ok {
		t.Fatal("a retired successor superseded it")
	}
}
