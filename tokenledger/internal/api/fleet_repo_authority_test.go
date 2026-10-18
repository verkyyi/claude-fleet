package api

import (
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
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
