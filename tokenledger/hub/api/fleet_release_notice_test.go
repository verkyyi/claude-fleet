package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

func (p *publishRig) postNotice(tok string, body any) (int, string) {
	p.t().Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"notice", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		p.t().Fatal(err)
	}
	defer resp.Body.Close()
	var out bytes.Buffer
	_, _ = out.ReadFrom(resp.Body)
	return resp.StatusCode, out.String()
}

// Only a notice the person must act on reaches the notifier, in two
// languages; any other workflow, no token or a bad verdict is refused and
// says nothing (claude-fleet#4913, T893).
func TestReleaseNoticeRoute(t *testing.T) {
	p := newPublishRig(t)
	var mu sync.Mutex
	var got []string
	p.h.srv.Notify = func(msg string) {
		mu.Lock()
		got = append(got, msg)
		mu.Unlock()
	}
	train := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/release-train.yml@refs/heads/master"})
	next := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/release-train-next.yml@refs/heads/master"})
	watch := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/release-watch.yml@refs/heads/master"})
	other := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/selftests.yml@refs/heads/master"})
	sha := "1c593db" + strings.Repeat("a", 33)
	prev := "5dbd42c" + strings.Repeat("b", 33)
	url := "https://github.com/o/r/actions/runs/9"
	n := map[string]any{"run_id": "901", "sha": sha, "verdict": "flaky", "action": "dispatch", "text": "红：x-selftest.sh · 不稳，已补发"}
	if code, body := p.postNotice(other, n); code != 401 {
		t.Fatalf("selftests.yml: %d %s", code, body)
	}
	if code, body := p.postNotice("", n); code != 401 {
		t.Fatalf("no token: %d %s", code, body)
	}
	if code, body := p.postNotice(train, map[string]any{"run_id": "901", "sha": sha, "verdict": "maybe", "text": "x"}); code != 400 {
		t.Fatalf("bad verdict: %d %s", code, body)
	}
	if code, body := p.postNotice(train, map[string]any{"run_id": "901", "sha": "abc", "verdict": "red", "text": "x"}); code != 400 {
		t.Fatalf("bad sha: %d %s", code, body)
	}
	// recorded only: no one needs to act
	for _, q := range []map[string]any{
		n,
		{"run_id": "902", "sha": sha, "verdict": "shipped", "text": "已上线 1c593db · 含 PR #1 #2"},
		{"run_id": "903", "sha": sha, "verdict": "superseded", "text": "1c593db 没发：stable 已在前面"},
		{"run_id": "904", "sha": sha, "verdict": "cancelled", "text": "1c593db 没发：被取消"},
	} {
		if code, body := p.postNotice(train, q); code != 200 || !strings.Contains(body, `"recorded"`) {
			t.Fatalf("%v: %d %s", q["verdict"], code, body)
		}
	}
	if code, body := p.postNotice(next, map[string]any{"run_id": "77", "sha": sha, "verdict": "resent", "text": "补发 1c593db"}); code != 200 || !strings.Contains(body, `"recorded"`) {
		t.Fatalf("backstop: %d %s", code, body)
	}
	// pushed at once
	for _, q := range []map[string]any{
		{"run_id": "905", "sha": sha, "verdict": "red", "tests": "fleet-credsep-selftest.sh", "url": url, "text": "红：fleet-credsep-selftest.sh · 真红，等修复"},
		{"run_id": "906", "sha": sha, "verdict": "held", "holds": "#5199", "text": "1c593db 测完未发布：#5199 挡着"},
		{"run_id": "907", "sha": sha, "verdict": "flaky", "action": "wait", "tests": "y-selftest.sh", "text": "红：y-selftest.sh · 不稳，没有补发（已到上限）"},
	} {
		if code, body := p.postNotice(train, q); code != 200 || !strings.Contains(body, `"sent"`) {
			t.Fatalf("%v: %d %s", q["verdict"], code, body)
		}
	}
	for _, q := range []map[string]any{
		{"run_id": "908", "sha": sha, "verdict": "rolledback", "to": prev, "text": "已自动回退 1c593db → 5dbd42c：canary"},
		{"run_id": "909", "sha": sha, "verdict": "rollback-failed", "text": "1c593db 出问题了但自动回退失败，请手动：x"},
	} {
		if code, body := p.postNotice(watch, q); code != 200 || !strings.Contains(body, `"sent"`) {
			t.Fatalf("%v: %d %s", q["verdict"], code, body)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	want := []string{
		"【fleet】发布红了 · 1c593db\nfleet-credsep-selftest.sh 真红，等修复\n点开看运行 › " + url +
			"\n\n[fleet] Release red · 1c593db\nfleet-credsep-selftest.sh failed for real — waiting for a fix\nOpen the run › " + url,
		"【fleet】发布被挡住 · 1c593db\n测完了，#5199 挡着没发\n\n[fleet] Release held · 1c593db\nTested, held by #5199",
		"【fleet】发布红了 · 1c593db\ny-selftest.sh 不稳，补发也没救回来\n\n[fleet] Release red · 1c593db\ny-selftest.sh is flaky and re-sending did not save it",
		"【fleet】已回滚 · 1c593db → 5dbd42c\n上线后体检不过，已退回上一版\n\n[fleet] Rolled back · 1c593db → 5dbd42c\nPost-release check failed — back on the previous release",
	}
	if len(got) != 5 {
		t.Fatalf("notified %d: %q", len(got), got)
	}
	for i, w := range want {
		if got[i] != w {
			t.Fatalf("notice %d:\n got %q\nwant %q", i, got[i], w)
		}
	}
	if !strings.HasPrefix(got[4], "【fleet】回滚失败 · 1c593db\n") || !strings.Contains(got[4], "[fleet] Rollback failed · 1c593db") {
		t.Fatalf("rollback-failed: %q", got[4])
	}
	rows, _ := p.h.srv.Store.HubAuditByAction("release.notice", time.Now().Add(-time.Hour))
	if len(rows) != 10 {
		t.Fatalf("audit rows %d, want every notice recorded", len(rows))
	}
}

// The digest goes once a day, after 09:00 Beijing, for the day before — even
// a day with nothing (T893).
func TestReleaseDigest(t *testing.T) {
	p := newPublishRig(t)
	var got []string
	p.h.srv.Notify = func(msg string) { got = append(got, msg) }
	p.h.srv.FleetPublicURL = "https://hub.example/"
	st := p.h.srv.Store
	loc := releaseDigestLoc()
	at := func(d, h, m int) time.Time { return time.Date(2026, 10, d, h, m, 0, 0, loc) }
	for i := 0; i < 78; i++ {
		prs := "#1 #2"
		if i == 0 {
			prs = "#1 #2 #3 #4 #5 #6 #7 #8 #9 #10 #11 #12 等 36 个"
		}
		if err := st.HubAudit("train", "release.notice", "r", "shipped", "abcdef0 已上线 abcdef0 · 含 PR "+prs+" · 合并→生效 9 分钟 · https://x", at(21, 1, i/2)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 7; i++ {
		_ = st.HubAudit("train", "release.notice", "r", "red", "abcdef0 红：x · 真红，等修复", at(21, 0, i))
	}
	_ = st.HubAudit("train", "release.notice", "r", "held", "abcdef0 测完未发布：#5199 挡着", at(20, 23, 0))
	_ = st.HubAudit("train", "release.notice", "r", "cancelled", "abcdef0 没发", at(21, 2, 0))
	_ = st.HubAudit("train", "release.notice", "r", "shipped", "abcdef0 已上线 · 含 PR #9", at(22, 3, 0)) // today: not counted

	if p.h.srv.releaseDigestTick(at(22, 8, 59)) || len(got) != 0 {
		t.Fatalf("before 09:00: %q", got)
	}
	if !p.h.srv.releaseDigestTick(at(22, 9, 0)) {
		t.Fatal("09:00: not sent")
	}
	want := "【fleet】昨天上线 78 次 · 含 190 个 PR\n红 7 次，都已补好；没有挡着的\n点开看清单 › https://hub.example/admin/release" +
		"\n\n[fleet] Yesterday: 78 releases · 190 PRs\n7 red, all fixed since; nothing held\nOpen the list › https://hub.example/admin/release"
	if len(got) != 1 || got[0] != want {
		t.Fatalf("digest:\n got %q\nwant %q", got, want)
	}
	for _, now := range []time.Time{at(22, 9, 1), at(22, 23, 59)} {
		if p.h.srv.releaseDigestTick(now) {
			t.Fatalf("%v: sent twice", now)
		}
	}
	// a day with nothing: still one line
	if !p.h.srv.releaseDigestTick(at(24, 9, 30)) || len(got) != 2 {
		t.Fatalf("quiet day: %q", got)
	}
	if !strings.HasPrefix(got[1], "【fleet】昨天没有上线\n没有红；") {
		t.Fatalf("quiet day: %q", got[1])
	}
	// a red after the last shipped, a hold that stands
	_ = st.HubAudit("train", "release.notice", "r", "red", "abcdef0 红", at(24, 10, 0))
	_ = st.HubAudit("train", "release.notice", "r", "held", "abcdef0 挡着", at(24, 11, 0))
	if !p.h.srv.releaseDigestTick(at(25, 9, 0)) || !strings.Contains(got[2], "红 1 次，还没补好；有挡着的") ||
		!strings.Contains(got[2], "1 red, not fixed yet; a release is held") {
		t.Fatalf("red + held: %q", got)
	}
}

func TestNoticePRs(t *testing.T) {
	for text, want := range map[string]int{
		"已上线 abc · 含 PR #1 #2 · 合并→生效 3 分钟 · https://github.com/o/r/actions/runs/1#x": 2,
		"已上线 abc · 含 PR #1 #2 等 30 个":                                                 30,
		"已上线 abc": 0,
	} {
		if got := noticePRs(text); got != want {
			t.Errorf("%q: %d, want %d", text, got, want)
		}
	}
}
