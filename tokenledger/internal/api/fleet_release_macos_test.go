package api

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/release"
)

// publishMac POSTs a Mac lane move: ref=stable-macos and the sha alone.
func (p *publishRig) publishMac(tok, sha string) (int, string) {
	p.t().Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("sha", sha)
	_ = mw.WriteField("ref", RefStableMacOS)
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"publish", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		p.t().Fatal(err)
	}
	defer resp.Body.Close()
	var b bytes.Buffer
	_, _ = b.ReadFrom(resp.Body)
	return resp.StatusCode, b.String()
}

// stableFor is the sha GET …/stable?platform=<p> serves.
func (p *publishRig) stableFor(t *testing.T, platform string) string {
	t.Helper()
	resp, body := getBody(t, p.h.http.URL+release.Path+"stable?platform="+platform)
	if resp.StatusCode != 200 {
		t.Fatalf("GET stable?platform=%s: %d %s", platform, resp.StatusCode, body)
	}
	m, err := release.Verify(p.pub, []byte(body), resp.Header.Get("X-Ccquota-Release-Signature"))
	if err != nil {
		t.Fatal(err)
	}
	return m.SHA
}

func (p *publishRig) version(t *testing.T) map[string]any {
	t.Helper()
	var v map[string]any
	_, body := getBody(t, p.h.http.URL+"/version")
	_ = json.Unmarshal([]byte(body), &v)
	return v
}

// TestMacLane (claude-fleet#3868): the Mac lane names a release stable already
// was, never ahead of stable and never backward; darwin is served it, linux
// stable; with none set every answer is stable's, the _macos fields absent.
func TestMacLane(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	b := p.repo.commit("B", nil)
	c := p.repo.commit("C", nil)
	tok := p.oidc.token(nil)
	for _, s := range [][2]string{{a, ""}, {b, a}} {
		if code, body := p.publish(tok, s[0], s[1], nil, nil); code != 200 {
			t.Fatalf("publish %s: %d %s", s[0][:7], code, body)
		}
	}
	// no lane: both platforms read stable, /version names no _macos field
	if got := p.stableFor(t, "darwin"); got != b {
		t.Fatalf("no lane: darwin served %s, want stable %s", got[:7], b[:7])
	}
	if v := p.version(t); v["client_version"] != b || v["client_version_macos"] != nil || v["client_url_macos"] != nil {
		t.Fatalf("no lane: /version = %v", v)
	}
	// ahead of stable (C was never published): refused
	if code, body := p.publishMac(tok, c); code != 409 {
		t.Fatalf("lane ahead of stable: %d %s", code, body)
	}
	// the lane at A: darwin gets A, linux B
	if code, body := p.publishMac(tok, a); code != 200 || !strings.Contains(body, `"published"`) {
		t.Fatalf("lane to A: %d %s", code, body)
	}
	if got := p.stableFor(t, "darwin"); got != a {
		t.Fatalf("darwin served %s, want the lane's %s", got[:7], a[:7])
	}
	if got := p.stableFor(t, "linux"); got != b {
		t.Fatalf("linux served %s, want stable %s", got[:7], b[:7])
	}
	if got := p.stable(t).SHA; got != b {
		t.Fatalf("no platform served %s, want stable %s", got[:7], b[:7])
	}
	v := p.version(t)
	if v["client_version"] != b || v["client_version_macos"] != a || v["client_url_macos"] != p.h.http.URL+"/install/stable/"+a {
		t.Fatalf("/version = %v", v)
	}
	if resp, _ := getBody(t, p.h.http.URL+"/install/stable/"+a+"/bin/fleet"); resp.StatusCode != 200 {
		t.Fatalf("/install/stable/<lane>/bin/fleet: %d", resp.StatusCode)
	}
	// forward to B; then back to A is refused; B again is a no-op
	if code, body := p.publishMac(tok, b); code != 200 {
		t.Fatalf("lane to B: %d %s", code, body)
	}
	p.rs.macAt = p.rs.macAt.AddDate(-1, 0, 0) // past the read cache
	if code, body := p.publishMac(tok, a); code != 409 {
		t.Fatalf("lane backward: %d %s", code, body)
	}
	if code, body := p.publishMac(tok, b); code != 200 || !strings.Contains(body, `"already"`) {
		t.Fatalf("lane again: %d %s", code, body)
	}
	if got := p.stableFor(t, "darwin"); got != b {
		t.Fatalf("darwin served %s after the lane caught up, want %s", got[:7], b[:7])
	}
	// a ref the hub does not know
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("sha", b)
	_ = mw.WriteField("ref", "stable-windows")
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, p.h.http.URL+release.Path+"publish", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("unknown ref: %d", resp.StatusCode)
	}
}
