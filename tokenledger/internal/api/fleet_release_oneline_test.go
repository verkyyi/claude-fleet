package api

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// postRef POSTs a publish carrying only sha + ref (what an older train sent to
// move the Mac lane, claude-fleet#3868).
func (p *publishRig) postRef(tok, sha, ref string) (int, string) {
	p.t().Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("sha", sha)
	_ = mw.WriteField("ref", ref)
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

// TestVersionOneReleaseLine (claude-fleet#4671): there is one release line.
// /version names stable and nothing for a Mac, …/stable serves stable whatever
// ?platform= says (an older client's question), an old hub's Mac lane pointer on
// the volume is not read, and a publish naming any ref but stable is a 400.
func TestVersionOneReleaseLine(t *testing.T) {
	p := newPublishRig(t)
	a := p.repo.commit("A", nil)
	b := p.repo.commit("B", nil)
	tok := p.oidc.token(nil)
	for _, s := range [][2]string{{a, ""}, {b, a}} {
		if code, body := p.publish(tok, s[0], s[1], nil, nil); code != 200 {
			t.Fatalf("publish %s: %d %s", s[0][:7], code, body)
		}
	}
	// what an older hub left: its Mac lane at A
	if err := os.WriteFile(filepath.Join(p.rs.Dir, "stable-macos"), []byte(`{"sha":"`+a+`","seq":1}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var v map[string]any
	_, vb := getBody(t, p.h.http.URL+"/version")
	if err := json.Unmarshal([]byte(vb), &v); err != nil {
		t.Fatal(err)
	}
	if v["stable"] != b || v["client_version"] != b {
		t.Fatalf("/version stable: %v", v)
	}
	for _, k := range []string{"client_version_macos", "client_url_macos", "stable_macos_behind", "stable_macos_behind_since"} {
		if _, ok := v[k]; ok {
			t.Fatalf("/version still says %s: %v", k, v)
		}
	}
	for _, q := range []string{"", "?platform=darwin", "?platform=linux"} {
		resp, body := getBody(t, p.h.http.URL+release.Path+"stable"+q)
		if resp.StatusCode != 200 {
			t.Fatalf("GET stable%s: %d %s", q, resp.StatusCode, body)
		}
		if h := resp.Header.Get("X-Ccquota-Release-Ref"); h != "" {
			t.Fatalf("GET stable%s names a lane: %s", q, h)
		}
		m, err := release.Verify(p.pub, []byte(body), resp.Header.Get("X-Ccquota-Release-Signature"))
		if err != nil {
			t.Fatal(err)
		}
		if m.SHA != b {
			t.Fatalf("GET stable%s served %s, want stable %s", q, m.SHA[:7], b[:7])
		}
	}
	// the Mac lane's ref is gone with it (claude-fleet#4790): a 400, nothing moved
	if code, body := p.postRef(tok, a, "stable-macos"); code != 400 {
		t.Fatalf("ref=stable-macos: %d %s", code, body)
	}
	if got := p.stable(t).SHA; got != b {
		t.Fatalf("stable moved to %s after a refused ref", got[:7])
	}
	if code, body := p.postRef(tok, b, "stable-windows"); code != 400 {
		t.Fatalf("unknown ref: %d %s", code, body)
	}
}
