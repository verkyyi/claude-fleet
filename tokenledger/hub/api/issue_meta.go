package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// GitHubIssueMeta answers an issue's title and its parent (GitHub's sub-issue
// link — an EPIC member's batch) for 我的用量 (claude-fleet#3227), off GitHub's
// REST API with a cache: an answer is trusted for TTL, a failure is not asked
// again for FailTTL, so a page read costs GitHub nothing most of the time and a
// private repo the hub cannot read is simply left blank. Token (optional, read
// from the environment at start) raises the rate limit and reaches private
// repos; it is never written anywhere.
type GitHubIssueMeta struct {
	APIBase string // default https://api.github.com
	Token   string
	// TokenSource, when set, answers the token a request carries ahead of
	// Token: the hub's GitHub App installation token (claude-fleet#4881) —
	// anonymous reads share the cluster's address and run out of GitHub's
	// 60 an hour. Its failure falls back to Token, else anonymous.
	TokenSource func(context.Context) (string, error)
	TTL         time.Duration // default 6h
	FailTTL     time.Duration // default 30m
	Client      *http.Client

	mu    sync.Mutex
	cache map[string]issueMetaEntry
}

type issueMetaEntry struct {
	title  string
	parent string // owner/name#N, "" = none
	err    error
	at     time.Time
}

const issueMetaCacheMax = 4096

var (
	issueRepoRE   = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	issueParentRE = regexp.MustCompile(`/repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(\d+)$`)
)

// IssueMeta is repo#issue's title and its parent's ref + title.
func (g *GitHubIssueMeta) IssueMeta(ctx context.Context, repo string, issue int) (IssueMeta, error) {
	e, err := g.lookup(ctx, repo, issue)
	if err != nil {
		return IssueMeta{}, err
	}
	m := IssueMeta{Title: e.title, Epic: e.parent}
	if e.parent != "" {
		i := strings.LastIndexByte(e.parent, '#')
		n, _ := strconv.Atoi(e.parent[i+1:])
		if p, err := g.lookup(ctx, e.parent[:i], n); err == nil {
			m.EpicTitle = p.title
		}
	}
	return m, nil
}

func (g *GitHubIssueMeta) lookup(ctx context.Context, repo string, issue int) (issueMetaEntry, error) {
	if !issueRepoRE.MatchString(repo) || issue <= 0 {
		return issueMetaEntry{}, errors.New("not an issue")
	}
	key := fmt.Sprintf("%s#%d", repo, issue)
	now := time.Now()
	g.mu.Lock()
	if e, ok := g.cache[key]; ok {
		ttl := orDur(g.TTL, 6*time.Hour)
		if e.err != nil {
			ttl = orDur(g.FailTTL, 30*time.Minute)
		}
		if now.Sub(e.at) < ttl {
			g.mu.Unlock()
			return e, e.err
		}
	}
	g.mu.Unlock()

	e := issueMetaEntry{at: now}
	e.title, e.parent, e.err = g.fetch(ctx, repo, issue)
	if e.err != nil && ctx.Err() != nil {
		return e, e.err // our own deadline, not GitHub's answer: ask again next time
	}
	g.mu.Lock()
	if g.cache == nil || len(g.cache) >= issueMetaCacheMax {
		g.cache = map[string]issueMetaEntry{}
	}
	g.cache[key] = e
	g.mu.Unlock()
	return e, e.err
}

func (g *GitHubIssueMeta) fetch(ctx context.Context, repo string, issue int) (title, parent string, err error) {
	base := strings.TrimRight(orDefault(g.APIBase, "https://api.github.com"), "/")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/repos/%s/issues/%d", base, repo, issue), nil)
	if err != nil {
		return "", "", err
	}
	resp, err := g.do(ctx, req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("github %s#%d: %w", repo, issue, ghStatusErr(resp))
	}
	var body struct {
		Title     string `json:"title"`
		ParentURL string `json:"parent_issue_url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 1<<20)).Decode(&body); err != nil {
		return "", "", err
	}
	if m := issueParentRE.FindStringSubmatch(body.ParentURL); m != nil {
		parent = m[1] + "#" + m[2]
	}
	return body.Title, parent, nil
}

// do sends one GitHub request with the reader's token.
func (g *GitHubIssueMeta) do(ctx context.Context, req *http.Request) (*http.Response, error) {
	req.Header.Set("Accept", "application/vnd.github+json")
	tok := g.Token
	if g.TokenSource != nil {
		if t, err := g.TokenSource(ctx); err == nil && t != "" {
			tok = t
		}
	}
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	c := g.Client
	if c == nil {
		c = &http.Client{Timeout: 5 * time.Second}
	}
	return c.Do(req)
}

// ghTransportErr names why no answer came: timed out or unreachable — never
// the URL or a header.
func ghTransportErr(err error) error {
	var te interface{ Timeout() bool }
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &te) && te.Timeout()) {
		return errors.New("GitHub timed out")
	}
	if errors.Is(err, context.Canceled) {
		return errors.New("cancelled")
	}
	return errors.New("GitHub unreachable")
}

// ghStatusErr names a non-200: its status and the start of GitHub's own
// message ("HTTP 403 rate limit exceeded", "HTTP 401 Bad credentials").
func ghStatusErr(resp *http.Response) error {
	var m struct {
		Message string `json:"message"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&m)
	if msg := strings.TrimSpace(clipRunes(m.Message, 80)); msg != "" {
		return fmt.Errorf("HTTP %d %s", resp.StatusCode, msg)
	}
	return fmt.Errorf("HTTP %d", resp.StatusCode)
}

func orDur(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// IssueState is repo#issue's state on GitHub right now ("open" / "closed"),
// never cached: settling a legacy task record (claude-fleet#4867) acts on it.
func (g *GitHubIssueMeta) IssueState(ctx context.Context, repo string, issue int) (string, error) {
	if !issueRepoRE.MatchString(repo) || issue <= 0 {
		return "", errors.New("not an issue")
	}
	base := strings.TrimRight(orDefault(g.APIBase, "https://api.github.com"), "/")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s/repos/%s/issues/%d", base, repo, issue), nil)
	if err != nil {
		return "", err
	}
	resp, err := g.do(ctx, req)
	if err != nil {
		return "", ghTransportErr(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", ghStatusErr(resp)
	}
	var body struct {
		State string `json:"state"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, 1<<20)).Decode(&body); err != nil {
		return "", err
	}
	return body.State, nil
}
