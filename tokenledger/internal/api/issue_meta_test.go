package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The batch is the parent GitHub's sub-issue link names; both lookups are
// cached, and a repo GitHub will not answer is blank, asked again only later.
func TestGitHubIssueMeta(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		switch r.URL.Path {
		case "/repos/o/app/issues/12":
			_, _ = w.Write([]byte(`{"title":"合并额度与用量页","parent_issue_url":"https://api.github.com/repos/o/app/issues/10"}`))
		case "/repos/o/app/issues/10":
			_, _ = w.Write([]byte(`{"title":"EPIC: 用量","parent_issue_url":null}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	g := &GitHubIssueMeta{APIBase: srv.URL}
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		m, err := g.IssueMeta(ctx, "o/app", 12)
		if err != nil || m.Title != "合并额度与用量页" || m.Epic != "o/app#10" || m.EpicTitle != "EPIC: 用量" {
			t.Fatalf("o/app#12 = %+v, %v", m, err)
		}
	}
	if m, err := g.IssueMeta(ctx, "o/app", 10); err != nil || m.Epic != "" {
		t.Errorf("the EPIC itself = %+v, %v; want no parent", m, err)
	}
	if _, err := g.IssueMeta(ctx, "o/private", 1); err == nil {
		t.Error("a 404 answered")
	}
	_, _ = g.IssueMeta(ctx, "o/private", 1)
	if n := calls.Load(); n != 3 {
		t.Errorf("%d requests to GitHub; want 3 (each issue once, the failure cached)", n)
	}
	if _, err := g.IssueMeta(ctx, "../x", 1); err == nil {
		t.Error("a repo that is not owner/name was asked")
	}
}

// claude-fleet#4881: an issue state GitHub would not give says why — the
// status and GitHub's words, or a timeout — never a bare "unknown".
func TestIssueStateSaysWhy(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/app/issues/1":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"API rate limit exceeded for 1.2.3.4."}`))
		case "/repos/o/app/issues/2":
			time.Sleep(200 * time.Millisecond)
		default:
			_, _ = w.Write([]byte(`{"state":"closed"}`))
		}
	}))
	defer srv.Close()
	g := &GitHubIssueMeta{APIBase: srv.URL, Client: &http.Client{Timeout: 50 * time.Millisecond}}
	ctx := context.Background()
	if _, err := g.IssueState(ctx, "o/app", 1); err == nil || !strings.HasPrefix(err.Error(), "HTTP 403 API rate limit exceeded") {
		t.Errorf("rate limited = %v", err)
	}
	if _, err := g.IssueState(ctx, "o/app", 2); err == nil || err.Error() != "GitHub timed out" {
		t.Errorf("slow = %v", err)
	}
	if st, err := g.IssueState(ctx, "o/app", 3); err != nil || st != "closed" {
		t.Errorf("o/app#3 = %q, %v", st, err)
	}
}
