package api

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// A release goes to ONE machine first (claude-fleet#4915).

// canaryRig: a hub with a release store, stable shaA #1 promoted long ago, and
// a manifest for shaB naming shaA as its prev.
type canaryRig struct {
	h   *harness
	rs  *ReleaseStore
	hb  func(host string, v *control.Versions) control.Heartbeat
	now time.Time
}

func newCanaryRig(t *testing.T) *canaryRig {
	t.Helper()
	h := newFleetHarness(t)
	rs := &ReleaseStore{Dir: t.TempDir()}
	h.srv.Releases = rs
	setStable(t, rs, shaA, 1)
	old := time.Now().Add(-time.Hour)
	must(t, os.Chtimes(filepath.Join(rs.Dir, releaseStable), old, old))
	id := "b2-" + shaB[:12]
	must(t, os.MkdirAll(filepath.Join(rs.Dir, shaB, id), 0o755))
	must(t, os.WriteFile(filepath.Join(rs.Dir, shaB, releaseCurrent), []byte(id+"\n"), 0o644))
	mb, _ := json.Marshal(release.Manifest{Prev: shaA, Seq: 2})
	must(t, os.WriteFile(filepath.Join(rs.Dir, shaB, id, release.ManifestName), mb, 0o644))
	return &canaryRig{h: h, rs: rs, now: time.Now(),
		hb: func(host string, v *control.Versions) control.Heartbeat {
			at := time.Now().UTC()
			return control.Heartbeat{Hostname: host, OSUser: "root", Versions: v, VersionsAt: &at}
		}}
}

func (r *canaryRig) setting(t *testing.T, k, v string) {
	t.Helper()
	must(t, r.h.srv.Store.SetFleetSetting(k, v, time.Now()))
}

func (r *canaryRig) hold(t *testing.T) (releaseHold, bool) {
	t.Helper()
	s, err := r.h.srv.Store.FleetSettings()
	must(t, err)
	return parseHold(s[releaseHoldKey])
}

// promoteB moves stable to shaB #2 now and tells the links, as a promote does.
func (r *canaryRig) promoteB(t *testing.T) {
	t.Helper()
	setStable(t, r.rs, shaB, 2)
	r.h.srv.BroadcastRelease(shaB, 2)
}

// waitHold ticks the gate until the record reads state (or fails).
func (r *canaryRig) waitHold(t *testing.T, state string) releaseHold {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		r.h.srv.releaseGateTick(time.Now())
		if h, ok := r.hold(t); ok && h.State == state {
			return h
		}
		if time.Now().After(deadline) {
			h, _ := r.hold(t)
			t.Fatalf("hold never reached %s: %+v", state, h)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func canaryLinks(t *testing.T, r *canaryRig) (k, o *websocket.Conn) {
	t.Helper()
	tokK, tokO := r.h.enroll(t, "k"), r.h.enroll(t, "o")
	k = teamNode(t, r.h, tokK, control.CapMachine, control.CapRelease)
	o = teamNode(t, r.h, tokO, control.CapMachine, control.CapRelease)
	beat(t, k, control.Proto, r.hb("mini2.local", &control.Versions{Runtime: shaA}))
	nextRelease(t, k, shaA, 1, "canary's first beat: the old stable, not held")
	beat(t, o, control.Proto, r.hb("mac-d", &control.Versions{Runtime: shaA}))
	nextRelease(t, o, shaA, 1, "other's first beat")
	return k, o
}

func TestReleaseCanaryPassesThenAll(t *testing.T) {
	r := newCanaryRig(t)
	r.setting(t, ReleaseCanaryKey, "mini2")
	k, o := canaryLinks(t, r)

	r.promoteB(t)
	nextRelease(t, k, shaB, 2, "the canary hears the new stable at once")
	v := r.h.srv.releaseGate(time.Now())
	if got := v.forMachine("mac-d").SHA; got != shaA {
		t.Fatalf("another machine is handed %.7s while the canary checks, want %.7s", got, shaA)
	}
	if got := v.forMachine("").SHA; got != shaA {
		t.Fatalf("an unnamed follower is handed %.7s, want %.7s", got, shaA)
	}
	if got := v.forMachine("MINI2").SHA; got != shaB {
		t.Fatalf("the canary is handed %.7s, want %.7s", got, shaB)
	}
	h := r.waitHold(t, holdCanary)
	if h.Prev != shaA || h.PrevSeq != 1 || h.Canary != "mini2" {
		t.Fatalf("hold %+v", h)
	}
	r.h.srv.releaseGateTick(time.Now())

	// switched + doctor PASS: everyone gets it
	beat(t, k, control.Proto, r.hb("mini2.local", &control.Versions{Runtime: shaB, Update: &control.UpdateState{Result: "committed"}}))
	r.waitHold(t, holdReleased)
	nextRelease(t, o, shaB, 2, "released: the rest hear it")
	if got := r.h.srv.releaseGate(time.Now()).forMachine("mac-d").SHA; got != shaB {
		t.Fatalf("after the canary passed another machine is handed %.7s", got)
	}
	silent(t, k, "the canary is not told twice")
}

func TestReleaseCanaryRollbackBlocks(t *testing.T) {
	r := newCanaryRig(t)
	r.setting(t, ReleaseCanaryKey, "mini2")
	notes := make(chan string, 8)
	r.h.srv.Notify = func(m string) { notes <- m }
	k, o := canaryLinks(t, r)

	r.promoteB(t)
	nextRelease(t, k, shaB, 2, "canary")
	r.waitHold(t, holdCanary)
	beat(t, k, control.Proto, r.hb("mini2.local", &control.Versions{Runtime: shaA,
		Update: &control.UpdateState{Result: "rolled-back", Reason: shaB[:12] + " → back to " + shaA[:12] + ": doctor: new FAIL install"}}))
	h := r.waitHold(t, holdBlocked)
	if h.Reason == "" {
		t.Fatal("a blocked hold says no why")
	}
	for _, m := range []string{"mac-d", "mini2", ""} {
		if got := r.h.srv.releaseGate(time.Now()).forMachine(m).SHA; got != shaA {
			t.Fatalf("blocked: %q is handed %.7s, want the old %.7s", m, got, shaA)
		}
	}
	// past the canary's window it stays blocked
	if got := r.h.srv.releaseGate(time.Now().Add(time.Hour)).forMachine("mac-d").SHA; got != shaA {
		t.Fatalf("a blocked release reaches others later: %.7s", got)
	}
	hl := r.h.srv.releaseHealth(shaB, time.Now().Add(-time.Minute), time.Now())
	rb, _ := hl["rolled_back"].([]machineWord)
	if len(rb) != 1 || !sameMachine(rb[0].Machine, "mini2") {
		t.Fatalf("health rolled_back = %+v", hl["rolled_back"])
	}
	if hh, _ := hl["hold"].(releaseHold); hh.State != holdBlocked {
		t.Fatalf("health hold = %+v", hl["hold"])
	}
	silent(t, o, "the rest never hear the blocked release")
	saw := false
	for len(notes) > 0 {
		if m := <-notes; contains(m, "被金丝雀拦住") {
			saw = true
		}
	}
	if !saw {
		t.Fatal("nobody was told the canary stopped it")
	}
}

func TestReleaseCanaryQuietReleasesAfterWait(t *testing.T) {
	old := releaseCanaryWait
	releaseCanaryWait = 600 * time.Millisecond
	t.Cleanup(func() { releaseCanaryWait = old })
	r := newCanaryRig(t)
	r.setting(t, ReleaseCanaryKey, "mini2")
	k, o := canaryLinks(t, r)
	r.promoteB(t)
	nextRelease(t, k, shaB, 2, "canary")
	r.waitHold(t, holdCanary)
	time.Sleep(releaseCanaryWait)
	h := r.waitHold(t, holdReleased)
	if !contains(h.Reason, "没回话") {
		t.Fatalf("released for %q, want the canary's silence", h.Reason)
	}
	nextRelease(t, o, shaB, 2, "a quiet canary never stops a release")
}

func TestReleaseCanaryOfflineReleasesAtOnce(t *testing.T) {
	r := newCanaryRig(t)
	r.setting(t, ReleaseCanaryKey, "nowhere")
	tok := r.h.enroll(t, "o")
	o := teamNode(t, r.h, tok, control.CapMachine, control.CapRelease)
	beat(t, o, control.Proto, r.hb("mac-d", &control.Versions{Runtime: shaA}))
	nextRelease(t, o, shaA, 1, "first beat")
	r.promoteB(t)
	h := r.waitHold(t, holdReleased)
	if !contains(h.Reason, "不在线") {
		t.Fatalf("released for %q", h.Reason)
	}
	nextRelease(t, o, shaB, 2, "no canary to wait for")
}

// TestReleaseCanaryOffAddsNothing: no fleet.release_canary ⇒ a promote reaches
// every link at once, the gate holds nothing and writes no record.
func TestReleaseCanaryOffAddsNothing(t *testing.T) {
	r := newCanaryRig(t)
	tok := r.h.enroll(t, "o")
	o := teamNode(t, r.h, tok, control.CapMachine, control.CapRelease)
	beat(t, o, control.Proto, r.hb("mac-d", nil))
	nextRelease(t, o, shaA, 1, "first beat")
	r.promoteB(t)
	nextRelease(t, o, shaB, 2, "no canary: at once")
	r.h.srv.releaseGateTick(time.Now())
	if v := r.h.srv.releaseGate(time.Now()); v.holding {
		t.Fatalf("no canary but holding %+v", v)
	}
	if h, ok := r.hold(t); ok {
		t.Fatalf("no canary but a record %+v", h)
	}
	if _, ok := r.h.srv.followerStable("mac-d"); ok {
		t.Fatal("followerStable overrides with no canary")
	}
}

func TestHTTPStatsCounts5xx(t *testing.T) {
	var s httpStats
	now := time.Now()
	for _, c := range []int{200, 200, 500, 503, 404, 502} {
		s.add(c, now)
	}
	s.add(500, now.Add(-2*time.Hour)) // forgotten
	total, errs := s.since(now.Add(-time.Minute))
	if total != 6 || errs != 3 {
		t.Fatalf("since a minute ago: %d total %d 5xx, want 6 / 3", total, errs)
	}
	if total, _ := s.since(now.Add(time.Hour)); total != 0 {
		t.Fatalf("since the future: %d", total)
	}
}
