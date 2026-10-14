package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4060 (EPIC #4048 C12): a trial's machine goes back fast — the
// page hidden 2 minutes, no input 4 (warned at 3), the trial's limit — and its
// conversation is kept apart, sealed to that one person, for 24 hours; back
// again, a clean login is handed out with their own conversation in it.

// fakeConvos stands in for the logins' conversation services: what each
// machine/login holds, every export and import.
type fakeConvos struct {
	mu      sync.Mutex
	held    map[string][]byte // machine/login → its conversation
	exports []string
	imports []string // machine/login ← person
}

func (f *fakeConvos) Export(_ context.Context, person, machine, login string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.exports = append(f.exports, machine+"/"+login)
	if b := f.held[machine+"/"+login]; b != nil {
		return b, nil
	}
	return []byte(`{"v":1,"home":"/Users/x","sessions":[]}`), nil
}

func (f *fakeConvos) Import(_ context.Context, person, machine, login string, bundle []byte) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.held[machine+"/"+login] != nil {
		return errConvoTaken
	}
	f.held[machine+"/"+login] = bundle
	f.imports = append(f.imports, machine+"/"+login+"←"+person)
	return nil
}

func convoOf(person, words string) []byte {
	b, _ := json.Marshal(map[string]any{"v": 1, "home": "/Users/" + person,
		"sessions": []map[string]string{{"id": "s1", "cwd": "/Users/" + person, "jsonl": words}}})
	return b
}

// trialSlotHarness: the trial on, spares on mac-d, a vault, the fake
// conversation services.
func trialSlotHarness(t *testing.T, spares int) (*harness, *fleetNode, *fakeConvos) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h)
	setHubSetting(t, h.srv, TrialKey, "on")
	// mac-d: separated logins, and it washes what is given back (#3504).
	h.srv.FleetAdmins = []string{"ivan"}
	node := connectCaps(t, h, "mac-d-op", "mac-d", "ivan", true, control.CapCredsep, control.CapRecycle)
	beatCount(t, node, "mac-d", "ivan", 1)
	waitFor(t, 3*time.Second, "mac-d on the roster", func() bool { return h.srv.leastBusyMachine(time.Now()) == "mac-d" })
	sparesOn(t, h, strconv.Itoa(spares))
	openSpares(t, node, spares, control.CredsepSeparated)
	readySpares(t, h, "mac-d", spares)
	sealer, err := credvault.NewSealer(bytes.Repeat([]byte{9}, 32))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Vault = &credvault.Vault{Store: h.srv.Store, Sealer: sealer, Refresher: &stubRefresher{}}
	f := &fakeConvos{held: map[string][]byte{}}
	h.srv.trialConvoIO = f
	return h, node, f
}

// seat hands pid a spare on mac-d at now, with their home on it; the login.
func seat(t *testing.T, h *harness, pid string, now time.Time) string {
	t.Helper()
	if got := h.srv.claimSpares(pid, pid, pid, []string{"mac-d"}, now); len(got) != 1 {
		t.Fatalf("claim for %s = %v", pid, got)
	}
	if err := h.srv.Store.PlaceTrial(pid, "mac-d", now); err != nil {
		t.Fatal(err)
	}
	a := accountState(t, h, pid, "mac-d")
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pid, Machine: "mac-d", Login: a.Login, SetBy: "test", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	return a.Login
}

// The three lines, each in its time: hidden after 120 s with no beat, idle
// after 240 s with no input (warned from 180 s, the warning on the beat), the
// cap at 900 s of machine time across seats. Each is a trial.release with its
// reason, the login given back, the seat free at once.
func TestTrialSlotReleasesOnTime(t *testing.T) {
	h, _, _ := trialSlotHarness(t, 3)
	t0 := time.Now().Add(-time.Hour).Truncate(time.Second)
	const hidden, idle, capped = "gh:8101", "gh:8102", "gh:8103"
	for _, p := range []string{hidden, idle, capped} {
		if err := h.srv.Store.StartTrial(p, t0); err != nil {
			t.Fatal(err)
		}
		seat(t, h, p, t0)
	}
	// idle and capped keep beating; capped keeps typing.
	beatAt := func(p string, at time.Time, input time.Time) beatAnswer {
		t.Helper()
		a, err := h.srv.tryBeat(p, input, at)
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	for s := 30; s <= 119; s += 30 {
		at := t0.Add(time.Duration(s) * time.Second)
		beatAt(idle, at, time.Time{})
		beatAt(capped, at, at)
	}
	h.srv.SweepTrialSlots(t0.Add(119 * time.Second))
	if n, _ := h.srv.Store.TrialsHolding(); n != 3 {
		t.Fatalf("holding at 119 s = %d; want all 3", n)
	}
	h.srv.SweepTrialSlots(t0.Add(121 * time.Second))
	if tr, _ := h.srv.Store.Trial(hidden); tr.State != store.TrialReclaimed || tr.EndedReason != trialReleaseHidden {
		t.Fatalf("no beat for 121 s: %+v; want released, hidden", tr)
	}
	if a := accountState(t, h, hidden, "mac-d"); a.State == store.AccountActive {
		t.Fatalf("hidden trial's login still theirs: %+v", a)
	}
	if !auditHas(mustAudit(t, h), "trial.release", "ok", "reason=hidden") {
		t.Errorf("no trial.release reason=hidden audit")
	}
	if n, _ := h.srv.Store.TrialsHolding(); n != 2 {
		t.Fatalf("holding after the release = %d; want the seat free at once", n)
	}

	for s := 150; s <= 179; s += 29 {
		at := t0.Add(time.Duration(s) * time.Second)
		beatAt(idle, at, time.Time{})
		beatAt(capped, at, at)
	}
	h.srv.SweepTrialSlots(t0.Add(181 * time.Second))
	if a := beatAt(idle, t0.Add(182*time.Second), time.Time{}); !a.Warn || a.PauseIn < 50 || a.PauseIn > 60 {
		t.Fatalf("no input for 182 s: beat = %+v; want warned, about a minute left", a)
	}
	if a := beatAt(capped, t0.Add(182*time.Second), t0.Add(182*time.Second)); a.Warn || a.State != "placed" {
		t.Fatalf("a typing trial's beat = %+v; want placed, no warning", a)
	}
	h.srv.SweepTrialSlots(t0.Add(239 * time.Second))
	if tr, _ := h.srv.Store.Trial(idle); tr.State != store.TrialPlaced {
		t.Fatalf("released before 240 s: %+v", tr)
	}
	beatAt(idle, t0.Add(240*time.Second), time.Time{})
	h.srv.SweepTrialSlots(t0.Add(241 * time.Second))
	if tr, _ := h.srv.Store.Trial(idle); tr.State != store.TrialReclaimed || tr.EndedReason != trialReleaseIdle || tr.UsedSecs != 241 {
		t.Fatalf("no input for 241 s: %+v; want released, idle, 241 s used", tr)
	}
	if a := beatAt(idle, t0.Add(242*time.Second), time.Time{}); a.State != "released" || a.Reason != trialReleaseIdle || a.Next != TryPagePath {
		t.Fatalf("the released page's beat = %+v; want released → /app/try", a)
	}

	// Input after the warning clears it.
	for s := 270; s <= 899; s += 30 {
		at := t0.Add(time.Duration(s) * time.Second)
		beatAt(capped, at, at)
	}
	h.srv.SweepTrialSlots(t0.Add(899 * time.Second))
	if tr, _ := h.srv.Store.Trial(capped); tr.State != store.TrialPlaced || !tr.WarnedAt.IsZero() {
		t.Fatalf("a busy trial at 899 s: %+v; want placed, not warned", tr)
	}
	h.srv.SweepTrialSlots(t0.Add(900 * time.Second))
	if tr, _ := h.srv.Store.Trial(capped); tr.State != store.TrialReclaimed || tr.EndedReason != trialEndTime {
		t.Fatalf("900 s used: %+v; want released, cap", tr)
	}
	// Capped is the end of it: 「已试过」, pointed at /apply.
	if a, err := h.srv.tryClaim(capped, "", t0.Add(901*time.Second)); err != nil || a.State != "tried" || a.Reason != trialEndTime {
		t.Fatalf("a capped trial's claim = %+v, %v; want tried (cap)", a, err)
	}
}

// Back after a pause: 「已暂停」 until 继续, then a clean login with their own
// conversation in it; the time used carries over, so the cap counts every seat.
func TestTrialPauseAndResumeCarriesTheConversation(t *testing.T) {
	h, _, f := trialSlotHarness(t, 2)
	t0 := time.Now().Add(-110 * time.Second).Truncate(time.Second) // 继续 comes now: the roster reads beats at now
	const p = "gh:8201"
	if err := h.srv.Store.StartTrialAs(p, store.IdentityGitHub, "8201", t0); err != nil {
		t.Fatal(err)
	}
	first := seat(t, h, p, t0)
	f.held["mac-d/"+first] = convoOf(p, "甲的青蛙")
	if err := h.srv.trialRelease(p, trialReleasePause, t0.Add(100*time.Second)); err != nil {
		t.Fatal(err)
	}
	c, err := h.srv.Store.TrialConvo(p, t0.Add(101*time.Second))
	if err != nil || c == nil {
		t.Fatalf("kept conversation = %v, %v; want one", c, err)
	}
	if bytes.Contains(c.Sealed, []byte("甲的青蛙")) {
		t.Fatal("the kept conversation is stored in the clear")
	}
	if !c.ExpiresAt.Equal(t0.Add(100*time.Second + trialConvoKeep)) {
		t.Fatalf("kept until %s; want 24 h after the release", c.ExpiresAt)
	}
	if !auditHas(mustAudit(t, h), "trial.release", "ok", "reason=pause convo=kept") {
		t.Errorf("no trial.release reason=pause convo=kept audit")
	}
	at := t0.Add(110 * time.Second)
	a, err := h.srv.tryClaimAs(p, "", false, at)
	if err != nil || a.State != "paused" || a.LeftSecs != 800 || a.KeptUntil != c.ExpiresAt.Unix() {
		t.Fatalf("a paused trial's look = %+v, %v; want paused, 800 s left, kept 24 h", a, err)
	}
	if tr, _ := h.srv.Store.Trial(p); tr.State != store.TrialReclaimed {
		t.Fatalf("a look moved the trial: %+v", tr)
	}
	// 继续: one trial, even with fleet.trial.once on — back in line, seated.
	a, err = h.srv.tryClaimAs(p, "", true, at)
	if err != nil || (a.State != "ready" && a.State != "opening") {
		t.Fatalf("继续 = %+v, %v; want a seat", a, err)
	}
	tr, _ := h.srv.Store.Trial(p)
	second := accountState(t, h, p, "mac-d").Login
	if tr.State != store.TrialPlaced || second == "" {
		t.Fatalf("after 继续: %+v on %q; want placed", tr, second)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: p, Machine: "mac-d", Login: second, SetBy: "test", SetAt: at}); err != nil {
		t.Fatal(err)
	}
	a, err = h.srv.tryHome(p, at)
	if err != nil || a.State != "ready" || !a.Resumed || a.LeftSecs != 800 {
		t.Fatalf("the new seat = %+v, %v; want ready, resumed, 800 s left", a, err)
	}
	if got := string(f.held["mac-d/"+second]); !strings.Contains(got, "甲的青蛙") {
		t.Fatalf("the new login holds %q; want the person's own conversation", got)
	}
	// Once per seat.
	if a, _ := h.srv.tryHome(p, at.Add(time.Second)); a.Resumed || len(f.imports) != 1 {
		t.Fatalf("seeded twice: %+v, imports %v", a, f.imports)
	}
	if !auditHas(mustAudit(t, h), "trial.resume", "ok", "mac-d/"+second) {
		t.Errorf("no trial.resume audit")
	}
	// The cap counts every seat: 100 s before, 800 s now.
	_, _ = h.srv.tryBeat(p, at.Add(798*time.Second), at.Add(798*time.Second))
	h.srv.SweepTrialSlots(at.Add(799 * time.Second))
	if tr, _ := h.srv.Store.Trial(p); tr.State != store.TrialPlaced {
		t.Fatalf("released at 899 s used: %+v", tr)
	}
	h.srv.SweepTrialSlots(at.Add(800 * time.Second))
	if tr, _ := h.srv.Store.Trial(p); tr.EndedReason != trialEndTime {
		t.Fatalf("900 s across two seats: %+v; want released, cap", tr)
	}
}

// BREAK-IT trial-transcript-cross: A's conversation is sealed to A — it does
// not open as B, B's seat is seeded with nothing of A's, and there is no read
// by id: every road takes the session's own principal.
func TestTrialConvoNeverCrosses(t *testing.T) {
	h, _, f := trialSlotHarness(t, 3)
	t0 := time.Now().Truncate(time.Second)
	const a, b = "gh:8301", "gh:8302"
	for _, p := range []string{a, b} {
		if err := h.srv.Store.StartTrial(p, t0); err != nil {
			t.Fatal(err)
		}
	}
	la := seat(t, h, a, t0)
	f.held["mac-d/"+la] = convoOf(a, "甲的秘密")
	if err := h.srv.trialRelease(a, trialReleaseHidden, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	c, _ := h.srv.Store.TrialConvo(a, t0.Add(time.Minute))
	if c == nil {
		t.Fatal("A's conversation was not kept")
	}
	var out json.RawMessage
	if err := h.srv.Vault.OpenPerson(c.Sealed, &out, b, trialConvoPurpose); err == nil {
		t.Fatal("A's conversation opened as B")
	}
	if err := h.srv.Vault.OpenPerson(c.Sealed, &out, a, trialConvoPurpose); err != nil || !strings.Contains(string(out), "甲的秘密") {
		t.Fatalf("A's conversation does not open as A: %v", err)
	}
	// Planted on B's row, it still opens only as A — and B's seat gets nothing.
	if err := h.srv.Store.PutTrialConvo(b, c.Sealed, t0.Add(time.Hour), t0); err != nil {
		t.Fatal(err)
	}
	lb := seat(t, h, b, t0.Add(2*time.Minute))
	tb, _ := h.srv.Store.Trial(b)
	if resumed, done := h.srv.trialSeed(tb, t0.Add(2*time.Minute)); resumed || !done {
		t.Fatalf("B's seat seeded = %v/%v; want nothing", resumed, done)
	}
	if got := f.held["mac-d/"+lb]; got != nil {
		t.Fatalf("B's login holds %s", got)
	}
	// The only routes: the session's own beat, pause and claim.
	for _, p := range []string{TryBeatPath, TryPausePath, TryClaimPath} {
		code, _, _ := tryDo(t, h, http.MethodPost, p+"?principal="+a+"&person="+a, b, map[string]any{})
		if code != http.StatusOK {
			t.Fatalf("POST %s as B = %d", p, code)
		}
	}
	if tr, _ := h.srv.Store.Trial(a); tr.State != store.TrialReclaimed {
		t.Fatalf("B's pause moved A's trial: %+v", tr)
	}
}

// The kept conversations go 24 hours on, ciphertext and all.
func TestTrialConvosPurgedAfterADay(t *testing.T) {
	h, _, f := trialSlotHarness(t, 1)
	t0 := time.Now().Truncate(time.Second)
	const p = "gh:8401"
	if err := h.srv.Store.StartTrial(p, t0); err != nil {
		t.Fatal(err)
	}
	f.held["mac-d/"+seat(t, h, p, t0)] = convoOf(p, "hello")
	if err := h.srv.trialRelease(p, trialReleaseIdle, t0); err != nil {
		t.Fatal(err)
	}
	h.srv.SweepTrialSlots(t0.Add(trialConvoKeep - time.Minute))
	if c, _ := h.srv.Store.TrialConvo(p, t0.Add(trialConvoKeep-time.Minute)); c == nil {
		t.Fatal("purged before 24 h")
	}
	h.srv.trialSlotSt.purgedAt = time.Time{}
	h.srv.SweepTrialSlots(t0.Add(trialConvoKeep + time.Second))
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM hub_trial_convos WHERE principal = ?`, p).Scan(&n); err != nil || n != 0 {
		t.Fatalf("rows after 24 h = %d, %v; want the row gone", n, err)
	}
	// And a trial past its day is no longer paused: 「已试过」.
	if a, _ := h.srv.tryClaim(p, "", t0.Add(trialConvoKeep+time.Minute)); a.State != "tried" {
		t.Fatalf("a day later = %+v; want tried", a)
	}
}

// BREAK-IT trial-dirty-handout: a trial's login released by the patrol goes
// through #3504's wash; an answer that is not clean fails it — never a spare,
// never handed to the next person — and a clean one makes it a spare again.
func TestTrialReleaseWashesBeforeTheNext(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h)
	admin := recycleFleet(t, h)
	sparesOn(t, h, "2")
	setHubSetting(t, h.srv, TrialKey, "on")
	h.srv.trialConvoIO = &fakeConvos{held: map[string][]byte{}}
	t0 := time.Now().Truncate(time.Second)
	for i, c := range []struct {
		res   control.AccountResult
		state string
	}{
		{control.AccountResult{OK: true, Reset: "dirty crontab", Credsep: control.CredsepSeparated}, store.AccountFailed},
		{control.AccountResult{OK: true, Reset: control.ResetClean, Credsep: control.CredsepSeparated}, ""},
	} {
		p, login := "gh:85"+string(rune('0'+i)), "trialwash"+string(rune('a'+i))
		openLogin(t, h, admin, p, login)
		if err := h.srv.Store.StartTrial(p, t0); err != nil {
			t.Fatal(err)
		}
		if err := h.srv.Store.PlaceTrial(p, "m8", t0); err != nil {
			t.Fatal(err)
		}
		h.srv.SweepTrialSlots(t0.Add(3 * time.Minute))
		m, op := expectAccountOp(t, admin.tnode)
		if op.Op != control.AccountReset || op.Login != login {
			t.Fatalf("op = %+v; want the reset of %s", op, login)
		}
		c.res.Op, c.res.Login = control.AccountReset, login
		sendResult(t, admin.c, m.OpID, c.res)
		// The person is free of it at once: the wash goes on under a spare
		// holder, and their home on it is gone.
		if as := mustAccounts(t, h, p); len(as) != 0 {
			t.Fatalf("the released person still holds %+v", as)
		}
		if _, ok, _ := h.srv.Store.EntryHomeOf(p); ok {
			t.Fatal("the released person's home still points at the washing login")
		}
		if c.state == store.AccountFailed {
			waitFor(t, 3*time.Second, login+" to be failed", func() bool {
				for _, sp := range mustSpares(t, h) {
					if sp.Login == login && sp.State == store.AccountFailed && strings.Contains(sp.Detail, "not handed out") {
						return true
					}
				}
				return false
			})
			for _, sp := range mustSpares(t, h) {
				if sp.Login == login && sp.State == store.AccountActive {
					t.Fatalf("a dirty wash became a ready spare: %+v", sp)
				}
			}
			continue
		}
		waitFor(t, 3*time.Second, login+" to be a spare", func() bool {
			for _, sp := range mustSpares(t, h) {
				if sp.Login == login && sp.State == store.AccountActive {
					return true
				}
			}
			return false
		})
	}
}

// C11's two stubs (claude-fleet#4059): an approved person's kept conversation
// goes into their new home, and their request starts with what they first
// asked — their own words, never the relay's or the browser's line.
func TestTrialConvoCarriedOnApprovalAndFirstWords(t *testing.T) {
	h, _, f := trialSlotHarness(t, 2)
	t0 := time.Now().Truncate(time.Second)
	const p = "gh:8601"
	if err := h.srv.Store.StartTrial(p, t0); err != nil {
		t.Fatal(err)
	}
	login := seat(t, h, p, t0)
	jsonl := `{"type":"user","message":{"role":"user","content":"<fleet-webchat-context>手机 · 上海</fleet-webchat-context>\n\n把上周的销售数据整理成看板"}}` + "\n" +
		`{"type":"assistant","message":{"content":[{"type":"text","text":"好的"}]}}` + "\n"
	b, _ := json.Marshal(map[string]any{"v": 1, "home": "/Users/x", "sessions": []map[string]string{{"id": "s1", "cwd": "/Users/x", "jsonl": jsonl}}})
	f.held["mac-d/"+login] = b
	// While the seat is live: read off the seat.
	if got := h.srv.trialFirstWords(p); got != "把上周的销售数据整理成看板" {
		t.Fatalf("first words from the seat = %q", got)
	}
	if err := h.srv.trialRelease(p, trialReleaseIdle, t0.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	delete(f.held, "mac-d/"+login)
	// Kept apart: read off the kept one.
	if got := h.srv.trialFirstWords(p); got != "把上周的销售数据整理成看板" {
		t.Fatalf("first words from the kept conversation = %q", got)
	}
	if got := h.srv.trialFirstWords("gh:8699"); got != "" {
		t.Fatalf("someone else's first words = %q; want none", got)
	}
	// Approved, placed as a member: no home yet — nothing, tried again later;
	// then their home — the conversation goes in, once.
	h.srv.seedKeptConvo(p, t0.Add(2*time.Minute))
	if len(f.imports) != 0 {
		t.Fatalf("imported with no home: %v", f.imports)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: p, Machine: "mac-d", Login: "fleetu9", SetBy: "test", SetAt: t0}); err != nil {
		t.Fatal(err)
	}
	h.srv.seedKeptConvo(p, t0.Add(3*time.Minute))
	h.srv.seedKeptConvo(p, t0.Add(4*time.Minute))
	if len(f.imports) != 1 || f.imports[0] != "mac-d/fleetu9←"+p {
		t.Fatalf("imports = %v; want the one into their home", f.imports)
	}
}
