package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
)

// authorityCall is one request to the authority road with auth (a bearer).
func authorityCall(t *testing.T, h *harness, auth func(http.Header), method, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, rd)
	if auth != nil {
		auth(req.Header)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	if out == nil {
		out = map[string]any{"raw": string(raw)}
	}
	return res.StatusCode, out
}

func TestRepoAuthorityRecoveryScope(t *testing.T) {
	h, _, _, f5, _ := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(token string) func(http.Header) {
		return func(h http.Header) { h.Set("Authorization", "Bearer "+token) }
	}
	path := FleetAuthorityPath + "/start?repo=" + writeRepo
	worker := f5.FleetID + "/" + wrFid
	for _, action := range []string{"reserve", "begin"} {
		code, out := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path,
			map[string]any{"action": action, "reservation": "original", "worker_id": worker})
		if code != 200 {
			t.Fatalf("start %d %v", code, out)
		}
	}
	for _, token := range []string{viewerToken, h.tokens["mac-c"], "foreign"} {
		if code, _ := authorityCall(t, h, auth(token), http.MethodGet, path+"&reservation=original", nil); code == 200 {
			t.Fatal("foreign/observer caller read original reservation")
		}
	}
	code, before := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, path+"&reservation=original", nil)
	if code != 200 || before["phase"] != "starting" {
		t.Fatal(code, before)
	}
	proof := map[string]any{"worker_id": worker, "native_session": "original", "pid": 42, "birth": "birth", "executable": "/bin/codex"}
	request := map[string]any{"action": "recover-observe", "reservation": "original", "worker_id": worker, "native_identity": proof}
	code, ack := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request)
	if code != 200 || ack["phase"] != "observed" {
		t.Fatal(code, ack)
	}
	code, again := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request)
	if code != 200 || !reflect.DeepEqual(ack, again) {
		t.Fatal("exact replay", code, again)
	}
	request["worker_id"] = "foreign/worker"
	if code, _ := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, request); code == 200 {
		t.Fatal("foreign worker accepted")
	}
}

func TestRepoAuthorityAPILocalFinalGateReservation(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+h.tokens["mac-d"]) }
	path := FleetAuthorityPath + "?repo=" + writeRepo
	start := FleetAuthorityPath + "/start?repo=" + writeRepo
	refresh := func() {
		for _, f := range []control.Fleet{f5, f4} {
			if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
		}
	}
	refresh()
	code, reservation := authorityCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "paused-after-final-gate"})
	if code != 200 {
		t.Fatalf("final gate: %d %v", code, reservation)
	}
	// Launcher deliberately stays paused here BEFORE new-window/native creation.
	code, frozen := authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "freeze-paused", "expected_revision": 0, "legacy_tickets": "github"})
	if code != 200 {
		t.Fatalf("freeze: %d %v", code, frozen)
	}
	refresh()
	code, refused := authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "apply-paused", "expected_revision": 1})
	if code != 409 {
		t.Fatalf("empty fresh snapshot erased a reserved start: %d %v", code, refused)
	}
	// The launcher resumes; native creation is behind begin's one-shot CAS.
	code, _ = authorityCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "begin", "reservation": "paused-after-final-gate", "worker_id": f5.FleetID + "/" + wrFid})
	if code != 409 {
		t.Fatal("frozen launcher resumed native execution", code)
	}
	code, _ = authorityCall(t, h, auth, http.MethodPost, start, map[string]any{"action": "cancel", "reservation": "paused-after-final-gate"})
	if code != 200 {
		t.Fatal("never-begun reservation cannot reconcile", code)
	}
	code, applied := authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "apply-reconciled", "expected_revision": 1})
	if code != 200 || applied["mode"] != "hub" {
		t.Fatalf("reconciled: %d %v", code, applied)
	}
}

func TestRepoAuthorityAPIManifestCutoverAndCapabilities(t *testing.T) {
	h, first, target, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetAuthorityPath + "?repo=" + writeRepo
	before, _ := h.srv.Store.FleetSettings()
	code, manifest := authorityCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || manifest["dry_run"] != true || len(manifest["legacy_owners"].([]any)) != 2 {
		t.Fatalf("inventory: %d %v", code, manifest)
	}
	after, _ := h.srv.Store.FleetSettings()
	if !reflect.DeepEqual(before, after) {
		t.Fatal("GET mutated registry")
	}
	freeze := map[string]any{"action": "freeze", "idempotency_key": "freeze", "expected_revision": 0, "legacy_tickets": "github"}
	code, a := authorityCall(t, h, auth, http.MethodPost, path, freeze)
	if code != 409 {
		t.Fatalf("unbound old owners must drain before freeze: %d %v", code, a)
	}
	unchanged, _ := h.srv.Store.OwnerAuthority("operator")
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
	code, a = authorityCall(t, h, auth, http.MethodPost, path, freeze)
	if code != 200 || a["mode"] != "frozen" {
		t.Fatalf("freeze: %d %v", code, a)
	}
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "idempotency_key": "legacy-frozen"}, 409)
	postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "repo": writeRepo, "coding_agent": "codex", "idempotency_key": "new-frozen"}, 409)
	if first.count()+target.count() != 0 {
		t.Fatal("freeze sent a start")
	}
	code, _ = authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "unsafe", "expected_revision": 1})
	if code != 409 {
		t.Fatal("active owners allowed cutover", code)
	}
	// Removing observations still does not clear captured owners.
	for _, f := range []control.Fleet{f5, f4} {
		if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	code, _ = authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "absent", "expected_revision": 1})
	if code != 409 {
		t.Fatal("disappearance cleared native owner", code)
	}
	t.Log("fixture GET wrote nothing; frozen legacy and accepted starts sent zero writes; vanished legacy owners still block")
}

func TestRepoAuthorityAPICleanCutoverNoGitHub(t *testing.T) {
	h, _, target, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetAuthorityPath + "?repo=" + writeRepo
	refresh := func() {
		for _, f := range []control.Fleet{f5, f4} {
			if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, "[]", time.Now().Add(time.Second)); err != nil {
				t.Fatal(err)
			}
		}
	}
	refresh()
	code, a := authorityCall(t, h, auth, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "freeze-empty", "expected_revision": 0, "legacy_tickets": "github"})
	if code != 200 {
		t.Fatalf("freeze: %d %v", code, a)
	}
	refresh()
	apply := map[string]any{"action": "apply", "idempotency_key": "apply-empty", "expected_revision": 1}
	code, a = authorityCall(t, h, auth, http.MethodPost, path, apply)
	if code != 200 || a["mode"] != "hub" {
		t.Fatalf("apply: %d %v", code, a)
	}
	code, again := authorityCall(t, h, auth, http.MethodPost, path, apply)
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
	path := FleetAuthorityPath + "?repo=" + writeRepo
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
		if code, out := authorityCall(t, h, auth, http.MethodPost, path, st.body); code != 200 || out["mode"] != st.mode {
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
	start := FleetAuthorityPath + "/start?repo=" + writeRepo
	worker := f5.FleetID + "/" + wrFid
	for _, step := range [][2]string{{"reserve", "held"}, {"reserve", "begun"}, {"begin", "begun"}, {"reserve", "gone"}, {"cancel", "gone"}} {
		code, out := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, start,
			map[string]any{"action": step[0], "reservation": step[1], "worker_id": worker})
		if code != 200 {
			t.Fatalf("%v %d %v", step, code, out)
		}
	}
	code, list := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, start+"&list=1", nil)
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
	if code, other := authorityCall(t, h, auth(h.tokens["mac-c"]), http.MethodGet, start+"&list=1", nil); code == 200 {
		if rows, _ := other["starts"].([]any); len(rows) != 0 {
			t.Fatal("another node read this node's starts", other)
		}
	}
	code, m := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodGet, FleetAuthorityPath+"?repo="+writeRepo, nil)
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
	path := FleetAuthorityPath + "?repo=" + writeRepo
	row, _ := h.srv.Store.Fleet(f4.FleetID)
	if _, err := h.srv.Store.RepoLocalStart(writeRepo, "operator", row.EndpointID, "left-open", "reserve", "", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	mentions := func(m map[string]any, s string) bool {
		b, _ := json.Marshal(map[string]any{"b": m["blockers"], "o": m["legacy_owners"], "n": m["nodes"]})
		return strings.Contains(string(b), s)
	}
	code, before := authorityCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || !mentions(before, f4.FleetID) || !mentions(before, "left-open") || len(before["retired_hosts"].([]any)) != 0 {
		t.Fatalf("before: %d %v", code, before)
	}
	res, err := h.srv.Store.RetireEndpointAs(row.EndpointID, "operator", "drill", time.Now())
	if err != nil || !res.Retired || res.Settled.Starts != 1 {
		t.Fatal(res, err)
	}
	code, after := authorityCall(t, h, auth, http.MethodGet, path, nil)
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
// blocks; another repo's manifest is the same person's, so the same.
func TestRepoAuthoritySupersededFleetRowBlocksNothing(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetAuthorityPath + "?repo=" + writeRepo
	other := FleetAuthorityPath + "?repo=example/other-repo"
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

	code, m := authorityCall(t, h, auth, http.MethodGet, path, nil)
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
	// The hosts are the person's, whichever repo the old road names
	// (claude-fleet#4896): another repo's manifest lists the same ones.
	_, otherM := authorityCall(t, h, auth, http.MethodGet, other, nil)
	for _, k := range []string{"blockers", "nodes", "retired_hosts", "superseded_hosts", "legacy_owners"} {
		if !reflect.DeepEqual(m[k], otherM[k]) {
			t.Fatalf("another repo's %s differs: %v → %v", k, m[k], otherM[k])
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
	old := store.FleetRow{FleetID: "a", MachineID: "m", EndpointID: "e", Repo: writeRepo, ObservedAt: now.Add(-time.Hour)}
	succ := store.FleetRow{FleetID: "b", MachineID: "m", EndpointID: "e", Repo: writeRepo, Present: true, ObservedAt: now}
	if g, ok := supersededBy(old, writeRepo, []store.FleetRow{old, succ}, eps); !ok || g.FleetID != "b" {
		t.Fatal("same machine, newer present row: superseded")
	}
	elsewhere := succ
	elsewhere.Repo = "example/other-repo"
	if _, ok := supersededBy(old, writeRepo, []store.FleetRow{old, elsewhere}, eps); ok {
		t.Fatal("a successor of another repo superseded it")
	}
	live := old
	live.Present = true
	if _, ok := supersededBy(live, writeRepo, []store.FleetRow{live, succ}, eps); ok {
		t.Fatal("a present row was superseded")
	}
	early := succ
	early.ObservedAt = now.Add(-2 * time.Hour)
	if _, ok := supersededBy(old, writeRepo, []store.FleetRow{old, early}, eps); ok {
		t.Fatal("a successor observed before the row superseded it")
	}
	absent := succ
	absent.Present = false
	if _, ok := supersededBy(old, writeRepo, []store.FleetRow{old, absent}, eps); ok {
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
	if _, ok := supersededBy(old, writeRepo, []store.FleetRow{old, gone}, retired); ok {
		t.Fatal("a retired successor superseded it")
	}
}

// An older node's init (claude-fleet#4885) selects nothing any more: it is
// refused, and the node's fallback gate read answers the person's own mode
// (claude-fleet#4896).
func TestRepoAuthorityAPIInitRefusedGateIsTheOwners(t *testing.T) {
	h, _, _, _, _ := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+h.tokens["mac-d"]) }
	body := map[string]any{"action": "init", "expected_revision": 0, "idempotency_key": "repo-init-new", "legacy_tickets": "hub"}
	if code, a := authorityCall(t, h, auth, http.MethodPost, FleetAuthorityPath+"?repo=acme/brand-new", body); code != 409 {
		t.Fatalf("init a new repo: %d %v", code, a)
	}
	code, g := authorityCall(t, h, auth, http.MethodGet, FleetAuthorityPath+"?repo=acme/brand-new&gate=1", nil)
	if code != 200 || g["mode"] != "legacy" || g["owner"] != "operator" {
		t.Fatalf("gate after a refused init: %d %v", code, g)
	}
	if after, _ := h.srv.Store.FleetSettings(); after["task-authority:acme/brand-new"] != "" || after["task-authority:owner:operator"] != "" {
		t.Fatal("a refused init wrote a selection", after)
	}
}

// BREAK-IT authority-other-owner-blocks + authority-owner-cutover
// (claude-fleet#4896): alice and bob both host writeRepo. alice drains her own
// legacy session (freeze · stop_ack · apply · rollback) while bob's legacy
// session and local start in the same repo neither block her nor are blocked;
// bob's gate stays legacy throughout and his hosts are never pushed.
func TestOwnerAuthorityTwoPeopleOneRepo(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	h.srv.FleetAdmins = []string{"frank"}
	for _, a := range []FleetAccountRequest{{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-a", Login: "alice"}, {Action: "adopt", PrincipalID: pBob, Hostname: "mac-b", Login: "bob"}} {
		if code := operatorPost(t, h, a); code != 200 {
			t.Fatalf("adopt %s: %d", a.Login, code)
		}
	}
	caps := []string{control.CapRead, control.CapWrite, control.CapLaunch, control.CapRepoAuthority}
	ta, tb := h.enroll(t, "mac-a"), h.enroll(t, "mac-b")
	na, nb := connectWriteNodeCaps(t, h, ta, caps...), connectWriteNodeCaps(t, h, tb, caps...)
	fa := fakeFleet(t, machineA, "fleet-a", writeRepo, "/u/alice/cf", 5)
	fb := fakeFleet(t, machineB, "fleet-b", writeRepo, "/u/bob/cf", 7)
	na.beatLoad("mac-a", "alice", machineA, 1, 1, fa)
	nb.beatLoad("mac-b", "bob", machineB, 1, 1, fb)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		fs, _ := h.srv.Store.Fleets()
		return len(fs) == 2
	})
	if o := h.srv.endpointOwner("ep_mac-a"); o != pAlice {
		t.Fatalf("mac-a's owner %q", o)
	}
	as := func(tok string) func(http.Header) {
		return func(hd http.Header) { hd.Set("Authorization", "Bearer "+tok) }
	}
	alice, bob := as(ta), as(tb)
	path, start := FleetAuthorityPath, FleetAuthorityPath+"/start?repo="+writeRepo
	call := func(who func(http.Header), method, p string, body map[string]any, want int) map[string]any {
		t.Helper()
		code, out := authorityCall(t, h, who, method, p, body)
		if code != want {
			t.Fatalf("%s %s: %d %v; want %d", method, p, code, out, want)
		}
		return out
	}
	refresh := func(f control.Fleet, workers string) {
		t.Helper()
		if err := h.srv.Store.UpdateFleetWorkers(f.FleetID, "running", 0, workers, time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	strs := func(v any) string { b, _ := json.Marshal(v); return string(b) }
	wa := fleetid.WorkerID(fa.FleetID, fleetid.WorkerKey(5, false, "", ""))
	wb := fleetid.WorkerID(fb.FleetID, fleetid.WorkerKey(7, false, "", ""))

	// bob keeps working on the legacy road in the same repo.
	call(bob, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "bob-1"}, 200)
	// alice's own session was launched (and observed) on the legacy road.
	native := map[string]any{"worker_id": wa, "native_session": "s-a", "pid": 55, "birth": "b-a", "executable": "/bin/claude"}
	call(alice, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "a-5"}, 200)
	call(alice, http.MethodPost, start, map[string]any{"action": "begin", "reservation": "a-5", "worker_id": wa}, 200)
	call(alice, http.MethodPost, start, map[string]any{"action": "observe", "reservation": "a-5", "worker_id": wa, "native_identity": native}, 200)

	m := call(alice, http.MethodGet, path, nil, 200)
	if b := strs(m["blockers"]); strings.Contains(b, wb) || strings.Contains(b, "bob-1") || strings.Contains(b, fb.FleetID) || !strings.Contains(b, "legacy execution: "+wa) {
		t.Fatalf("alice's blockers: %s", b)
	}
	if n := strs(m["nodes"]); strings.Contains(n, fb.FleetID) || !strings.Contains(n, fa.FleetID) {
		t.Fatalf("alice's hosts: %s", n)
	}
	if mb := call(bob, http.MethodGet, path, nil, 200); !strings.Contains(strs(mb["blockers"]), "legacy execution: "+wb) || !strings.Contains(strs(mb["blockers"]), "local start retained: bob-1") || strings.Contains(strs(mb["blockers"]), wa) {
		t.Fatalf("bob's blockers: %v", mb["blockers"])
	}
	// Only someone who sees every owner may read another's.
	call(alice, http.MethodGet, path+"?owner="+pBob, nil, 403)
	viewer := as(viewerToken)
	if mb := call(viewer, http.MethodGet, path+"?owner="+pBob, nil, 200); !strings.Contains(strs(mb["blockers"]), wb) {
		t.Fatalf("admin read of bob: %v", mb["blockers"])
	}

	// alice: freeze → her session stops → stop_ack → apply.
	a := call(alice, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "a-freeze", "expected_revision": 0}, 200)
	if a["mode"] != "frozen" || a["owner"] != pAlice {
		t.Fatal(a)
	}
	call(bob, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "bob-2"}, 200)
	call(alice, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "a-new"}, 409)
	call(alice, http.MethodPost, start, map[string]any{"action": "stopped", "reservation": "a-5", "worker_id": wa, "native_identity": native, "execution_stopped": true}, 200)
	evidence := map[string]any{"execution_stopped": true}
	for k, v := range native {
		evidence[k] = v
	}
	call(alice, http.MethodPost, path, map[string]any{"action": "stop_ack", "idempotency_key": "a-ack", "expected_revision": 1, "worker_id": wa, "evidence": strs(evidence)}, 200)
	refresh(fa, "[]")
	a = call(alice, http.MethodPost, path, map[string]any{"action": "apply", "idempotency_key": "a-apply", "expected_revision": 2}, 200)
	if a["mode"] != "hub" {
		t.Fatal(a)
	}
	if g := call(alice, http.MethodGet, FleetAuthorityPath+"?repo="+writeRepo+"&gate=1", nil, 200); g["mode"] != "hub" {
		t.Fatalf("alice's gate: %v", g)
	}
	if g := call(bob, http.MethodGet, path+"?gate=1", nil, 200); g["mode"] != "legacy" || g["revision"] != float64(0) {
		t.Fatalf("bob's gate moved with alice's: %v", g)
	}
	call(bob, http.MethodPost, start, map[string]any{"action": "begin", "reservation": "bob-2", "worker_id": wb}, 200)
	waitFor(t, 3*time.Second, "alice's host told", func() bool { return len(na.authorityPushes()) == 2 })
	if p := na.authorityPushes(); p[1] != (control.RepoAuthority{Repo: writeRepo, Mode: "hub", Revision: 3}) {
		t.Fatalf("alice's pushes: %v", p)
	}
	time.Sleep(100 * time.Millisecond)
	if p := nb.authorityPushes(); len(p) != 0 {
		t.Fatalf("bob's host was pushed alice's authority: %v", p)
	}

	// alice rolls back; bob was never asked.
	refresh(fa, "[]")
	call(alice, http.MethodPost, path, map[string]any{"action": "freeze", "idempotency_key": "a-freeze-2", "expected_revision": 3}, 200)
	refresh(fa, "[]")
	if a = call(alice, http.MethodPost, path+"?rollback=1", map[string]any{"action": "rollback", "idempotency_key": "a-back", "expected_revision": 4}, 200); a["mode"] != "legacy" {
		t.Fatal(a)
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action LIKE 'task_authority_%' AND fleet_id = ?`, "owner:"+pAlice).Scan(&n); err != nil || n != 5 {
		t.Fatalf("alice's audit rows %d %v", n, err)
	}
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'task_authority_read' AND fleet_id = ?`, "owner:"+pBob).Scan(&n); err != nil || n != 1 {
		t.Fatalf("the admin's read of bob is not audited: %d %v", n, err)
	}
	if b, _ := h.srv.Store.OwnerAuthority(pBob); b.Revision != 0 || b.Mode != "legacy" {
		t.Fatal("bob's authority moved", b)
	}
}

// claude-fleet#4886: a client runs no task, so a repo its inventory still
// lists is a leftover — its fleet row is listed under client_hosts and blocks
// nothing, the managed host stays, and the client may not reserve a start.
func TestRepoAuthorityClientHostBlocksNothing(t *testing.T) {
	h, _, _, f5, f4 := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(h http.Header) { h.Set("Authorization", "Bearer "+viewerToken) }
	path := FleetAuthorityPath + "?repo=" + writeRepo
	row, _ := h.srv.Store.Fleet(f4.FleetID)
	ws, _ := json.Marshal([]map[string]any{{"worker_id": f4.FleetID + "/old", "repo": writeRepo}})
	if err := h.srv.Store.UpdateFleetWorkers(f4.FleetID, "running", 1, string(ws), time.Now()); err != nil {
		t.Fatal(err)
	}
	mentions := func(m map[string]any, s string) bool {
		b, _ := json.Marshal(map[string]any{"b": m["blockers"], "o": m["legacy_owners"], "n": m["nodes"]})
		return strings.Contains(string(b), s)
	}
	code, before := authorityCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || !mentions(before, f4.FleetID) || len(before["client_hosts"].([]any)) != 0 {
		t.Fatalf("before: %d %v", code, before)
	}
	if err := h.srv.Store.SetEndpointRole(row.EndpointID, store.NodeRoleClient); err != nil {
		t.Fatal(err)
	}
	code, after := authorityCall(t, h, auth, http.MethodGet, path, nil)
	if code != 200 || mentions(after, f4.FleetID) || mentions(after, row.EndpointID) {
		t.Fatalf("a client host still blocks: %d %v", code, after)
	}
	clients := after["client_hosts"].([]any)
	if len(clients) != 1 || clients[0].(map[string]any)["fleet_id"] != f4.FleetID {
		t.Fatalf("client_hosts: %v", clients)
	}
	if !mentions(after, f5.FleetID) {
		t.Fatalf("the managed host vanished: %v", after)
	}
	start := FleetAuthorityPath + "/start?repo=" + writeRepo
	cauth := func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+h.tokens["mac-c"]) }
	if code, m := authorityCall(t, h, cauth, http.MethodPost, start, map[string]any{"action": "reserve", "reservation": "client-start"}); code != 403 || !strings.Contains(m["error"].(string), "客户端") {
		t.Fatalf("a client reserved a start: %d %v", code, m)
	}
}

// claude-fleet#4978: a stale worker_start its node never ran is abandoned by
// that node alone — listed only to its own login, refused while too young,
// refused to another node, then failed START_ABANDONED with one audit row; it
// no longer blocks its owner's cutover.
func TestAuthorityOperationNodeAbandonsStaleStart(t *testing.T) {
	h, _, _, f5, _ := twoNodesCaps(t, control.CapLaunch, control.CapRepoAuthority)
	auth := func(token string) func(http.Header) {
		return func(h http.Header) { h.Set("Authorization", "Bearer "+token) }
	}
	path := FleetAuthorityPath + "/operation"
	id := postFleet(t, h, "worker_start", map[string]any{"kind": "scratch", "fleet_id": f5.FleetID, "idempotency_key": "stale"}, 200)["operation_id"].(string)
	if err := h.srv.Store.UpdateFleetOperation(id, "running", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	listed := func(token string) bool {
		code, out := authorityCall(t, h, auth(token), http.MethodGet, path, nil)
		if code != 200 {
			t.Fatal(code, out)
		}
		for _, raw := range out["operations"].([]any) {
			if raw.(map[string]any)["operation_id"] == id {
				return true
			}
		}
		return false
	}
	if !listed(h.tokens["mac-d"]) || listed(h.tokens["mac-c"]) {
		t.Fatal("the start is listed to its own node only")
	}
	body := map[string]any{"operation_id": id, "local": "not_accepted"}
	if code, out := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, body); code != 409 || !strings.Contains(asJSON(out), "younger than") {
		t.Fatal("young", code, out)
	}
	old := abandonAge
	abandonAge = 0
	t.Cleanup(func() { abandonAge = old })
	if code, _ := authorityCall(t, h, auth(h.tokens["mac-c"]), http.MethodPost, path, body); code != 404 {
		t.Fatal("another node abandoned it", code)
	}
	if code, _ := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, map[string]any{"operation_id": id, "local": "running"}); code != 400 {
		t.Fatal("a node that ran it may not abandon it", code)
	}
	if code, _ := authorityCall(t, h, auth(viewerToken), http.MethodPost, path, body); code != 403 {
		t.Fatal("only its node abandons a start", code)
	}
	code, out := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, body)
	e, _ := out["result"].(map[string]any)["error"].(map[string]any)
	if code != 200 || out["status"] != "failed" || e["code"] != "START_ABANDONED" || e["prior_status"] != "running" || e["local"] != "not_accepted" {
		t.Fatal("abandon", code, out)
	}
	if code, _ := authorityCall(t, h, auth(h.tokens["mac-d"]), http.MethodPost, path, body); code != 409 {
		t.Fatal("abandoned twice", code)
	}
	log, err := h.srv.Store.FleetAuditLog(50)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range log {
		if a.Action == "operation_abandon" && a.OperationID == id && strings.HasPrefix(a.Actor, "node:") && strings.Contains(a.Outcome, "local=not_accepted") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no operation_abandon audit row: %+v", log)
	}
	blockers, _, err := h.srv.Store.OwnerAuthorityBlockers("operator", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.Join(blockers, "|"), "unsettled start: "+id) {
		t.Fatal("still blocks", blockers)
	}
}
