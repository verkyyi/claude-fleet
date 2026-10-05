package api

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/findings"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/model"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// fakeRobot is a WeCom group robot: it records every markdown content it is
// sent and answers like the real one.
type fakeRobot struct {
	mu   sync.Mutex
	got  []string
	fail bool
	ts   *httptest.Server
}

func newFakeRobot(t *testing.T) *fakeRobot {
	r := &fakeRobot{}
	r.ts = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		raw, _ := io.ReadAll(req.Body)
		var m struct {
			Msgtype  string `json:"msgtype"`
			Markdown struct {
				Content string `json:"content"`
			} `json:"markdown"`
		}
		if err := json.Unmarshal(raw, &m); err != nil || m.Msgtype != "markdown" {
			w.WriteHeader(400)
			return
		}
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.fail {
			w.WriteHeader(500)
			return
		}
		r.got = append(r.got, m.Markdown.Content)
		w.Write([]byte(`{"errcode":0,"errmsg":"ok"}`))
	}))
	t.Cleanup(r.ts.Close)
	return r
}

func (r *fakeRobot) messages() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.got...)
}

func (r *fakeRobot) notifier(repeat time.Duration) *FindingNotifier {
	return &FindingNotifier{Webhook: r.ts.URL + "/cgi-bin/webhook/send?key=SECRET-KEY", Repeat: repeat,
		HubURL: "https://hub.example", Locale: "zh-CN", Client: r.ts.Client()}
}

func wantMessages(t *testing.T, r *fakeRobot, n int, lastContains ...string) {
	t.Helper()
	got := r.messages()
	if len(got) != n {
		t.Fatalf("messages = %d, want %d:\n%s", len(got), n, strings.Join(got, "\n---\n"))
	}
	if n == 0 {
		return
	}
	t.Logf("robot got:\n%s", got[n-1])
	for _, s := range lastContains {
		if !strings.Contains(got[n-1], s) {
			t.Fatalf("last message lacks %q:\n%s", s, got[n-1])
		}
	}
}

// The EPIC #1665 C2 acceptance, end to end through the tick: a Codex profile
// reporting reauth_required is pushed ONCE, with the login command; not again
// within the 6-hour interval; reminded at 6 h; and when the account is back
// one 已恢复 message goes out and the ledger forgets it.
func TestFindingNotifyReauthOnceThenRemindThenRecover(t *testing.T) {
	h := newFleetHarness(t)
	robot := newFakeRobot(t)
	h.srv.Notifier = robot.notifier(6 * time.Hour)
	t0 := time.Now().UTC().Truncate(time.Minute)
	// A collector row only moves forward in time (UpsertCollector drops an
	// older observation), so each report is observed a little later.
	report := func(at time.Time, state, reason string) {
		if err := h.srv.Store.UpsertCollector(model.CollectorStatus{Source: model.SourceCodex, ProfileID: "p-work", ProfileName: "work",
			EndpointID: "ep-m5", ObservedAt: at, State: "ok", Capabilities: []string{},
			Login: &model.LoginHealth{State: state, Reason: reason}}); err != nil {
			t.Fatal(err)
		}
	}
	report(t0, "reauth_required", "Access token expired and no refresh credential is available")

	h.srv.FindingNotifyTick(t0)
	wantMessages(t, robot, 1, "**ccquota · 严重**", "账号 work（codex · ep-m5:work）需要重新登录", "`codex login --device-auth`",
		"> Access token expired", "> https://hub.example/credentials")
	// Every 5-second page refresh used to be a candidate message. The ticks
	// inside the interval say nothing.
	h.srv.FindingNotifyTick(t0.Add(time.Minute))
	h.srv.FindingNotifyTick(t0.Add(5*time.Hour + 59*time.Minute))
	wantMessages(t, robot, 1)
	ledger, _ := h.srv.Store.FindingNotices()
	if len(ledger) != 1 {
		t.Fatalf("ledger = %+v, want one row", ledger)
	}
	// At the interval: one reminder, saying how long it has stood.
	h.srv.FindingNotifyTick(t0.Add(6 * time.Hour))
	wantMessages(t, robot, 2, "**ccquota · 仍在严重 · 已持续 6小时**", "需要重新登录")
	h.srv.FindingNotifyTick(t0.Add(6*time.Hour + time.Minute))
	wantMessages(t, robot, 2)

	// The operator signed in: the profile is valid again.
	report(t0.Add(6*time.Hour+time.Minute), "valid", "")
	h.srv.FindingNotifyTick(t0.Add(6*time.Hour + 2*time.Minute))
	wantMessages(t, robot, 3, "**ccquota · 已恢复**", "账号 work（codex · ep-m5:work）需要重新登录")
	if ledger, _ = h.srv.Store.FindingNotices(); len(ledger) != 0 {
		t.Fatalf("ledger after recovery = %+v, want empty", ledger)
	}
	h.srv.FindingNotifyTick(t0.Add(7 * time.Hour))
	wantMessages(t, robot, 3)

	// Off: a nil notifier is a no-op tick.
	h.srv.Notifier = nil
	report(t0.Add(7*time.Hour), "reauth_required", "again")
	h.srv.FindingNotifyTick(t0.Add(8 * time.Hour))
	wantMessages(t, robot, 3)
}

// The dedup rules on one problem across its life: announced once (Repeat 0 =
// never reminded), again on escalation, again when the sentence changes at
// the same severity, silently when it gets quieter, and recovered when gone.
func TestFindingNotifyEscalationAndRecovery(t *testing.T) {
	h := newFleetHarness(t)
	robot := newFakeRobot(t)
	n := robot.notifier(0)
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	tok := func(days int) []findings.Finding {
		return findings.Now(findings.NowInputs{Now: base, Uncapped: true, SetupTokens: []findings.SetupToken{
			{PrincipalID: "pool", Provider: "claude", Account: "icloud", ExpiresAt: base.Add(time.Duration(days) * 24 * time.Hour)}}})
	}
	n.reconcile(h.srv.Store, tok(20), base)
	wantMessages(t, robot, 1, "**ccquota · 警告**", "setup-token icloud（pool · claude）还有 20 days 到期")
	n.reconcile(h.srv.Store, tok(20), base.Add(9*time.Hour)) // Repeat 0: never reminded
	wantMessages(t, robot, 1)
	n.reconcile(h.srv.Store, tok(3), base.Add(17*24*time.Hour))
	wantMessages(t, robot, 2, "**ccquota · 升级为严重**", "还有 3 days 到期")
	n.reconcile(h.srv.Store, tok(-1), base.Add(21*24*time.Hour))
	wantMessages(t, robot, 3, "**ccquota · 严重（有变化）**", "已于 1 day 前到期")
	// Quieter (a fresh token imported with a shorter life, say): recorded, not said.
	n.reconcile(h.srv.Store, tok(20), base.Add(22*24*time.Hour))
	wantMessages(t, robot, 3)
	ledger, _ := h.srv.Store.FindingNotices()
	if len(ledger) != 1 {
		t.Fatalf("ledger = %+v", ledger)
	}
	for _, row := range ledger {
		if row.Severity != "warning" || row.FindingID != tok(20)[0].ID || !row.FirstAt.Equal(base) {
			t.Fatalf("downgrade not recorded: %+v", row)
		}
	}
	n.reconcile(h.srv.Store, nil, base.Add(23*24*time.Hour))
	wantMessages(t, robot, 4, "**ccquota · 已恢复**", "setup-token icloud（pool · claude）还有 20 days 到期")
	if ledger, _ = h.srv.Store.FindingNotices(); len(ledger) != 0 {
		t.Fatalf("ledger = %+v", ledger)
	}
}

// What is never pushed: an info finding, a muted finding (which also does not
// count as gone), and a kind whose clearing is routine (window_high).
func TestFindingNotifySkipsInfoMutedAndRoutineRecovery(t *testing.T) {
	h := newFleetHarness(t)
	robot := newFakeRobot(t)
	n := robot.notifier(0)
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	info := findings.Review(findings.Inputs{
		Projects:     []findings.ProjectStat{{CWD: "/srv/work/api", Turns: 250, CacheHit: 0.30, Tokens: 4_000_000_000, PrevTokens: 1_000_000_000}},
		PrevProjects: []findings.ProjectStat{{CWD: "/srv/work/api", Turns: 250, CacheHit: 0.90, Tokens: 1_000_000_000}},
	})
	if len(info) == 0 || info[0].Severity != "info" {
		t.Fatalf("fixture: %+v", info)
	}
	n.reconcile(h.srv.Store, info, base)
	wantMessages(t, robot, 0)

	hot := func(mutes findings.Mutes) []findings.Finding {
		return findings.Now(findings.NowInputs{Now: base, Uncapped: true, Mutes: mutes,
			Windows: []findings.WindowStat{{AccountUUID: "acct-1", Label: "team@example.com", FiveHourPct: 95}}})
	}
	// Muted before it was ever announced: silence, and no row.
	if _, err := h.srv.Store.MuteFinding(store.FindingMute{FindingID: hot(nil)[0].ID}, time.Hour, base); err != nil {
		t.Fatal(err)
	}
	mutes, _ := h.srv.activeMutes(base)
	n.reconcile(h.srv.Store, hot(mutes), base)
	wantMessages(t, robot, 0)
	// Unmuted: announced once; gone: no 已恢复 for a window that cooled, row dropped.
	n.reconcile(h.srv.Store, hot(nil), base.Add(2*time.Hour))
	wantMessages(t, robot, 1, "**ccquota · 严重**", "team@example.com")
	n.reconcile(h.srv.Store, nil, base.Add(3*time.Hour))
	wantMessages(t, robot, 1)
	if ledger, _ := h.srv.Store.FindingNotices(); len(ledger) != 0 {
		t.Fatalf("ledger = %+v", ledger)
	}
}

// A failed send records nothing (so it is retried), pauses the notifier for
// notifyBackoff, and the error never carries the webhook's key.
func TestFindingNotifyFailureBacksOffAndKeepsTheKey(t *testing.T) {
	h := newFleetHarness(t)
	robot := newFakeRobot(t)
	n := robot.notifier(0)
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	fs := findings.Now(findings.NowInputs{Now: base, Uncapped: true, Logins: []findings.LoginState{
		{Provider: "codex", Account: "ops", Where: "m5:default", State: "reauth_required", Command: "codex login --device-auth"}}})
	robot.fail = true
	n.reconcile(h.srv.Store, fs, base)
	wantMessages(t, robot, 0)
	if ledger, _ := h.srv.Store.FindingNotices(); len(ledger) != 0 {
		t.Fatalf("a failed send was recorded: %+v", ledger)
	}
	if !n.retryAt.Equal(base.Add(notifyBackoff)) {
		t.Fatalf("retryAt = %s, want %s", n.retryAt, base.Add(notifyBackoff))
	}
	robot.fail = false
	h.srv.Notifier = n
	h.srv.FindingNotifyTick(base.Add(time.Minute)) // inside the backoff: nothing
	wantMessages(t, robot, 0)
	n.reconcile(h.srv.Store, fs, base.Add(notifyBackoff))
	wantMessages(t, robot, 1, "ops")

	dead := &FindingNotifier{Webhook: "http://127.0.0.1:1/cgi-bin/webhook/send?key=SECRET-KEY", Client: &http.Client{Timeout: time.Second}}
	err := dead.send(notice{kind: "new", finding: fs[0]}, base)
	if err == nil || strings.Contains(err.Error(), "SECRET-KEY") || strings.Contains(err.Error(), "key=") {
		t.Fatalf("send error leaks the webhook: %v", err)
	}
}

// One tick sends at most maxPerTick; the rest wait for the next.
func TestFindingNotifyPerTickCap(t *testing.T) {
	h := newFleetHarness(t)
	robot := newFakeRobot(t)
	n := robot.notifier(0)
	base := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	var ws []findings.WindowStat
	for i := 0; i < maxPerTick+3; i++ {
		ws = append(ws, findings.WindowStat{AccountUUID: "acct-" + strings.Repeat("x", i+1), Label: "a@x", FiveHourPct: 95})
	}
	fs := findings.Now(findings.NowInputs{Now: base, Uncapped: true, Windows: ws})
	if len(fs) != maxPerTick+3 {
		t.Fatalf("uncapped findings = %d", len(fs))
	}
	n.reconcile(h.srv.Store, fs, base)
	wantMessages(t, robot, maxPerTick)
	n.reconcile(h.srv.Store, fs, base.Add(time.Minute))
	wantMessages(t, robot, maxPerTick+3)
	n.reconcile(h.srv.Store, fs, base.Add(2*time.Minute))
	wantMessages(t, robot, maxPerTick+3)
}

func TestFindingNotifierFromEnv(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if n, err := FindingNotifierFromEnv(env(nil), "https://hub"); n != nil || err != nil {
		t.Fatalf("unset: %+v %v", n, err)
	}
	if _, err := FindingNotifierFromEnv(env(map[string]string{"CCQUOTA_WECOM_WEBHOOK": "not a url"}), ""); err == nil || strings.Contains(err.Error(), "not a url") {
		t.Fatalf("bad url: %v", err)
	}
	n, err := FindingNotifierFromEnv(env(map[string]string{"CCQUOTA_WECOM_WEBHOOK": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=k"}), "https://hub/")
	if err != nil || n.Repeat != 6*time.Hour || n.Locale != "zh-CN" || n.HubURL != "https://hub" {
		t.Fatalf("defaults: %+v %v", n, err)
	}
	n, err = FindingNotifierFromEnv(env(map[string]string{"CCQUOTA_WECOM_WEBHOOK": "https://x/y", "CCQUOTA_WECOM_REPEAT_HOURS": "0", "CCQUOTA_WECOM_LOCALE": "en"}), "")
	if err != nil || n.Repeat != 0 || n.Locale != "en" {
		t.Fatalf("knobs: %+v %v", n, err)
	}
	if _, err = FindingNotifierFromEnv(env(map[string]string{"CCQUOTA_WECOM_WEBHOOK": "https://x/y", "CCQUOTA_WECOM_REPEAT_HOURS": "-1"}), ""); err == nil {
		t.Fatal("negative hours accepted")
	}
}
