package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// fakeGHToken is credential-shaped (conf/secret-shapes.list's github row and
// the team layer's value shape) and nobody's.
const fakeGHToken = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"

// feedbackHarness is sessHarness (m5's login is gh:1005's, m4's nobody's)
// with the feedback desk on, its clock in the test's hand.
func feedbackHarness(t *testing.T) (h *harness, tok5, tok4 string, clock *time.Time) {
	t.Helper()
	h, tok5, tok4, _, _ = sessHarness(t)
	now := time.Date(2026, 10, 11, 3, 0, 0, 0, time.UTC)
	clock = &now
	h.srv.Feedback = &FeedbackDesk{Dir: t.TempDir(),
		ShapesFile: filepath.Join("..", "..", "..", "conf", "secret-shapes.list"),
		Now:        func() time.Time { return *clock }}
	ts := httptest.NewServer(h.srv.Handler()) // the routes are registered at Handler()
	t.Cleanup(ts.Close)
	h.http = ts
	return h, tok5, tok4, clock
}

func feedbackPost(t *testing.T, h *harness, tok string, body any) (int, map[string]any) {
	t.Helper()
	return sessDo(t, h, http.MethodPost, NodeFeedbackPath, tok, "", body)
}

// feedbackMultipart sends text + ctx + attachments (name → bytes).
func feedbackMultipart(t *testing.T, h *harness, tok, text string, atts map[string][]byte) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("text", text)
	_ = mw.WriteField("ctx", `{"agent":"claude","machine_kind":"managed-linux"}`)
	for name, b := range atts {
		fw, err := mw.CreateFormFile("attach", name)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = fw.Write(b)
	}
	_ = mw.Close()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+NodeFeedbackPath, &buf)
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func feedbackRows(t *testing.T, h *harness) []store.Feedback {
	t.Helper()
	rows, err := h.srv.Store.FeedbackList(0)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// Who sent it is the hub's word: the token's login, and the person behind it.
func TestFeedbackIdentity(t *testing.T) {
	h, tok5, tok4, _ := feedbackHarness(t)
	ctx := map[string]any{"fleet_version": "b25ce2d8", "agent": "claude", "machine_kind": "managed-linux",
		"worker_id": "u/f", "cc_session": "s1", "window": "@3", "extra": "dropped"}
	st, out := feedbackPost(t, h, tok5, map[string]any{"text": "  ⌘P 要等 5 秒  ", "ctx": ctx})
	if st != 200 || out["id"] != "F1" || out["state"] != "received" || len(out) != 2 {
		t.Fatalf("first feedback: %d %v", st, out)
	}
	ep, err := h.srv.Store.EndpointByTokenHash(HashToken(tok5))
	if err != nil {
		t.Fatal(err)
	}
	host, login := h.srv.nodeIdentity(ep)
	rows := feedbackRows(t, h)
	if len(rows) != 1 {
		t.Fatalf("rows: %v", rows)
	}
	f := rows[0]
	if f.Principal != "gh:1005" || f.EndpointID != ep.ID || f.Login != login || f.Host != host ||
		f.Text != "⌘P 要等 5 秒" || f.State != store.FeedbackReceived || f.Attach != "" {
		t.Fatalf("row: %+v", f)
	}
	var kept map[string]string
	if err := json.Unmarshal([]byte(f.Ctx), &kept); err != nil || len(kept) != 6 || kept["window"] != "@3" || kept["extra"] != "" {
		t.Fatalf("ctx kept: %q %v", f.Ctx, err)
	}
	// a login that is nobody's: taken, with no person — its own limits
	if st, out = feedbackPost(t, h, tok4, map[string]any{"text": "新会话慢"}); st != 200 || out["id"] != "F2" {
		t.Fatalf("nobody's login: %d %v", st, out)
	}
	if rows = feedbackRows(t, h); rows[0].Principal != "" || rows[0].EndpointID == ep.ID {
		t.Fatalf("nobody's row: %+v", rows[0])
	}
	// the body cannot speak for another login
	if st, out = feedbackPost(t, h, tok5, map[string]any{"text": "x", "login": login + "-not"}); st != http.StatusForbidden || out["error"] != "WRONG_LOGIN" {
		t.Fatalf("another login: %d %v", st, out)
	}
	if st, _ = feedbackPost(t, h, "not-a-token", map[string]any{"text": "x"}); st != http.StatusUnauthorized {
		t.Fatalf("no node token: %d", st)
	}
	for name, body := range map[string]map[string]any{
		"empty":      {"text": "   "},
		"too long":   {"text": strings.Repeat("慢", feedbackTextMax+1)},
		"ctx shape":  {"text": "x", "ctx": "flat"},
		"ctx 2 line": {"text": "x", "ctx": map[string]any{"window": "a\nb"}},
	} {
		if st, out := feedbackPost(t, h, tok5, body); st != http.StatusBadRequest {
			t.Fatalf("%s: %d %v", name, st, out)
		}
	}
	if st, _ := sessDo(t, h, http.MethodGet, NodeFeedbackPath, tok5, "", nil); st != http.StatusMethodNotAllowed {
		t.Fatalf("GET: %d", st)
	}
	if n := len(feedbackRows(t, h)); n != 2 {
		t.Fatalf("refusals wrote rows: %d", n)
	}
}

// 10 a person a day, 30 seconds apart; past either, 429 with when.
func TestFeedbackLimits(t *testing.T) {
	h, tok5, tok4, clock := feedbackHarness(t)
	if st, out := feedbackPost(t, h, tok5, map[string]any{"text": "第 1 条"}); st != 200 {
		t.Fatalf("1st: %d %v", st, out)
	}
	*clock = clock.Add(10 * time.Second)
	st, out := feedbackPost(t, h, tok5, map[string]any{"text": "第 2 条"})
	if st != http.StatusTooManyRequests || out["error"] != "rate_limited" || out["retry_after"] != float64(20) ||
		!strings.Contains(out["message"].(string), "30 秒") {
		t.Fatalf("2nd within 30s: %d %v", st, out)
	}
	// another login is not held by this one's gap
	if st, out := feedbackPost(t, h, tok4, map[string]any{"text": "别人"}); st != 200 {
		t.Fatalf("another login: %d %v", st, out)
	}
	for i := 2; i <= feedbackPerDay; i++ {
		*clock = clock.Add(31 * time.Second)
		if st, out := feedbackPost(t, h, tok5, map[string]any{"text": "又一条"}); st != 200 {
			t.Fatalf("#%d: %d %v", i, st, out)
		}
	}
	*clock = clock.Add(31 * time.Second)
	st, out = feedbackPost(t, h, tok5, map[string]any{"text": "第 11 条"})
	if st != http.StatusTooManyRequests || out["error"] != "rate_limited" || !strings.Contains(out["message"].(string), "明天") {
		t.Fatalf("11th: %d %v", st, out)
	}
	if ra, _ := out["retry_after"].(float64); ra < 1 || ra > 24*3600 {
		t.Fatalf("11th retry_after: %v", out["retry_after"])
	}
	if n := len(feedbackRows(t, h)); n != feedbackPerDay+1 {
		t.Fatalf("rows: %d", n)
	}
	// the next day it is open again
	*clock = clock.Add(24 * time.Hour)
	if st, out := feedbackPost(t, h, tok5, map[string]any{"text": "第二天"}); st != 200 {
		t.Fatalf("next day: %d %v", st, out)
	}
}

// The hub's day: 200 for everyone.
func TestFeedbackHubDay(t *testing.T) {
	h, tok5, _, clock := feedbackHarness(t)
	day := debugDay(*clock)
	for i := 0; i < feedbackAllDay; i++ {
		if err := h.srv.Store.UseDebug(store.DebugUseAll, feedbackUseKind, day, feedbackAllDay); err != nil {
			t.Fatal(err)
		}
	}
	st, out := feedbackPost(t, h, tok5, map[string]any{"text": "满了"})
	if st != http.StatusTooManyRequests || !strings.Contains(out["message"].(string), "入口今天") {
		t.Fatalf("hub full: %d %v", st, out)
	}
	uses, _ := h.srv.Store.DebugUses("fb:gh:1005", day)
	if uses[feedbackUseKind] != 0 {
		t.Fatalf("the person's use was not given back: %v", uses)
	}
}

// A credential in the words, the context or an attachment: 422, nothing kept,
// nothing counted.
func TestFeedbackSecretRefused(t *testing.T) {
	h, tok5, _, _ := feedbackHarness(t)
	st, out := feedbackPost(t, h, tok5, map[string]any{"text": "我的令牌是 " + fakeGHToken + " 不管用"})
	if st != http.StatusUnprocessableEntity || out["error"] != "secret" || !strings.Contains(out["message"].(string), "原话") {
		t.Fatalf("secret in text: %d %v", st, out)
	}
	if st, out = feedbackPost(t, h, tok5, map[string]any{"text": "x", "ctx": map[string]any{"window": fakeGHToken}}); st != http.StatusUnprocessableEntity {
		t.Fatalf("secret in ctx: %d %v", st, out)
	}
	st, out = feedbackMultipart(t, h, tok5, "看日志", map[string][]byte{"recent.log": []byte("ok\nAuthorization: Bearer abc.def\n")})
	if st != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "附件") {
		t.Fatalf("secret in attach: %d %v", st, out)
	}
	if n := len(feedbackRows(t, h)); n != 0 {
		t.Fatalf("a refused feedback was kept: %d rows", n)
	}
	entries, _ := os.ReadDir(h.srv.Feedback.Dir)
	if len(entries) != 0 {
		t.Fatalf("a refused attachment was kept: %v", entries)
	}
	// nothing was counted: the clean one goes straight through
	if st, out = feedbackPost(t, h, tok5, map[string]any{"text": "已遮：<redacted:github>"}); st != 200 || out["id"] != "F1" {
		t.Fatalf("clean after refusals: %d %v", st, out)
	}
}

// Attachments: kept under F<id>/, at most 20 MB in all, gone after 7 days.
func TestFeedbackAttachments(t *testing.T) {
	h, tok5, _, clock := feedbackHarness(t)
	st, out := feedbackMultipart(t, h, tok5, "屏幕附上", map[string][]byte{"../screen.txt": []byte("❯ fleet\n")})
	if st != 200 || out["id"] != "F1" {
		t.Fatalf("with attach: %d %v", st, out)
	}
	got, err := os.ReadFile(filepath.Join(h.srv.Feedback.Dir, "F1", "1-screen.txt"))
	if err != nil || string(got) != "❯ fleet\n" {
		t.Fatalf("attachment kept: %q %v", got, err)
	}
	f, _ := h.srv.Store.FeedbackByID(1)
	if f == nil || !strings.Contains(f.Attach, "1-screen.txt") {
		t.Fatalf("row attach: %+v", f)
	}
	*clock = clock.Add(31 * time.Second)
	st, out = feedbackMultipart(t, h, tok5, "太大", map[string][]byte{"big.log": bytes.Repeat([]byte("a"), feedbackAttachMax+1)})
	if st != http.StatusRequestEntityTooLarge || out["error"] != "too_large" {
		t.Fatalf("over 20 MB: %d %v", st, out)
	}
	if n := len(feedbackRows(t, h)); n != 1 {
		t.Fatalf("a refused attachment wrote a row: %d", n)
	}
	// six days: kept; eight: the files go, the row stays
	h.srv.feedbackPrune(clock.Add(6 * 24 * time.Hour))
	if _, err := os.Stat(filepath.Join(h.srv.Feedback.Dir, "F1")); err != nil {
		t.Fatalf("pruned early: %v", err)
	}
	h.srv.feedbackPrune(clock.Add(8 * 24 * time.Hour))
	if _, err := os.Stat(filepath.Join(h.srv.Feedback.Dir, "F1")); !os.IsNotExist(err) {
		t.Fatalf("not pruned: %v", err)
	}
	if f, _ = h.srv.Store.FeedbackByID(1); f == nil || f.Attach != "" || f.Text != "屏幕附上" {
		t.Fatalf("row after prune: %+v", f)
	}
}

// A person reads their own, and only their own.
func TestFeedbackMine(t *testing.T) {
	h, tok5, tok4, _ := feedbackHarness(t)
	feedbackPost(t, h, tok5, map[string]any{"text": "我的"})
	feedbackPost(t, h, tok4, map[string]any{"text": "别人的"})
	read := func(p string) []feedbackMine {
		t.Helper()
		r := httptest.NewRequest(http.MethodGet, FeedbackMinePath, nil)
		r = r.WithContext(context.WithValue(r.Context(), principalKey{}, p))
		w := httptest.NewRecorder()
		h.srv.handleFeedbackMine(w, r)
		var out struct {
			Feedback []feedbackMine `json:"feedback"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &out) != nil {
			t.Fatalf("mine %s: %d %s", p, w.Code, w.Body)
		}
		return out.Feedback
	}
	if got := read("gh:1005"); len(got) != 1 || got[0].ID != "F1" || got[0].Text != "我的" || got[0].State != "received" {
		t.Fatalf("gh:1005's: %+v", got)
	}
	if got := read("gh:9999"); len(got) != 0 {
		t.Fatalf("another person's: %+v", got)
	}
	if got := read(""); len(got) != 0 {
		t.Fatalf("nobody's: %+v", got)
	}
}

// Off (no CCQUOTA_FLEET_FEEDBACK_DIR): no route, nothing kept.
func TestFeedbackOffAddsNothing(t *testing.T) {
	h, tok5, _, _, _ := sessHarness(t)
	if h.srv.Feedback != nil {
		t.Fatal("the harness turned feedback on")
	}
	get := func(method, path string, body []byte) (int, string) {
		req, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok5)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	body := []byte(`{"text":"⌘P 要等 5 秒"}`)
	for _, c := range []struct{ method, path, unknown string }{
		{http.MethodPost, NodeFeedbackPath, "/v1/node/no-such-route"},
		{http.MethodGet, FeedbackMinePath, "/v1/fleet/no-such-route"},
	} {
		code, got := get(c.method, c.path, body)
		ucode, ugot := get(c.method, c.unknown, body)
		if code == 200 || code != ucode || got != ugot {
			t.Fatalf("%s off = %d %q, an unknown path = %d %q", c.path, code, got, ucode, ugot)
		}
	}
	if rows, err := h.srv.Store.FeedbackList(0); err != nil || len(rows) != 0 {
		t.Fatalf("rows off: %v %v", rows, err)
	}
}
