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
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Feedback → a GitHub issue (claude-fleet#3356, EPIC #3354 C2). A feedback the
// hub took becomes, within the minute, one issue labelled `feedback` in the
// fleet's own (public) repo — written by the hub itself, as the fleet's
// existing GitHub App: each pass signs a ten-minute JWT with the App's private
// key, trades it for a one-hour installation token, uses it and drops it. The
// key is read once from the mounted Secret's files (CCQUOTA_FLEET_FEEDBACK_GH_DIR:
// app-id · installation-id · private-key); neither it nor a token is ever
// logged, stored, or put in an issue.
//
// The issue's body is feedbackIssueBody — the ONE definition of what goes
// public (共同约定 5): the words (already held against the shape table at
// intake), the fleet version, the kind of machine, Claude or Codex, the F
// number and its marker. Never the login, the person, the machine's name, the
// session, or an attachment.
//
// One feedback, one issue: before creating, the pass lists the repo's
// `feedback` issues and adopts the one whose body ENDS with this F number's
// marker (a 500 that did create one, a hub that died before writing it back).
// A failed pass leaves the row received (「待转」) and tries again after 1
// minute, doubling to an hour.
//
// Off (no App credentials): nothing is ever sent to GitHub; feedback is taken
// and listed as before.
const (
	feedbackGHAPI        = "https://api.github.com"
	feedbackGHRepo       = "verkyyi/claude-fleet"
	feedbackGHLabel      = "feedback"
	feedbackFileEvery    = 30 * time.Second
	feedbackRetryFirst   = time.Minute
	feedbackRetryMax     = time.Hour
	feedbackTitleRunes   = 40
	feedbackGHTimeout    = 20 * time.Second
	feedbackGHListPages  = 5
	feedbackGHBodyMaxLog = 200
)

// FeedbackGitHub is the filer's configuration; nil on the desk = off.
type FeedbackGitHub struct {
	AppID          string
	InstallationID string
	Key            *rsa.PrivateKey
	// Repo is owner/name (CCQUOTA_FLEET_FEEDBACK_REPO, default verkyyi/claude-fleet).
	Repo string
	// API replaces https://api.github.com in tests.
	API string
	// Client replaces the default HTTP client in tests.
	Client *http.Client

	mu    sync.Mutex
	retry map[int64]feedbackRetry
}

type feedbackRetry struct {
	at    time.Time
	delay time.Duration
}

// LoadFeedbackGitHub reads the App's credentials from dir (the mounted
// Secret). Any of the three files missing or empty ⇒ nil, nil (filing off);
// a key that does not parse ⇒ an error (the caller logs it and leaves filing
// off). The error never carries the key's bytes.
func LoadFeedbackGitHub(dir, repo string) (*FeedbackGitHub, error) {
	if dir == "" {
		return nil, nil
	}
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	app, inst, pemText := read("app-id"), read("installation-id"), read("private-key")
	if app == "" || inst == "" || pemText == "" {
		return nil, nil
	}
	key, err := parseRSAKey([]byte(pemText))
	if err != nil {
		return nil, fmt.Errorf("%s/private-key: %w", dir, err)
	}
	if repo == "" {
		repo = feedbackGHRepo
	}
	return &FeedbackGitHub{AppID: app, InstallationID: inst, Key: key, Repo: repo}, nil
}

func parseRSAKey(b []byte) (*rsa.PrivateKey, error) {
	blk, _ := pem.Decode(b)
	if blk == nil {
		return nil, errors.New("not a PEM private key")
	}
	if k, err := x509.ParsePKCS1PrivateKey(blk.Bytes); err == nil {
		return k, nil
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		return nil, errors.New("not an RSA private key (PKCS#1 or PKCS#8)")
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("not an RSA private key")
	}
	return rk, nil
}

func (g *FeedbackGitHub) api() string {
	if g.API != "" {
		return strings.TrimRight(g.API, "/")
	}
	return feedbackGHAPI
}

func (g *FeedbackGitHub) client() *http.Client {
	if g.Client != nil {
		return g.Client
	}
	return &http.Client{Timeout: feedbackGHTimeout}
}

// appJWT is the App's RS256 assertion: issued a minute back (clock skew),
// good for nine minutes (GitHub's cap is ten).
func (g *FeedbackGitHub) appJWT(now time.Time) (string, error) {
	enc := base64.RawURLEncoding
	head := enc.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{"iat": now.Add(-time.Minute).Unix(), "exp": now.Add(9 * time.Minute).Unix(), "iss": g.AppID})
	signing := head + "." + enc.EncodeToString(claims)
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, g.Key, crypto.SHA256, sum[:])
	if err != nil {
		return "", fmt.Errorf("sign the App JWT: %w", err)
	}
	return signing + "." + enc.EncodeToString(sig), nil
}

// call does one GitHub request; a non-2xx is an error naming the status and
// the start of GitHub's own message (never a header, never the token).
func (g *FeedbackGitHub) call(ctx context.Context, method, path, auth string, body, out any) error {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, g.api()+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := g.client().Do(req)
	if err != nil {
		var ue interface{ Timeout() bool }
		if errors.As(err, &ue) && ue.Timeout() {
			return fmt.Errorf("%s %s: timed out", method, path)
		}
		return fmt.Errorf("%s %s: unreachable", method, path)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if res.StatusCode/100 != 2 {
		var m struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(b, &m)
		return fmt.Errorf("%s %s: %d %s", method, path, res.StatusCode, clipRunes(m.Message, feedbackGHBodyMaxLog))
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			return fmt.Errorf("%s %s: answer not JSON", method, path)
		}
	}
	return nil
}

// installationToken trades the App JWT for a short installation token.
func (g *FeedbackGitHub) installationToken(ctx context.Context, now time.Time) (string, error) {
	jwt, err := g.appJWT(now)
	if err != nil {
		return "", err
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := g.call(ctx, http.MethodPost, "/app/installations/"+g.InstallationID+"/access_tokens", "Bearer "+jwt, map[string]any{}, &out); err != nil {
		return "", err
	}
	if out.Token == "" {
		return "", errors.New("installation token: GitHub answered none")
	}
	return out.Token, nil
}

// feedbackMarker is the last line of every feedback issue: how the filer
// finds the one issue an F number already has.
func feedbackMarker(num string) string { return "<!-- fleet:feedback id=" + num + " -->" }

var (
	feedbackVersionRe = regexp.MustCompile(`^[0-9a-f]{7,40}$`)
	feedbackMarkerRe  = regexp.MustCompile(`<!-- fleet:feedback id=(F[0-9]+) -->\s*$`)
)

// feedbackPublicKind names the kind of machine for the public issue; anything
// it does not know is 未知, never echoed.
func feedbackPublicKind(k string) string {
	switch strings.ToLower(k) {
	case "managed-mac", "managed-darwin", "托管 mac":
		return "托管 Mac"
	case "managed-linux", "托管 linux":
		return "托管 Linux"
	case "own", "personal", "client", "self", "自己的电脑":
		return "自己的电脑"
	}
	return "未知"
}

func feedbackPublicAgent(a string) string {
	switch strings.ToLower(a) {
	case "claude":
		return "Claude"
	case "codex":
		return "Codex"
	}
	return "未知"
}

// feedbackIssueTitle is the words' first 40 characters on one line.
func feedbackIssueTitle(text string) string {
	t := strings.Join(strings.Fields(text), " ")
	if utf8.RuneCountInString(t) > feedbackTitleRunes {
		return string([]rune(t)[:feedbackTitleRunes]) + "…"
	}
	return t
}

// feedbackIssueBody is the ONE definition of what a feedback makes public
// (共同约定 5). A field added here is the 发起人's call.
func feedbackIssueBody(f store.Feedback) string {
	var ctx map[string]string
	_ = json.Unmarshal([]byte(f.Ctx), &ctx)
	ver := ctx["fleet_version"]
	if !feedbackVersionRe.MatchString(ver) {
		ver = "未知"
	} else {
		ver = "`" + ver + "`"
	}
	num := store.FeedbackNumber(f.ID)
	var b strings.Builder
	for _, ln := range strings.Split(f.Text, "\n") {
		b.WriteString("> " + ln + "\n")
	}
	fmt.Fprintf(&b, "\n- 版本：%s\n- 机器：%s\n- 会话：%s\n- 反馈号：%s\n\n%s\n",
		ver, feedbackPublicKind(ctx["machine_kind"]), feedbackPublicAgent(ctx["agent"]), num, feedbackMarker(num))
	return b.String()
}

// feedbackFiled lists the F numbers the repo's feedback issues already carry.
func (g *FeedbackGitHub) feedbackFiled(ctx context.Context, auth string) (map[string]int64, error) {
	out := map[string]int64{}
	for page := 1; page <= feedbackGHListPages; page++ {
		var issues []struct {
			Number int64  `json:"number"`
			Body   string `json:"body"`
		}
		path := fmt.Sprintf("/repos/%s/issues?labels=%s&state=all&sort=created&direction=desc&per_page=100&page=%d", g.Repo, feedbackGHLabel, page)
		if err := g.call(ctx, http.MethodGet, path, auth, nil, &issues); err != nil {
			return nil, err
		}
		for _, is := range issues {
			if m := feedbackMarkerRe.FindStringSubmatch(is.Body); m != nil {
				if _, seen := out[m[1]]; !seen {
					out[m[1]] = is.Number
				}
			}
		}
		if len(issues) < 100 {
			break
		}
	}
	return out, nil
}

// due says whether a row may be tried now.
func (g *FeedbackGitHub) due(id int64, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	r, ok := g.retry[id]
	return !ok || !now.Before(r.at)
}

// failed backs a row off: 1 minute, doubling, at most an hour.
func (g *FeedbackGitHub) failed(id int64, now time.Time) time.Duration {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.retry == nil {
		g.retry = map[int64]feedbackRetry{}
	}
	d := feedbackRetryFirst
	if r, ok := g.retry[id]; ok {
		d = min(r.delay*2, feedbackRetryMax)
	}
	g.retry[id] = feedbackRetry{at: now.Add(d), delay: d}
	return d
}

func (g *FeedbackGitHub) done(id int64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.retry, id)
}

// feedbackFile is one filing pass: every received row that is due becomes
// (or is found to be) one issue. Off: returns at once, nothing sent.
func (s *Server) feedbackFile(ctx context.Context, now time.Time) {
	d := s.Feedback
	if d == nil || d.GitHub == nil {
		return
	}
	g := d.GitHub
	rows, err := s.Store.FeedbackToFile(50)
	if err != nil {
		log.Printf("feedback file: %v", err)
		return
	}
	var todo []store.Feedback
	for _, f := range rows {
		if g.due(f.ID, now) {
			todo = append(todo, f)
		}
	}
	if len(todo) == 0 {
		return
	}
	fail := func(why error) {
		for _, f := range todo {
			wait := g.failed(f.ID, now)
			log.Printf("feedback %s: not filed (%v) — 待转, again in %s", store.FeedbackNumber(f.ID), why, wait)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tok, err := g.installationToken(ctx, now)
	if err != nil {
		fail(err)
		return
	}
	auth := "Bearer " + tok
	filed, err := g.feedbackFiled(ctx, auth)
	if err != nil {
		fail(err)
		return
	}
	for i, f := range todo {
		num := store.FeedbackNumber(f.ID)
		n, ok := filed[num]
		if !ok {
			var out struct {
				Number int64 `json:"number"`
			}
			err := g.call(ctx, http.MethodPost, "/repos/"+g.Repo+"/issues", auth, map[string]any{
				"title": feedbackIssueTitle(f.Text), "body": feedbackIssueBody(f), "labels": []string{feedbackGHLabel}}, &out)
			if err == nil && out.Number == 0 {
				err = errors.New("GitHub answered no issue number")
			}
			if err != nil {
				todo = todo[i:]
				fail(err)
				return
			}
			n = out.Number
		}
		if err := s.Store.SetFeedbackFiled(f.ID, n, now); err != nil {
			log.Printf("feedback %s: issue #%d not written back: %v", num, n, err)
			continue
		}
		g.done(f.ID)
		log.Printf("feedback %s: filed as %s#%d", num, g.Repo, n)
	}
}

// kickFeedbackFiler asks the filer for a pass now (a feedback just came in).
func (d *FeedbackDesk) kickFeedbackFiler() {
	select {
	case d.kick() <- struct{}{}:
	default:
	}
}

func (d *FeedbackDesk) kick() chan struct{} {
	d.kickOnce.Do(func() { d.kickCh = make(chan struct{}, 1) })
	return d.kickCh
}

// runFeedbackFiler files on every kick and every 30 seconds, on the leader.
func (s *Server) runFeedbackFiler(ctx context.Context) {
	d := s.Feedback
	t := time.NewTicker(feedbackFileEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-d.kick():
		}
		if s.Elector != nil && !s.Elector.Leader(ctx, "feedback-file") {
			continue
		}
		s.feedbackFile(ctx, d.now())
	}
}
