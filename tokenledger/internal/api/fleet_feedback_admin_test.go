package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// adminGet reads one admin feedback door as the operator.
func adminGet(t *testing.T, h *harness, path string) (int, http.Header, []byte) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+viewerToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, res.Header, b
}

func adminList(t *testing.T, h *harness, q string) (rows []feedbackRow, counts map[string]int, next string) {
	t.Helper()
	st, _, b := adminGet(t, h, AdminFeedbackPath+q)
	var out struct {
		Feedback []feedbackRow `json:"feedback"`
		Counts   map[string]int `json:"counts"`
		Next     string         `json:"next"`
	}
	if st != http.StatusOK || json.Unmarshal(b, &out) != nil {
		t.Fatalf("list %q: %d %s", q, st, b)
	}
	return out.Feedback, out.Counts, out.Next
}

// The admin's page reads every feedback (claude-fleet#3357): an empty hub is
// an empty list; a row carries who, login, machine and type, the opened one
// its session and attachments; the list pages and filters.
func TestFeedbackAdminListAndDetail(t *testing.T) {
	h, tok5, tok4, clock := feedbackHarness(t)

	// 空态
	if rows, counts, next := adminList(t, h, ""); len(rows) != 0 || len(counts) != 0 || next != "" {
		t.Fatalf("empty hub: %+v %v %q", rows, counts, next)
	}

	if st, out := feedbackMultipart(t, h, tok5, "新会话很慢", map[string][]byte{"recent.log": []byte("line one\nline two\n")}); st != 200 {
		t.Fatalf("send F1: %d %v", st, out)
	}
	*clock = clock.Add(time.Minute)
	if st, out := feedbackPost(t, h, tok4, map[string]any{"text": "⌘P 打不开",
		"ctx": map[string]any{"agent": "codex", "machine_kind": "managed-mac", "window": "@7", "cc_session": "abc-123", "worker_id": "u/f", "fleet_version": "9f094a54"}}); st != 200 {
		t.Fatalf("send F2: %d %v", st, out)
	}

	rows, counts, next := adminList(t, h, "")
	if len(rows) != 2 || rows[0].ID != "F2" || rows[1].ID != "F1" || counts["received"] != 2 || next != "" {
		t.Fatalf("list: %+v %v %q", rows, counts, next)
	}
	f1 := rows[1]
	if !strings.Contains(f1.Who, "gh:1005") || f1.Login == "" || f1.Host == "" || f1.MachineKind != "managed-linux" ||
		f1.Agent != "claude" || f1.Attachments != 1 || f1.State != "received" || f1.Text != "新会话很慢" {
		t.Fatalf("F1 row: %+v", f1)
	}
	if rows[0].Principal != "" && rows[0].Who == "" {
		t.Fatalf("F2 names nobody: %+v", rows[0])
	}

	// paging and filtering
	if rows, _, next := adminList(t, h, "?limit=1"); len(rows) != 1 || rows[0].ID != "F2" || next != "F2" {
		t.Fatalf("page 1: %+v %q", rows, next)
	}
	if rows, _, next := adminList(t, h, "?limit=1&before=F2"); len(rows) != 1 || rows[0].ID != "F1" || next != "" {
		t.Fatalf("page 2: %+v %q", rows, next)
	}
	if rows, _, _ := adminList(t, h, "?state=closed"); len(rows) != 0 {
		t.Fatalf("closed: %+v", rows)
	}
	if st, _, _ := adminGet(t, h, AdminFeedbackPath+"?state=nope"); st != http.StatusBadRequest {
		t.Fatalf("bad state: %d", st)
	}

	// one opened: the context, the attachment
	st, _, b := adminGet(t, h, AdminFeedbackPath+"/F2")
	var d feedbackDetail
	if st != 200 || json.Unmarshal(b, &d) != nil {
		t.Fatalf("F2: %d %s", st, b)
	}
	if d.Ctx["window"] != "@7" || d.Ctx["cc_session"] != "abc-123" || d.Ctx["worker_id"] != "u/f" || d.Ctx["fleet_version"] != "9f094a54" ||
		d.EndpointID == "" || d.MachineKind != "managed-mac" || d.Agent != "codex" || len(d.Attach) != 0 {
		t.Fatalf("F2 detail: %+v", d)
	}
	st, _, b = adminGet(t, h, AdminFeedbackPath+"/F1")
	d = feedbackDetail{}
	if st != 200 || json.Unmarshal(b, &d) != nil || len(d.Attach) != 1 {
		t.Fatalf("F1: %d %s", st, b)
	}
	st, hdr, body := adminGet(t, h, d.Attach[0].URL)
	if st != 200 || string(body) != "line one\nline two\n" || !strings.Contains(hdr.Get("Content-Disposition"), "attachment") ||
		hdr.Get("X-Content-Type-Options") != "nosniff" || !strings.HasPrefix(hdr.Get("Content-Type"), "text/plain") {
		t.Fatalf("attachment: %d %v %q", st, hdr, body)
	}
	for _, p := range []string{"/F1/attach/nope.log", "/F9", "/x"} {
		if st, _, _ := adminGet(t, h, AdminFeedbackPath+p); st != http.StatusNotFound {
			t.Errorf("GET %s = %d; want 404", p, st)
		}
	}
	// no token is ever on the page: none of the answers carries one
	_, _, all := adminGet(t, h, AdminFeedbackPath)
	if bytes.Contains(all, []byte(tok5)) || bytes.Contains(all, []byte(tok4)) {
		t.Fatal("a node token is on the admin's list")
	}

	// a node token is not the admin's
	if st, _ := sessDo(t, h, http.MethodGet, AdminFeedbackPath, tok5, "", nil); st != http.StatusForbidden && st != http.StatusUnauthorized {
		t.Fatalf("node token read the admin's list: %d", st)
	}
}

// 「标为重复」: GitHub first (when the row has an issue), then the row closes
// with the reply 「与 F1 重复」; a GitHub that refuses changes nothing.
func TestFeedbackAdminDuplicate(t *testing.T) {
	h, tok5, _, clock := feedbackHarness(t)
	for _, txt := range []string{"一", "二", "三"} {
		if st, out := feedbackPost(t, h, tok5, map[string]any{"text": txt}); st != 200 {
			t.Fatalf("send %s: %d %v", txt, st, out)
		}
		*clock = clock.Add(time.Minute)
	}
	_ = h.srv.Store.SetFeedbackFiled(1, 41, *clock)
	_ = h.srv.Store.SetFeedbackFiled(2, 42, *clock)
	dup := func(id, of string) (int, map[string]any) {
		return sessDo(t, h, http.MethodPost, AdminFeedbackPath+"/"+id+"/duplicate", viewerToken, "", map[string]any{"of": of})
	}
	if st, _ := dup("F2", "F2"); st != http.StatusBadRequest {
		t.Fatalf("dup of itself: %d", st)
	}
	if st, _ := dup("F2", "F99"); st != http.StatusBadRequest {
		t.Fatalf("dup of nothing: %d", st)
	}

	// GitHub cannot be written yet: the row closes, the answer says to close the issue by hand
	st, out := dup("F2", "F1")
	if st != 200 || out["reply"] != "与 F1 重复" || !strings.Contains(out["note"].(string), "#42") {
		t.Fatalf("dup, no GitHub: %d %v", st, out)
	}
	if f, _ := h.srv.Store.FeedbackByID(2); f.State != "closed" || f.Reply != "与 F1 重复" || f.ClosedAt.IsZero() {
		t.Fatalf("F2 after: %+v", f)
	}
	if st, _ := dup("F2", "F1"); st != http.StatusConflict {
		t.Fatalf("dup twice: %d", st)
	}

	// GitHub refuses: nothing changes
	_ = h.srv.Store.SetFeedbackFiled(3, 43, *clock)
	h.srv.Feedback.CloseIssue = func(context.Context, int64, string) error { return errors.New("502 from GitHub") }
	if st, _ := dup("F3", "F1"); st != http.StatusBadGateway {
		t.Fatalf("GitHub down: %d", st)
	}
	if f, _ := h.srv.Store.FeedbackByID(3); f.State != "filed" || f.Reply != "" {
		t.Fatalf("F3 changed though GitHub refused: %+v", f)
	}

	// GitHub answers: commented on and closed, naming the other issue
	var gotN int64
	var gotC string
	h.srv.Feedback.CloseIssue = func(_ context.Context, n int64, c string) error { gotN, gotC = n, c; return nil }
	if st, out := dup("F3", "F1"); st != 200 || out["note"] != nil {
		t.Fatalf("dup with GitHub: %d %v", st, out)
	}
	if gotN != 43 || gotC != "与 F1 重复（#41）" {
		t.Fatalf("GitHub got #%d %q", gotN, gotC)
	}
	if rows, counts, _ := adminList(t, h, "?state=closed"); len(rows) != 2 || counts["closed"] != 2 || counts["filed"] != 1 {
		t.Fatalf("closed: %+v %v", rows, counts)
	}
	if f, _ := h.srv.Store.FeedbackByID(3); !strings.Contains(adminRowGH(t, h, "F3"), "/issues/43") || f.State != "closed" {
		t.Fatalf("F3: %+v", f)
	}
}

func adminRowGH(t *testing.T, h *harness, id string) string {
	t.Helper()
	_, _, b := adminGet(t, h, AdminFeedbackPath+"/"+id)
	var d feedbackDetail
	_ = json.Unmarshal(b, &d)
	return d.GHURL
}

// A user is refused the page and every door (403); an admin's /v1/me lists
// 反馈 only while the hub takes feedback.
func TestFeedbackAdminRoles(t *testing.T) {
	h, admin, user := rolesHarness(t)
	pages := func(sess *http.Cookie) []string {
		t.Helper()
		_, b := rolesGet(t, h, sess, "/v1/me")
		var me Me
		_ = json.Unmarshal(b, &me)
		return me.Pages
	}
	has := func(ps []string) bool {
		for _, p := range ps {
			if p == feedbackPageID {
				return true
			}
		}
		return false
	}
	// off: no page
	if has(pages(admin)) {
		t.Fatal("feedback off, yet /v1/me lists it")
	}

	h.srv.Feedback = &FeedbackDesk{Dir: t.TempDir()}
	ts := httptest.NewServer(h.srv.Handler())
	t.Cleanup(ts.Close)
	h.http = ts
	if !has(pages(admin)) {
		t.Fatal("an admin's /v1/me does not list 反馈")
	}
	if has(pages(user)) {
		t.Fatal("a user's /v1/me lists 反馈")
	}
	for _, p := range []string{AdminFeedbackPath, AdminFeedbackPath + "/F1", AdminFeedbackPath + "/F1/attach/1-x.log", feedbackPagePath} {
		if st, _ := rolesGet(t, h, user, p); st != http.StatusForbidden {
			t.Errorf("user GET %s = %d; want 403", p, st)
		}
	}
	if st, b := rolesGet(t, h, admin, AdminFeedbackPath); st != http.StatusOK || !strings.Contains(string(b), `"feedback":[]`) {
		t.Fatalf("admin GET %s = %d %s", AdminFeedbackPath, st, b)
	}
}
