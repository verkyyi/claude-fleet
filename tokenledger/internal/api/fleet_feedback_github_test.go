package api

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

const (
	fakeAppID   = "5271651"
	fakeInstID  = "170195053"
	fakeInstTok = "ghs_" + "FAKEinstallationTOKEN0123456789abcdef"
)

// fakeIssuesGitHub is a GitHub that knows one App, one installation and one repo's
// issues. fail500 answers every issue write with 500 — after creating it when
// createThen500 is set; hang makes every call wait past the client's timeout.
type fakeIssuesGitHub struct {
	t   *testing.T
	pub *rsa.PublicKey
	mu  sync.Mutex
	// what was asked, in order: "METHOD path"
	calls  []string
	issues []map[string]any
	// comments by issue number (claude-fleet#3359)
	comments      map[int64][]map[string]any
	fail500       bool
	createThen500 bool
	hang          bool
}

func (f *fakeIssuesGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.calls = append(f.calls, r.Method+" "+r.URL.Path)
	hang, fail, createThen := f.hang, f.fail500, f.createThen500
	f.mu.Unlock()
	if hang {
		time.Sleep(300 * time.Millisecond)
	}
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/app/installations/"+fakeInstID+"/access_tokens":
		if !f.jwtOK(auth) {
			http.Error(w, `{"message":"bad JWT"}`, http.StatusUnauthorized)
			return
		}
		writeJSON(w, http.StatusCreated, map[string]any{"token": fakeInstTok, "expires_at": "2026-10-11T04:00:00Z"})
	case auth != fakeInstTok:
		http.Error(w, `{"message":"Bad credentials"}`, http.StatusUnauthorized)
	case r.Method == http.MethodGet && r.URL.Path == "/repos/o/r/issues":
		state := r.URL.Query().Get("state")
		if r.URL.Query().Get("labels") != "feedback" || (state != "all" && state != "closed") {
			http.Error(w, `{"message":"unexpected list"}`, http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		out := []map[string]any{}
		for _, is := range f.issues {
			if state == "all" || is["state"] == state {
				out = append(out, is)
			}
		}
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, out)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/o/r/issues/") && strings.HasSuffix(r.URL.Path, "/comments"):
		var n int64
		_, _ = fmt.Sscanf(strings.TrimPrefix(r.URL.Path, "/repos/o/r/issues/"), "%d", &n)
		f.mu.Lock()
		out := append([]map[string]any{}, f.comments[n]...)
		f.mu.Unlock()
		writeJSON(w, http.StatusOK, out)
	case r.Method == http.MethodPost && r.URL.Path == "/repos/o/r/issues":
		if fail && !createThen {
			http.Error(w, `{"message":"Server Error"}`, http.StatusInternalServerError)
			return
		}
		var in map[string]any
		_ = json.NewDecoder(r.Body).Decode(&in)
		f.mu.Lock()
		in["number"] = float64(9000 + len(f.issues))
		f.issues = append(f.issues, in)
		f.mu.Unlock()
		if fail {
			http.Error(w, `{"message":"Server Error"}`, http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusCreated, in)
	default:
		http.Error(w, `{"message":"Not Found"}`, http.StatusNotFound)
	}
}

// jwtOK verifies the App assertion: RS256 by the App's key, iss = the App.
func (f *fakeIssuesGitHub) jwtOK(tok string) bool {
	p := strings.Split(tok, ".")
	if len(p) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(p[2])
	if err != nil {
		return false
	}
	sum := sha256.Sum256([]byte(p[0] + "." + p[1]))
	if rsa.VerifyPKCS1v15(f.pub, crypto.SHA256, sum[:], sig) != nil {
		return false
	}
	b, _ := base64.RawURLEncoding.DecodeString(p[1])
	var c struct {
		Iss string `json:"iss"`
		Iat int64  `json:"iat"`
		Exp int64  `json:"exp"`
	}
	return json.Unmarshal(b, &c) == nil && c.Iss == fakeAppID && c.Exp > c.Iat && c.Exp-c.Iat <= 600
}

func (f *fakeIssuesGitHub) snapshot() (calls []string, issues []map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.calls...), append([]map[string]any{}, f.issues...)
}

// feedbackGHHarness is feedbackHarness with the App's credentials loaded from
// a Secret-shaped directory and pointed at a fake GitHub; every log line the
// hub writes is captured.
func feedbackGHHarness(t *testing.T) (h *harness, tok5 string, clock *time.Time, gh *fakeIssuesGitHub, logs *bytes.Buffer, keyPEM string) {
	t.Helper()
	h, tok5, _, clock = feedbackHarness(t)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM = string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	dir := t.TempDir()
	for name, v := range map[string]string{"app-id": fakeAppID + "\n", "installation-id": fakeInstID, "private-key": keyPEM} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o400); err != nil {
			t.Fatal(err)
		}
	}
	g, err := LoadFeedbackGitHub(dir, "o/r")
	if err != nil || g == nil {
		t.Fatalf("load: %v %v", g, err)
	}
	gh = &fakeIssuesGitHub{t: t, pub: &key.PublicKey}
	ts := httptest.NewServer(gh)
	t.Cleanup(ts.Close)
	g.API, g.Client = ts.URL, &http.Client{Timeout: 100 * time.Millisecond}
	h.srv.Feedback.GitHub = g
	logs = &bytes.Buffer{}
	log.SetOutput(io.MultiWriter(logs, os.Stderr))
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return h, tok5, clock, gh, logs, keyPEM
}

// The public issue carries the words, the version, the kind of machine,
// Claude/Codex and the F number — never who, where or which session.
func TestFeedbackFiledPublicFieldsOnly(t *testing.T) {
	h, tok5, clock, gh, logs, keyPEM := feedbackGHHarness(t)
	ctx := map[string]any{"fleet_version": "b25ce2d8", "agent": "claude", "machine_kind": "managed-linux",
		"worker_id": "uuid-0f3a/fid-77", "cc_session": "sess-4b1e", "window": "@31"}
	text := "⌘P 打开新会话要等五秒，有时候更久，跟着一起卡住的还有侧栏的任务列表和顶上那一行状态\n第二行"
	if st, out := feedbackPost(t, h, tok5, map[string]any{"text": text, "ctx": ctx}); st != 200 || out["id"] != "F1" {
		t.Fatalf("intake: %d %v", st, out)
	}
	h.srv.feedbackFile(context.Background(), *clock)

	_, issues := gh.snapshot()
	if len(issues) != 1 {
		t.Fatalf("issues: %v", issues)
	}
	is := issues[0]
	want := "> ⌘P 打开新会话要等五秒，有时候更久，跟着一起卡住的还有侧栏的任务列表和顶上那一行状态\n> 第二行\n\n" +
		"- 版本：`b25ce2d8`\n- 机器：托管 Linux\n- 会话：Claude\n- 反馈号：F1\n\n<!-- fleet:feedback id=F1 -->\n"
	if is["body"] != want {
		t.Fatalf("body:\n%q\nwant\n%q", is["body"], want)
	}
	if is["title"] != "⌘P 打开新会话要等五秒，有时候更久，跟着一起卡住的还有侧栏的任务列表和顶上那一…" {
		t.Fatalf("title: %q", is["title"])
	}
	if lb, _ := is["labels"].([]any); len(lb) != 1 || lb[0] != "feedback" {
		t.Fatalf("labels: %v", is["labels"])
	}
	row := feedbackRows(t, h)[0]
	if row.State != store.FeedbackFiled || row.GHNumber != 9000 || !row.FiledAt.Equal(*clock) {
		t.Fatalf("row: %+v", row)
	}
	public := is["title"].(string) + is["body"].(string)
	for _, secret := range []string{row.Login, row.Host, row.Principal, "1005", row.EndpointID,
		"uuid-0f3a", "fid-77", "sess-4b1e", "@31"} {
		if secret != "" && strings.Contains(public, secret) {
			t.Fatalf("the public issue names %q:\n%s", secret, public)
		}
	}
	// unknown kinds and agents are 未知, never echoed; a version not a sha too
	b := feedbackIssueBody(store.Feedback{ID: 7, Text: "x", Ctx: `{"machine_kind":"m5-of-verky","agent":"bob","fleet_version":"verky's"}`})
	if !strings.Contains(b, "- 版本：未知\n- 机器：未知\n- 会话：未知\n") || strings.Contains(b, "verky") || strings.Contains(b, "m5") {
		t.Fatalf("unknown ctx: %q", b)
	}
	// no credential in any log line
	for _, s := range []string{fakeInstTok, strings.TrimSpace(keyPEM), "BEGIN RSA"} {
		if strings.Contains(logs.String(), s) {
			t.Fatalf("a log line carries a credential (%.12s…)", s)
		}
	}
	// filed already ⇒ a second pass sends nothing
	before, _ := gh.snapshot()
	h.srv.feedbackFile(context.Background(), clock.Add(time.Hour))
	if after, _ := gh.snapshot(); len(after) != len(before) {
		t.Fatalf("a pass with nothing to file asked GitHub: %v", after[len(before):])
	}
}

// GitHub down (500, a timeout) ⇒ the feedback stays 待转 and is tried again
// after 1 minute, doubling; once GitHub is back it becomes exactly ONE issue —
// even when the failed write had in fact created it.
func TestFeedbackGitHubDownQueuesThenFilesOnce(t *testing.T) {
	h, tok5, clock, gh, logs, _ := feedbackGHHarness(t)
	if st, out := feedbackPost(t, h, tok5, map[string]any{"text": "侧栏不刷新"}); st != 200 || out["id"] != "F1" {
		t.Fatalf("intake: %d %v", st, out)
	}
	now := *clock
	pass := func(at time.Time) { h.srv.feedbackFile(context.Background(), at) }
	calls := func() int { c, _ := gh.snapshot(); return len(c) }

	gh.mu.Lock()
	gh.fail500, gh.createThen500 = true, true // created, but answered 500
	gh.mu.Unlock()
	pass(now)
	if r := feedbackRows(t, h)[0]; r.State != store.FeedbackReceived || r.GHNumber != 0 {
		t.Fatalf("after a 500: %+v", r)
	}
	n := calls()
	pass(now.Add(59 * time.Second)) // inside the first minute: not tried
	if calls() != n {
		t.Fatal("tried again inside the first minute")
	}
	gh.mu.Lock()
	gh.fail500, gh.createThen500, gh.hang = false, false, true
	gh.mu.Unlock()
	pass(now.Add(61 * time.Second)) // tried, times out ⇒ next in 2 minutes
	if calls() == n || feedbackRows(t, h)[0].State != store.FeedbackReceived {
		t.Fatal("the retry after a minute did not run, or a timeout filed it")
	}
	n = calls()
	pass(now.Add(61*time.Second + 119*time.Second))
	if calls() != n {
		t.Fatal("tried again before the doubled wait")
	}
	gh.mu.Lock()
	gh.hang = false
	gh.mu.Unlock()
	pass(now.Add(61*time.Second + 121*time.Second))
	_, issues := gh.snapshot()
	r := feedbackRows(t, h)[0]
	if len(issues) != 1 || r.State != store.FeedbackFiled || r.GHNumber != 9000 {
		t.Fatalf("back up: %d issues, row %+v", len(issues), r)
	}
	if !strings.Contains(logs.String(), "F1: not filed") || strings.Contains(logs.String(), fakeInstTok) {
		t.Fatalf("logs: %s", logs.String())
	}
	// the backoff caps at an hour
	g := h.srv.Feedback.GitHub
	var d time.Duration
	for i := 0; i < 12; i++ {
		d = g.failed(42, now)
	}
	if d != time.Hour {
		t.Fatalf("backoff cap: %s", d)
	}
}

// No App credentials ⇒ feedback is taken as before and nothing is sent.
func TestFeedbackFilingOffSendsNothing(t *testing.T) {
	gh := &fakeIssuesGitHub{t: t}
	ts := httptest.NewServer(gh)
	t.Cleanup(ts.Close)
	h, tok5, _, clock := feedbackHarness(t)
	if st, out := feedbackPost(t, h, tok5, map[string]any{"text": "x"}); st != 200 || out["id"] != "F1" {
		t.Fatalf("intake: %d %v", st, out)
	}
	h.srv.feedbackFile(context.Background(), *clock)
	// a Secret mounted with a key missing, or not mounted at all
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "app-id"), []byte(fakeAppID), 0o400)
	for _, d := range []string{"", dir, filepath.Join(dir, "nope")} {
		if g, err := LoadFeedbackGitHub(d, ""); g != nil || err != nil {
			t.Fatalf("load %q: %v %v", d, g, err)
		}
	}
	_ = os.WriteFile(filepath.Join(dir, "installation-id"), []byte(fakeInstID), 0o400)
	_ = os.WriteFile(filepath.Join(dir, "private-key"), []byte("not a key"), 0o400)
	if g, err := LoadFeedbackGitHub(dir, ""); g != nil || err == nil || strings.Contains(err.Error(), "not a key") {
		t.Fatalf("a bad key: %v %v", g, err)
	}
	if c, _ := gh.snapshot(); len(c) != 0 {
		t.Fatalf("GitHub was asked: %v", c)
	}
	if r := feedbackRows(t, h)[0]; r.State != store.FeedbackReceived || r.GHNumber != 0 {
		t.Fatalf("row: %+v", r)
	}
}
