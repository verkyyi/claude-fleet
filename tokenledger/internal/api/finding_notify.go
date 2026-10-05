package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/findings"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/i18n"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Findings reach WeCom (claude-fleet#1469, EPIC #1665 C2).
//
// A finding used to live only on the entrance page and the /credentials
// banner — a 5-second poll by whoever happened to be looking. A setup token
// running out, a Codex account whose refresh died at 23:46, were discovered the
// next morning when a switch ran into them (EPIC #1665 measured it: ~10 hours).
// This pushes every warning / critical finding of the "now" view to a WeCom
// group robot, so it reaches the operator's phone within a minute.
//
// What keeps that from being a message every 5 seconds — the DEDUP RULES, in
// one place, backed by store.finding_notices:
//
//   - the unit is the finding's PROBLEM (Finding.Problem: kind + subject,
//     without severity or template). A problem is announced ONCE when first
//     seen, and the row remembers the id and severity it was announced at.
//   - the same problem back with a MORE SEVERE id (a token's 30-day warning
//     turning critical in its last week) is announced again, as an
//     escalation; the same severity with another sentence (expiring →
//     expired) likewise; a LESS severe one is recorded silently — nobody
//     needs a push to hear it got better before it is gone.
//   - a problem still standing after Repeat (CCQUOTA_WECOM_REPEAT_HOURS, 6 h,
//     the operator's interval; 0 = never) is reminded, once per interval.
//   - a problem that has GONE is announced as recovered — for the kinds whose
//     clearing means a person acted or a machine came back (recoverKinds);
//     a rate-limit window cooling off on its own is not news — and its row
//     is dropped, so it would be "new" again if it came back.
//   - a MUTED finding is a problem the operator has already dealt with: it is
//     neither announced nor reminded while the mute holds, and it does not
//     count as gone. Info findings are never pushed.
//   - the findings are evaluated UNCAPPED (findings.NowInputs.Uncapped): the
//     page's cap of eight would let the ninth problem flap between "new" and
//     "recovered" as the ones above it came and went.
//
// A tick that cannot reach the webhook records nothing for what it failed to
// send (so it is retried) and backs off notifyBackoff before trying again;
// at most maxPerTick messages go out per tick — a robot takes 20 a minute,
// and a hub that has just gained the webhook may have a backlog.
//
// The webhook URL carries the robot's key. It comes from the environment only
// (CCQUOTA_WECOM_WEBHOOK, like the SSO secrets), is never logged — net/http's
// errors print the URL, so they are unwrapped before they reach the log — and
// never enters a config file or a page.

// notifyTick is how often the notifier evaluates. A minute is well inside the
// EPIC's ≤ 5 minutes and far above anything a robot would mind.
const notifyTick = time.Minute

// notifyBackoff is how long a failed send pauses the notifier.
const notifyBackoff = 5 * time.Minute

// maxPerTick bounds the messages one tick sends.
const maxPerTick = 10

// defaultNotifyRepeat is CCQUOTA_WECOM_REPEAT_HOURS's default.
const defaultNotifyRepeat = 6 * time.Hour

// recoverKinds are the finding kinds whose disappearance is worth a message:
// each one clears only because a person acted (a token re-imported, a login
// redone, the vault unlocked) or a machine came back.
var recoverKinds = map[string]bool{
	"cred_vault_locked": true, "cred_setup_token": true, "account_login": true, "stale_agent": true,
}

// FindingNotifier is the WeCom side of the findings page: what to send where.
// Nil on the Server means off, and the hub is byte for byte what it was.
type FindingNotifier struct {
	Webhook string        // the group robot's webhook URL (a secret: it carries the key)
	Repeat  time.Duration // remind about a standing problem this often; 0 = never
	HubURL  string        // prefix for a finding's Link in the message, "" = no link
	Locale  string        // the language the messages are written in (i18n.ZhCN)
	Client  *http.Client

	retryAt time.Time
}

// FindingNotifierFromEnv reads CCQUOTA_WECOM_WEBHOOK (unset ⇒ nil, off),
// CCQUOTA_WECOM_REPEAT_HOURS (6; 0 = once only) and CCQUOTA_WECOM_LOCALE
// (zh-CN). hubURL is the public address links are built on.
func FindingNotifierFromEnv(getenv func(string) string, hubURL string) (*FindingNotifier, error) {
	wh := strings.TrimSpace(getenv("CCQUOTA_WECOM_WEBHOOK"))
	if wh == "" {
		return nil, nil
	}
	u, err := url.Parse(wh)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		// The value is a secret: the error says what is wrong, not what it was.
		return nil, errors.New("CCQUOTA_WECOM_WEBHOOK is not an http(s) URL")
	}
	n := &FindingNotifier{Webhook: wh, Repeat: defaultNotifyRepeat, HubURL: strings.TrimRight(hubURL, "/"), Locale: i18n.ZhCN,
		Client: &http.Client{Timeout: 10 * time.Second}}
	if v := strings.TrimSpace(getenv("CCQUOTA_WECOM_REPEAT_HOURS")); v != "" {
		h, err := strconv.ParseFloat(v, 64)
		if err != nil || h < 0 {
			return nil, fmt.Errorf("CCQUOTA_WECOM_REPEAT_HOURS=%q: want a number of hours ≥ 0", v)
		}
		n.Repeat = time.Duration(h * float64(time.Hour))
	}
	if v := strings.TrimSpace(getenv("CCQUOTA_WECOM_LOCALE")); v != "" {
		n.Locale = i18n.Normalize(v)
	}
	return n, nil
}

// RunFindingNotify evaluates on notifyTick until ctx ends. A no-op without a
// notifier.
func (s *Server) RunFindingNotify(ctx context.Context) {
	if s.Notifier == nil {
		return
	}
	t := time.NewTicker(notifyTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			s.FindingNotifyTick(now.UTC())
		}
	}
}

// FindingNotifyTick is one evaluation at now: the "now" findings over every
// account, uncapped, reconciled against what was already said.
func (s *Server) FindingNotifyTick(now time.Time) {
	n := s.Notifier
	if n == nil || now.Before(n.retryAt) {
		return
	}
	in, err := s.GatherNow(store.AllAccounts)
	if err != nil {
		log.Printf("findings notify: gather: %v", err)
		return
	}
	in.Now, in.Uncapped = now, true
	n.reconcile(s.Store, findings.Now(in), now)
}

// notice is one message's cause.
type notice struct {
	kind    string // new | escalated | changed | reminder | recovered
	finding findings.Finding
	prev    store.FindingNotice
}

// reconcile applies the dedup rules above to fs and sends what they call for.
func (n *FindingNotifier) reconcile(st *store.Store, fs []findings.Finding, now time.Time) {
	notices, err := st.FindingNotices()
	if err != nil {
		log.Printf("findings notify: read ledger: %v", err)
		return
	}
	live := map[string]bool{}
	for _, f := range fs {
		live[f.Problem] = true
	}
	sent := 0
	for _, f := range fs {
		if f.Severity == "info" || f.Muted != nil {
			continue
		}
		prev, had := notices[f.Problem]
		var kind string
		switch {
		case !had:
			kind = "new"
		case prev.FindingID == f.ID:
			if n.Repeat > 0 && now.Sub(prev.LastAt) >= n.Repeat {
				kind = "reminder"
			}
		case severityRank(f.Severity) < severityRank(prev.Severity):
			kind = "escalated"
		case severityRank(f.Severity) == severityRank(prev.Severity):
			kind = "changed"
		default:
			// Quieter than announced: remember that, say nothing.
			prev.FindingID, prev.Severity, prev.Title = f.ID, f.Severity, localizeFinding(f, n.locale()).Title
			if err := st.PutFindingNotice(prev); err != nil {
				log.Printf("findings notify: ledger: %v", err)
			}
		}
		if kind == "" {
			continue
		}
		if sent >= maxPerTick {
			return // the rest next tick: nothing is recorded for them
		}
		if err := n.send(notice{kind: kind, finding: f, prev: prev}, now); err != nil {
			n.fail(now, err)
			return
		}
		sent++
		// The title is kept in the notifier's language: it is what the
		// recovery message will quote, once the finding itself is gone.
		row := store.FindingNotice{Problem: f.Problem, FindingID: f.ID, Kind: f.Kind, Severity: f.Severity,
			Title: localizeFinding(f, n.locale()).Title, FirstAt: now, LastAt: now}
		if had {
			row.FirstAt = prev.FirstAt
		}
		if err := st.PutFindingNotice(row); err != nil {
			log.Printf("findings notify: ledger: %v", err)
		}
	}
	// Recovered: announced, no longer present.
	gone := make([]string, 0, len(notices))
	for p := range notices {
		if !live[p] {
			gone = append(gone, p)
		}
	}
	sort.Strings(gone)
	for _, p := range gone {
		prev := notices[p]
		if recoverKinds[prev.Kind] {
			if sent >= maxPerTick {
				return
			}
			if err := n.send(notice{kind: "recovered", prev: prev}, now); err != nil {
				n.fail(now, err)
				return
			}
			sent++
		}
		if err := st.DeleteFindingNotice(p); err != nil {
			log.Printf("findings notify: ledger: %v", err)
		}
	}
}

func (n *FindingNotifier) fail(now time.Time, err error) {
	n.retryAt = now.Add(notifyBackoff)
	log.Printf("findings notify: wecom: %v — retrying after %s", err, notifyBackoff)
}

func severityRank(s string) int {
	switch s {
	case "critical":
		return 0
	case "warning":
		return 1
	}
	return 2
}

var (
	severityWords = map[string]i18n.Text{
		"critical": {i18n.EN: "critical", i18n.ZhCN: "严重"},
		"warning":  {i18n.EN: "warning", i18n.ZhCN: "警告"},
	}
	noticeHeads = map[string]i18n.Text{
		"new":       {i18n.EN: "ccquota · {sev}", i18n.ZhCN: "ccquota · {sev}"},
		"escalated": {i18n.EN: "ccquota · escalated to {sev}", i18n.ZhCN: "ccquota · 升级为{sev}"},
		"changed":   {i18n.EN: "ccquota · {sev} (changed)", i18n.ZhCN: "ccquota · {sev}（有变化）"},
		"reminder":  {i18n.EN: "ccquota · still {sev} · {for}", i18n.ZhCN: "ccquota · 仍在{sev} · 已持续 {for}"},
		"recovered": {i18n.EN: "ccquota · recovered", i18n.ZhCN: "ccquota · 已恢复"},
	}
)

// message renders one notice as WeCom markdown: a bold head, the finding's
// sentence in the notifier's language, the detail and the link quoted under
// it. For a recovery the sentence is the one last sent — the finding is gone,
// so there is nothing else to render.
func (n *FindingNotifier) message(x notice, now time.Time) string {
	loc := n.locale()
	var b strings.Builder
	if x.kind == "recovered" {
		b.WriteString("**" + noticeHeads[x.kind].In(loc) + "**\n")
		b.WriteString(x.prev.Title)
		return b.String()
	}
	f := localizeFinding(x.finding, loc)
	args := map[string]string{"sev": severityWords[f.Severity].In(loc)}
	if x.kind == "reminder" {
		args["for"] = humanDuration(now.Sub(x.prev.FirstAt), loc)
	}
	b.WriteString("**" + i18n.Interpolate(noticeHeads[x.kind].In(loc), args) + "**\n")
	b.WriteString(f.Title)
	if f.Detail != "" {
		b.WriteString("\n> " + f.Detail)
	}
	if n.HubURL != "" && f.Link != "" {
		b.WriteString("\n> " + n.HubURL + f.Link)
	}
	return b.String()
}

func (n *FindingNotifier) locale() string {
	if n.Locale == "" {
		return i18n.ZhCN
	}
	return n.Locale
}

// humanDuration is "6h" / "2d 3h" / "45m" in either language.
func humanDuration(d time.Duration, loc string) string {
	d = d.Round(time.Minute)
	days, hours, mins := int(d/(24*time.Hour)), int(d%(24*time.Hour)/time.Hour), int(d%time.Hour/time.Minute)
	zh := i18n.Normalize(loc) == i18n.ZhCN
	switch {
	case days > 0 && zh:
		return fmt.Sprintf("%d天%d小时", days, hours)
	case days > 0:
		return fmt.Sprintf("%dd %dh", days, hours)
	case hours > 0 && zh:
		return fmt.Sprintf("%d小时", hours)
	case hours > 0:
		return fmt.Sprintf("%dh", hours)
	case zh:
		return fmt.Sprintf("%d分钟", mins)
	}
	return fmt.Sprintf("%dm", mins)
}

// wecomMaxContent is the robot API's cap on a markdown message's content.
const wecomMaxContent = 4000

// send posts one markdown message to the robot. The robot answers
// {"errcode":0,"errmsg":"ok"}; anything else is a failure.
func (n *FindingNotifier) send(x notice, now time.Time) error {
	content := n.message(x, now)
	if len(content) > wecomMaxContent {
		content = content[:wecomMaxContent]
	}
	body, _ := json.Marshal(map[string]any{"msgtype": "markdown", "markdown": map[string]string{"content": content}})
	client := n.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Post(n.Webhook, "application/json", bytes.NewReader(body))
	if err != nil {
		// A *url.Error prints the URL — the key with it. Keep the cause only.
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return fmt.Errorf("post: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("webhook answered %d", resp.StatusCode)
	}
	var ans struct {
		Errcode int    `json:"errcode"`
		Errmsg  string `json:"errmsg"`
	}
	if err := json.Unmarshal(raw, &ans); err == nil && ans.Errcode != 0 {
		return fmt.Errorf("webhook refused: %d %s", ans.Errcode, ans.Errmsg)
	}
	return nil
}
