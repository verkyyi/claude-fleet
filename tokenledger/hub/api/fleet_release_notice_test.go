package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"testing"

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

// The train's and the backstop's notice reaches the notifier once, prefixed;
// any other workflow, no token or a bad verdict is refused and says nothing
// (claude-fleet#4913).
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
	other := p.oidc.token(map[string]any{"workflow_ref": "o/r/.github/workflows/selftests.yml@refs/heads/master"})
	sha := strings.Repeat("ab", 20)
	n := map[string]any{"run_id": "901", "sha": sha, "verdict": "flaky", "text": "红：x-selftest.sh · 不稳，已补发"}
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
	if code, body := p.postNotice(train, n); code != 200 || !strings.Contains(body, `"sent"`) {
		t.Fatalf("train: %d %s", code, body)
	}
	if code, body := p.postNotice(next, map[string]any{"run_id": "77", "sha": sha, "verdict": "resent", "text": "补发 abababa"}); code != 200 {
		t.Fatalf("backstop: %d %s", code, body)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 || got[0] != "发布列车 · 红：x-selftest.sh · 不稳，已补发" || got[1] != "发布列车 · 补发 abababa" {
		t.Fatalf("notified: %q", got)
	}
}
