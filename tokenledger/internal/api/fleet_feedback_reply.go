package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A feedback's reply → the person's session (claude-fleet#3359, EPIC #3354 C5).
// When its GitHub issue is closed, what the closing said goes back to the
// person who sent it, in the session they are using:
//
//   - every 5 minutes the hub (the same App token as the filer) lists the
//     repo's `feedback` issues closed since the oldest still-open row was filed
//     (REST, `since` — no state of its own); for each issue carrying a filed
//     row's marker, the reply is the newest `/reply` comment's first paragraph,
//     else the comment written with the close (its first paragraph), else
//     「已处理，见单子 #N」 (a duplicate: 「和另一张单是同一件事」). The row is
//     closed once — a reopened issue closed again changes nothing.
//   - every minute each closed row — closed here or by C3's 「标为重复」 — whose reply has not reached the person is
//     sent as worker_message, text `[fleet-feedback] 你的反馈 F12 有回音了…`,
//     to the session that sent it (idempotency key fb-F12) when the inventory
//     shows it, else to one of that person's live sessions on any of their
//     machines (fb-F12-<hash of the worker_id>). The node delivers that prefix
//     straight to the session's inbox (fleet_control.py); only this desk's
//     actor may send it. Reached = the node says succeeded: replied_at is
//     written, and nothing is ever sent for that row again.
//   - nobody's session up, or the node down: the row waits; past 30 days after
//     the close it is never sent.
//
// Off (no GitHub App, or no feedback desk): nothing is polled; rows only reach
// closed through GitHub, so nothing is sent either.
const (
	feedbackReplyPollEvery = 5 * time.Minute
	feedbackReplySendEvery = time.Minute
	feedbackReplyKeep      = 30 * 24 * time.Hour
	feedbackReplyRunes     = 500
	feedbackReplyWait      = 90 * time.Second
	feedbackReplyTries     = 6
	// feedbackActor is the journal's actor for a reply, and the only one the
	// hub lets send the [fleet-feedback] prefix.
	feedbackActor = "feedback"
	// FeedbackReplyPrefix starts every reply's text; fleet_control.py delivers
	// a worker_message carrying it to any session's inbox.
	FeedbackReplyPrefix = "[fleet-feedback]"
	// feedbackCloseWindow is how long before an issue's close a comment still
	// counts as "written with the close".
	feedbackCloseWindow = 10 * time.Minute
)

var (
	feedbackHTMLCommentRe = regexp.MustCompile(`(?s)<!--.*?-->`)
	feedbackReplyCmdRe    = regexp.MustCompile(`^/reply\b[ \t]*`)
)

type ghClosedIssue struct {
	Number      int64     `json:"number"`
	Body        string    `json:"body"`
	State       string    `json:"state"`
	StateReason string    `json:"state_reason"`
	ClosedAt    time.Time `json:"closed_at"`
}

type ghComment struct {
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
	User      struct {
		Type string `json:"type"`
	} `json:"user"`
}

// feedbackReplyParagraph is a comment's first paragraph, HTML comments (a
// fleet comment's markers) and a leading /reply taken out, on at most 500
// characters with no control character; "" when nothing is left.
func feedbackReplyParagraph(body string) string {
	t := strings.ReplaceAll(body, "\r\n", "\n")
	t = feedbackHTMLCommentRe.ReplaceAllString(t, "")
	t = strings.TrimSpace(t)
	t = strings.TrimSpace(feedbackReplyCmdRe.ReplaceAllString(t, ""))
	if i := strings.Index(t, "\n\n"); i >= 0 {
		t = t[:i]
	}
	t = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if r < 32 || r == 0x7f {
			return -1
		}
		return r
	}, t)
	t = strings.TrimSpace(strings.ReplaceAll(t, "<!--", "< !--"))
	if utf8.RuneCountInString(t) > feedbackReplyRunes {
		t = string([]rune(t)[:feedbackReplyRunes]) + "…"
	}
	return t
}

// feedbackReplyOf picks what a closed issue says back (共同约定 8): the newest
// /reply comment, else the newest comment written with the close, else a
// plain sentence naming the issue.
func feedbackReplyOf(is ghClosedIssue, comments []ghComment) string {
	for i := len(comments) - 1; i >= 0; i-- {
		c := comments[i]
		if strings.EqualFold(c.User.Type, "Bot") {
			continue
		}
		lead := strings.TrimSpace(feedbackHTMLCommentRe.ReplaceAllString(strings.ReplaceAll(c.Body, "\r\n", "\n"), ""))
		if feedbackReplyCmdRe.MatchString(lead) {
			if p := feedbackReplyParagraph(c.Body); p != "" {
				return p
			}
		}
	}
	if !is.ClosedAt.IsZero() {
		for i := len(comments) - 1; i >= 0; i-- {
			c := comments[i]
			if strings.EqualFold(c.User.Type, "Bot") || c.CreatedAt.After(is.ClosedAt.Add(2*time.Minute)) ||
				c.CreatedAt.Before(is.ClosedAt.Add(-feedbackCloseWindow)) {
				continue
			}
			if p := feedbackReplyParagraph(c.Body); p != "" {
				return p
			}
		}
	}
	if is.StateReason == "duplicate" {
		return fmt.Sprintf("这件事和另一张单是同一件，已在那边处理（见单子 #%d）。", is.Number)
	}
	return fmt.Sprintf("已处理，见单子 #%d。", is.Number)
}

// feedbackReplyText is what the person's session is told.
func feedbackReplyText(f store.Feedback, repo string) string {
	return fmt.Sprintf("%s 你的反馈 %s 有回音了（%s#%d）：%s", FeedbackReplyPrefix,
		store.FeedbackNumber(f.ID), repo, f.GHNumber, f.Reply)
}

// feedbackPollCloses is one poll of GitHub: every filed row whose issue was
// closed becomes closed with its reply. Off: returns at once.
func (s *Server) feedbackPollCloses(ctx context.Context, now time.Time) {
	d := s.Feedback
	if d == nil || d.GitHub == nil {
		return
	}
	g := d.GitHub
	rows, err := s.Store.FeedbackFiledOpen(1000)
	if err != nil {
		log.Printf("feedback replies: %v", err)
		return
	}
	if len(rows) == 0 {
		return // nothing on GitHub to wait for: GitHub is not asked
	}
	open := map[string]store.Feedback{}
	since := rows[0].FiledAt
	for _, f := range rows {
		open[store.FeedbackNumber(f.ID)] = f
		if !f.FiledAt.IsZero() && f.FiledAt.Before(since) {
			since = f.FiledAt
		}
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	tok, err := g.installationToken(ctx, now)
	if err != nil {
		log.Printf("feedback replies: not polled (%v)", err)
		return
	}
	auth := "Bearer " + tok
	closed := 0
	for page := 1; page <= feedbackGHListPages; page++ {
		var issues []ghClosedIssue
		q := url.Values{"labels": {feedbackGHLabel}, "state": {"closed"}, "sort": {"updated"}, "direction": {"desc"},
			"per_page": {"100"}, "page": {fmt.Sprint(page)}}
		if !since.IsZero() {
			q.Set("since", since.UTC().Format(time.RFC3339))
		}
		if err := g.call(ctx, http.MethodGet, "/repos/"+g.Repo+"/issues?"+q.Encode(), auth, nil, &issues); err != nil {
			log.Printf("feedback replies: not polled (%v)", err)
			return
		}
		for _, is := range issues {
			m := feedbackMarkerRe.FindStringSubmatch(is.Body)
			if m == nil || is.State != "closed" {
				continue
			}
			f, ok := open[m[1]]
			if !ok || f.GHNumber != is.Number {
				continue
			}
			var comments []ghComment
			cq := url.Values{"per_page": {"100"}}
			if !is.ClosedAt.IsZero() {
				cq.Set("since", is.ClosedAt.Add(-feedbackCloseWindow).UTC().Format(time.RFC3339))
			}
			if err := g.call(ctx, http.MethodGet, fmt.Sprintf("/repos/%s/issues/%d/comments?%s", g.Repo, is.Number, cq.Encode()),
				auth, nil, &comments); err != nil {
				log.Printf("feedback %s: comments of #%d not read (%v) — again next poll", m[1], is.Number, err)
				continue
			}
			at := is.ClosedAt
			if at.IsZero() {
				at = now
			}
			ok, err := s.Store.CloseFeedback(f.ID, feedbackReplyOf(is, comments), at)
			if err != nil {
				log.Printf("feedback %s: close not written: %v", m[1], err)
				continue
			}
			if ok {
				closed++
				delete(open, m[1])
				log.Printf("feedback %s: %s#%d closed — reply queued", m[1], g.Repo, is.Number)
			}
		}
		if len(issues) < 100 {
			break
		}
	}
	if closed > 0 {
		cancel()
		s.feedbackSendReplies(parent, now)
	}
}

// feedbackTarget is one live session a reply may go to.
type feedbackTarget struct {
	workerID string
	idem     string
}

// feedbackTargets lists where row f's reply may go now, best first: the
// session that sent it when the inventory shows it, then the same login's
// other sessions, then the person's sessions on their other machines.
// Fleets on a machine the hub has lost are not listed.
func (s *Server) feedbackTargets(f store.Feedback, now time.Time) []feedbackTarget {
	var ctxm map[string]string
	_ = json.Unmarshal([]byte(f.Ctx), &ctxm)
	orig := ctxm["worker_id"]
	rows, err := s.Store.Fleets()
	if err != nil {
		log.Printf("feedback %s: fleets not read: %v", store.FeedbackNumber(f.ID), err)
		return nil
	}
	avail := s.nodeAvailability(now)
	num := store.FeedbackNumber(f.ID)
	var first, same, other []feedbackTarget
	for _, r := range rows {
		if !r.Present || avail[r.EndpointID] == "lost" {
			continue
		}
		mine := r.EndpointID == f.EndpointID
		if !mine && f.Principal != "" {
			p, err := s.principalOnNode(r.EndpointID, r.Hostname, r.OSUser)
			mine = err == nil && p == f.Principal
		}
		if !mine {
			continue
		}
		var ws []struct {
			WorkerID string  `json:"worker_id"`
			Identity *string `json:"identity"`
		}
		if json.Unmarshal([]byte(r.WorkersJSON), &ws) != nil {
			continue
		}
		for _, w := range ws {
			if fid, _, err := fleetid.ParseWorkerID(w.WorkerID); err != nil || fid != r.FleetID {
				continue
			}
			alias := ""
			if w.Identity != nil && fleetid.IsUUID(*w.Identity) {
				alias = r.FleetID + "/" + *w.Identity
			}
			switch {
			case orig != "" && (w.WorkerID == orig || alias == orig):
				first = append(first, feedbackTarget{workerID: orig, idem: "fb-" + num})
			case r.EndpointID == f.EndpointID:
				same = append(same, feedbackTarget{workerID: w.WorkerID, idem: feedbackIdem(num, w.WorkerID)})
			default:
				other = append(other, feedbackTarget{workerID: w.WorkerID, idem: feedbackIdem(num, w.WorkerID)})
			}
		}
	}
	return append(append(first[:min(len(first), 1)], same...), other...)
}

func feedbackIdem(num, workerID string) string {
	sum := sha256.Sum256([]byte(workerID))
	return "fb-" + num + "-" + hex.EncodeToString(sum[:6])
}

// feedbackSendReplies is one delivery pass: every closed row whose reply has
// not reached the person, inside the 30 days, is tried on its sessions in
// order until one node says succeeded.
func (s *Server) feedbackSendReplies(ctx context.Context, now time.Time) {
	if s.Feedback == nil {
		return
	}
	rows, err := s.Store.FeedbackToReply(now.Add(-feedbackReplyKeep), 200)
	if err != nil {
		log.Printf("feedback replies: %v", err)
		return
	}
	repo := feedbackGHRepo
	if g := s.Feedback.GitHub; g != nil && g.Repo != "" {
		repo = g.Repo
	}
	for _, f := range rows {
		s.feedbackSendReply(ctx, f, repo, now)
	}
}

func (s *Server) feedbackSendReply(ctx context.Context, f store.Feedback, repo string, now time.Time) {
	num := store.FeedbackNumber(f.ID)
	text := feedbackReplyText(f, repo)
	targets := s.feedbackTargets(f, now)
	for i, t := range targets {
		if i >= feedbackReplyTries {
			return
		}
		op, err := s.SubmitWrite(ctx, fleetPrincipal{Actor: feedbackActor}, "worker_message",
			map[string]any{"worker_id": t.workerID, "text": text, "idempotency_key": t.idem})
		if err != nil {
			continue // its machine cannot take a write now: the next session, or the next pass
		}
		if st := asString(op["status"]); !operationFinal(st) || st == "unknown" {
			op, _ = s.awaitOperation(ctx, op, time.Now().Add(s.feedbackWait()))
		}
		switch asString(op["status"]) {
		case "succeeded":
			if ok, err := s.Store.SetFeedbackReplied(f.ID, now); err != nil {
				log.Printf("feedback %s: reply sent, replied_at not written: %v", num, err)
			} else if ok {
				log.Printf("feedback %s: reply reached its person's session", num)
			}
			return
		case "failed":
			continue // that session is gone or refused: the next one
		default:
			// not known whether it landed: never send it a second way now —
			// this session is asked again next pass, while it is there
			return
		}
	}
}

func (s *Server) feedbackWait() time.Duration {
	if s.Feedback != nil && s.Feedback.ReplyWait > 0 {
		return s.Feedback.ReplyWait
	}
	return feedbackReplyWait
}

// runFeedbackReplies polls GitHub every 5 minutes and sends waiting replies
// every minute, on the leader.
func (s *Server) runFeedbackReplies(ctx context.Context) {
	d := s.Feedback
	poll := time.NewTicker(feedbackReplyPollEvery)
	send := time.NewTicker(feedbackReplySendEvery)
	defer poll.Stop()
	defer send.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-poll.C:
			if s.Elector != nil && !s.Elector.Leader(ctx, "feedback-reply") {
				continue
			}
			s.feedbackPollCloses(ctx, d.now())
		case <-send.C:
			if s.Elector != nil && !s.Elector.Leader(ctx, "feedback-reply") {
				continue
			}
			s.feedbackSendReplies(ctx, d.now())
		}
	}
}
