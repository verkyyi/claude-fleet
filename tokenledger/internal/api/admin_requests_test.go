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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// claude-fleet#4052 (EPIC #4048 C4): an admin reads the requests and decides
// them; a member is answered as if there were nothing there.

// requestsDo is one JSON request to the requests' doors with sess.
func requestsDo(t *testing.T, h *ghHarness, sess *http.Cookie, method, path string, body any) (int, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequestWithContext(ctx, method, h.http.URL+path, rd)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", h.http.URL)
	}
	if sess != nil {
		req.AddCookie(sess)
	}
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, b
}

func seedRequest(t *testing.T, h *ghHarness, id, kind, subject, display string, at time.Time) {
	t.Helper()
	if _, err := h.srv.Store.Requests().Create(store.AccessRequest{ID: id, Kind: kind, Subject: subject, Display: display,
		Use: "给五个人的运营小组做每周销售看板。", NotifyChannel: store.NotifyEmail, NotifyAddr: "x@example.com", CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
}

func hubAuditCount(t *testing.T, h *ghHarness, action, outcome string) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM hub_audit WHERE action = ? AND outcome = ?`, action, outcome).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// A member gets the 404 on every door, reads and writes alike.
func TestAdminRequests_MemberGets404(t *testing.T) {
	h, _, user := rolesHarness(t)
	seedRequest(t, h, "rq-a", store.IdentityEmail, "dana@example.com", "dana@example.com", time.Now())
	for _, c := range []struct{ method, path string }{
		{http.MethodGet, AdminRequestsPath},
		{http.MethodGet, AdminRequestsPath + "?state=pending&count=1"},
		{http.MethodGet, AdminRequestsPath + "/rq-a"},
		{http.MethodPost, AdminRequestsPath + "/rq-a/approve"},
		{http.MethodPost, AdminRequestsPath + "/rq-a/reject"},
	} {
		var body any
		if c.method == http.MethodPost {
			body = map[string]any{"reason": "no"}
		}
		if st, b := requestsDo(t, h, user, c.method, c.path, body); st != http.StatusNotFound {
			t.Errorf("member %s %s = %d %s; want 404", c.method, c.path, st, b)
		}
	}
	if r, _ := h.srv.Store.Requests().Get("rq-a"); r.State != store.RequestPending {
		t.Fatalf("a member's POST changed the request: %s", r.State)
	}
}

// The list, its KPIs and the left column's count.
func TestAdminRequests_ListAndCount(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	now := time.Now()
	seedRequest(t, h, "rq-old", store.IdentityEmail, "old@example.com", "old@example.com", now.Add(-48*time.Hour))
	seedRequest(t, h, "rq-new", store.IdentityGitHub, "777", "zoe", now.Add(-time.Hour))
	seedRequest(t, h, "rq-no", store.IdentityEmail, "no@example.com", "no@example.com", now.Add(-3*time.Hour))
	if _, err := h.srv.Store.Requests().Decide("rq-no", store.RequestRejected, "not yet", now.Add(24*time.Hour), "gh:1", now); err != nil {
		t.Fatal(err)
	}
	st, b := requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath+"?state=pending&count=1", nil)
	if st != http.StatusOK || strings.TrimSpace(string(b)) != `{"pending":2}` {
		t.Fatalf("count = %d %s; want {\"pending\":2}", st, b)
	}
	st, b = requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath, nil)
	var v adminRequestsView
	if st != http.StatusOK || json.Unmarshal(b, &v) != nil {
		t.Fatalf("list = %d %s", st, b)
	}
	if len(v.Requests) != 3 || v.Pending != 2 || v.Decided7d != 1 || v.Approved7d != 0 || v.CooldownDays != 30 {
		t.Fatalf("list = %+v", v)
	}
	if v.OldestPending == nil || v.OldestPending.Unix() != now.Add(-48*time.Hour).Unix() {
		t.Fatalf("oldest pending = %v", v.OldestPending)
	}
	if strings.Contains(string(b), "ip_hash") {
		t.Fatal("the list carries the address hash")
	}
	st, b = requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath+"?state=rejected", nil)
	v = adminRequestsView{}
	if json.Unmarshal(b, &v); st != http.StatusOK || len(v.Requests) != 1 || v.Requests[0].ID != "rq-no" {
		t.Fatalf("rejected = %d %s", st, b)
	}
	if st, _ := requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath+"?state=nope", nil); st != http.StatusBadRequest {
		t.Fatalf("?state=nope = %d; want 400", st)
	}
}

// Approving puts the person on the list in one step: their way lets them
// in at once, and the audit has the decision and the addition.
func TestAdminRequests_ApproveLetsThemIn(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	now := time.Now()
	// they tried to sign in first: the refusal is their 登录记录
	if _, role, why, err := h.srv.admitPerson(store.IdentityEmail, "dana@example.com", "", "", now); err != nil || role != "" || why != denyNotListed {
		t.Fatalf("before: role %q why %q err %v", role, why, err)
	}
	seedRequest(t, h, "rq-d", store.IdentityEmail, "dana@example.com", "dana@example.com", now)
	st, b := requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath+"/rq-d", nil)
	var d adminRequestDetail
	if st != http.StatusOK || json.Unmarshal(b, &d) != nil || d.Signins.Count != 1 || d.Trial || d.Person != "" {
		t.Fatalf("detail = %d %s", st, b)
	}

	st, b = requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-d/approve", map[string]any{})
	d = adminRequestDetail{}
	if st != http.StatusOK || json.Unmarshal(b, &d) != nil || d.State != store.RequestApproved || d.Person == "" || d.DecidedBy == "" {
		t.Fatalf("approve = %d %s", st, b)
	}
	pid, role, why, err := h.srv.admitPerson(store.IdentityEmail, "dana@example.com", "", "", now)
	if err != nil || role != roleUser || why != "" || pid != d.Person {
		t.Fatalf("after: pid %q role %q why %q err %v; want %s as user", pid, role, why, err, d.Person)
	}
	if hubAuditCount(t, h, "request.approve", "ok") != 1 || hubAuditCount(t, h, "user.add", "ok") != 1 {
		t.Fatal("approve did not write request.approve + user.add")
	}
	// again: nothing decided twice; a refusal now is too late
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-d/approve", map[string]any{}); st != http.StatusOK {
		t.Fatalf("approve again = %d", st)
	}
	if hubAuditCount(t, h, "request.approve", "ok") != 1 {
		t.Fatal("approve again audited a second decision")
	}
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-d/reject", map[string]any{"reason": "x"}); st != http.StatusConflict {
		t.Fatalf("reject an approved one = %d; want 409", st)
	}
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-none/approve", map[string]any{}); st != http.StatusNotFound {
		t.Fatalf("approve none = %d; want 404", st)
	}
}

// A GitHub request: the person is gh:<id>, and GitHub's sign-in lets them in.
func TestAdminRequests_ApproveGitHub(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	now := time.Now()
	if _, role, why, _ := h.srv.githubAdmitSignIn(777, "zoe", now, ""); role != "" || why != denyNotListed {
		t.Fatalf("before: role %q why %q", role, why)
	}
	seedRequest(t, h, "rq-z", store.IdentityGitHub, "777", "zoe", now)
	st, b := requestsDo(t, h, admin, http.MethodGet, AdminRequestsPath+"/rq-z", nil)
	if !strings.Contains(string(b), `"signins":{"count":1`) {
		t.Fatalf("detail = %d %s; want the refused sign-in counted", st, b)
	}
	if st, b := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-z/approve", map[string]any{}); st != http.StatusOK || !strings.Contains(string(b), `"person":"gh:777"`) {
		t.Fatalf("approve = %d %s", st, b)
	}
	if pid, role, why, err := h.srv.githubAdmitSignIn(777, "zoe", now, ""); err != nil || role != roleUser || pid != "gh:777" {
		t.Fatalf("after: pid %q role %q why %q err %v", pid, role, why, err)
	}
}

// Rejecting needs a reason; it records it and the cooldown chosen.
func TestAdminRequests_Reject(t *testing.T) {
	h, admin, _ := rolesHarness(t)
	now := time.Now()
	seedRequest(t, h, "rq-r", store.IdentityEmail, "eve@example.com", "eve@example.com", now)
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-r/reject", map[string]any{"reason": "  "}); st != http.StatusBadRequest {
		t.Fatalf("no reason = %d; want 400", st)
	}
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-r/reject", map[string]any{"reason": "x", "cooldown_days": 999}); st != http.StatusBadRequest {
		t.Fatalf("999 days = %d; want 400", st)
	}
	st, b := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-r/reject",
		map[string]any{"reason": "目前只对团队开放", "cooldown_days": 10})
	var d adminRequestDetail
	if st != http.StatusOK || json.Unmarshal(b, &d) != nil || d.State != store.RequestRejected || d.Reason != "目前只对团队开放" {
		t.Fatalf("reject = %d %s", st, b)
	}
	if got := d.CooldownUntil.Sub(now); got < 10*24*time.Hour-time.Minute || got > 10*24*time.Hour+time.Minute {
		t.Fatalf("cooldown %v; want 10 days", got)
	}
	var cool *store.CooldownError
	if _, err := h.srv.Store.Requests().Create(store.AccessRequest{ID: "rq-r2", Kind: store.IdentityEmail,
		Subject: "eve@example.com", CreatedAt: now.Add(time.Hour)}); !errors.As(err, &cool) {
		t.Fatalf("a new request inside the cooldown: %v", err)
	}
	if hubAuditCount(t, h, "request.reject", "ok") != 1 {
		t.Fatal("no request.reject audited")
	}
	if _, role, _, _ := h.srv.admitPerson(store.IdentityEmail, "eve@example.com", "", "", now); role != "" {
		t.Fatal("a refused person was let in")
	}
	// cooldown 0: they may ask again at once
	seedRequest(t, h, "rq-f", store.IdentityEmail, "fay@example.com", "fay@example.com", now)
	if st, _ := requestsDo(t, h, admin, http.MethodPost, AdminRequestsPath+"/rq-f/reject", map[string]any{"reason": "x", "cooldown_days": 0}); st != http.StatusOK {
		t.Fatalf("reject 0 days = %d", st)
	}
	seedRequest(t, h, "rq-f2", store.IdentityEmail, "fay@example.com", "fay@example.com", now.Add(time.Second))
}

// claude-fleet#4062 (C14): the 「新申请待审核」 notice links to the request;
// an admin not signed in there yet (WeChat's own browser) signs in and comes
// back to that request, not the console's front page. Only a request page is
// remembered, and only one spelled as a request id.
func TestAdminRequests_NoticeLinkSurvivesSignIn(t *testing.T) {
	h, _, _ := rolesHarness(t)
	seedRequest(t, h, "rq-a", store.IdentityEmail, "dana@example.com", "dana@example.com", time.Now())
	get := func(path string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+path, nil)
		req.Header.Set("Accept", "text/html")
		resp, err := noFollow.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp
	}
	resp := get("/admin/requests/rq-a")
	if resp.StatusCode != http.StatusFound || resp.Header.Get("Location") != "/app/signin" {
		t.Fatalf("signed out: %d → %q; want 302 /app/signin", resp.StatusCode, resp.Header.Get("Location"))
	}
	c := cookieNamed(resp, entryReturnCookie)
	if c == nil || c.Value != "/admin/requests/rq-a" || !c.HttpOnly {
		t.Fatalf("return cookie: %+v; want /admin/requests/rq-a, HttpOnly", c)
	}
	r := httptest.NewRequest(http.MethodGet, "/auth/wechat/callback", nil)
	r.AddCookie(c)
	if got := loginReturn(httptest.NewRecorder(), r); got != "/admin/requests/rq-a" {
		t.Fatalf("after sign-in: %q; want the request", got)
	}
	// Another admin page sets nothing; a value not a request page is refused.
	if c := cookieNamed(get("/admin/people"), entryReturnCookie); c != nil {
		t.Errorf("/admin/people left a return cookie %q", c.Value)
	}
	for _, v := range []string{"/admin/people", "/admin/requests/../people", "/admin/requests/x", "//evil.example/admin/requests/rq-a"} {
		r := httptest.NewRequest(http.MethodGet, "/auth/wechat/callback", nil)
		r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: v})
		if got := loginReturn(httptest.NewRecorder(), r); got != AppPrefix {
			t.Errorf("return %q → %q; want %s", v, got, AppPrefix)
		}
	}
}
