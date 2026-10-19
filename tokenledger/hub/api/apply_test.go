package api

import (
	"net/http"
	"strings"
	"testing"
)

// The sign-in page says the hub is open to a limited few, and /apply sends a
// signed-out person there first, the page saying so (claude-fleet#4049).
func TestSigninSaysLimitedAccess(t *testing.T) {
	for _, tc := range []struct {
		name string
		base string
		wx   bool
	}{{"github only", newGitHubHarness(t).http.URL, false}, {"every way", newWaysHarness(t).http.URL, true}} {
		resp, body := newBrowser(t, "").do(http.MethodGet, tc.base+AppPrefix+"/signin?lang=zh", nil)
		if resp.StatusCode != http.StatusOK || !strings.Contains(body, `<span class="pill"><i></i>目前限定开放</span>`) {
			t.Fatalf("%s: /signin (%d) has no 「目前限定开放」 pill:\n%s", tc.name, resp.StatusCode, body)
		}
		if strings.Contains(body, "先登录，再填申请") || !strings.Contains(body, "当场申请") {
			t.Errorf("%s: /signin's lead is not the ordinary one:\n%s", tc.name, body)
		}
		if tc.wx != strings.Contains(body, "关注公众号后") {
			t.Errorf("%s: the follow note shows = %v; want %v", tc.name, !tc.wx, tc.wx)
		}
		_, body = newBrowser(t, "").do(http.MethodGet, tc.base+AppPrefix+"/signin?lang=en", nil)
		if !strings.Contains(body, "Limited access for now") {
			t.Errorf("%s: the English /signin has no pill", tc.name)
		}

		// /apply, signed out: to sign-in, which then leads with applying.
		resp, _ = newBrowser(t, "").do(http.MethodGet, tc.base+ApplyPath, nil)
		if loc := resp.Header.Get("Location"); resp.StatusCode != http.StatusFound || loc != AppPrefix+"/signin?next=/apply" {
			t.Fatalf("%s: GET /apply signed out = %d → %q; want 302 → /app/signin?next=/apply", tc.name, resp.StatusCode, loc)
		}
		_, body = newBrowser(t, "").do(http.MethodGet, tc.base+AppPrefix+"/signin?next=/apply&lang=zh", nil)
		if !strings.Contains(body, `<p class="lead">先登录，再填申请。</p>`) {
			t.Errorf("%s: /signin?next=/apply does not lead with applying:\n%s", tc.name, body)
		}
		// Any other next is not reflected.
		_, body = newBrowser(t, "").do(http.MethodGet, tc.base+AppPrefix+"/signin?next=/evil&lang=zh", nil)
		if strings.Contains(body, "先登录，再填申请") || strings.Contains(body, "/evil") {
			t.Errorf("%s: /signin reflects an unknown next", tc.name)
		}
	}
}
