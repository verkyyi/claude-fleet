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

// Findings reach the operator's phone (claude-fleet#1469, EPIC #1665 C2) —
// through the cluster's notification service kf-notify (claude-fleet#1705),
// else a bare WeCom group robot.
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
//
// kf-notify (claude-fleet#1705) is the operator's choice since 2026-10-05: with
// CCQUOTA_NOTIFY_URL + CCQUOTA_NOTIFY_KEY set it wins over the webhook (kept
// for one version). The call is the cluster's own convention
// (24haowan-monorepo smoke/notify-post.js): POST <url>/v1/notify, a Bearer key,
// {dest, title, body, source, severity, dedupKey, dedupWindowSec, recovery}.
// The mapping:
//
//   - source   = ccquota:finding:<kind>
//   - dedupKey = ccquota:<Finding.Problem> — one key per problem, across its
//     whole life, so kf-notify's inbox folds an announcement, its reminders and
//     its recovery into one event (a recovery finds its event by that key).
//   - severity = critical → error, warning → warn, a recovery → info (the
//     service only knows info|warn|error).
//   - recovery = true on the 已恢复 message.
//   - dedupWindowSec = kfDedupWindow: the dedup rules above are the real
//     ones; kf-notify's own fold (same key + severity inside its window, 1 h
//     by default) would otherwise swallow a 「有变化」 sent within the hour.
//
// The key is a Bearer secret: environment only, never logged, never in an
// error (the URL carries none, but the error path is the same as the webhook's).

// notifyTick is how often the notifier evaluates. A minute is well inside the
// EPIC's ≤ 5 minutes and far above anything a robot would mind.
const notifyTick = time.Minute

// notifyBackoff is how long a failed send pauses the notifier.
const notifyBackoff = 5 * time.Minute

// maxPerTick bounds the messages one tick sends.
const maxPerTick = 10

// defaultNotifyRepeat is CCQUOTA_WECOM_REPEAT_HOURS's default.
const defaultNotifyRepeat = 6 * time.Hour

// kfDedupWindow is the window kf-notify folds a repeated (dedupKey, severity)
// in. Short: it only has to catch a true duplicate.
const kfDedupWindow = 60

// defaultKfDest is kf-notify's dest when CCQUOTA_NOTIFY_DEST is unset — the
// cluster's default (notify-post.js).
const defaultKfDest = "alerts.prod"

// recoverKinds are the finding kinds whose disappearance is worth a message:
// each one clears only because a person acted (a token re-imported, a login
// redone, the vault unlocked) or a machine came back.
var recoverKinds = map[string]bool{
	"cred_vault_locked": true, "cred_setup_token": true, "account_login": true, "stale_agent": true,
	"compute_region": true,
}

// FindingNotifier is the push side of the findings page: what to send where.
// Nil on the Server means off, and the hub is byte for byte what it was.
// KfURL set ⇒ kf-notify; else Webhook.
type FindingNotifier struct {
	KfURL   string        // kf-notify's base URL (…/v1/notify is appended)
	KfKey   string        // kf-notify's Bearer key (a secret)
	KfDest  string        // kf-notify's dest ("" = alerts.prod)
	Webhook string        // the group robot's webhook URL (a secret: it carries the key)
	Repeat  time.Duration // remind about a standing problem this often; 0 = never
	HubURL  string        // prefix for a finding's Link in the message, "" = no link
	Locale  string        // the language the messages are written in (i18n.ZhCN)
	Client  *http.Client

	retryAt time.Time
}

// FindingNotifierFromEnv reads CCQUOTA_NOTIFY_URL + CCQUOTA_NOTIFY_KEY (+
// CCQUOTA_NOTIFY_DEST) for kf-notify, else CCQUOTA_WECOM_WEBHOOK; neither ⇒
// nil, off. CCQUOTA_NOTIFY_REPEAT_HOURS (6; 0 = once only) and
// CCQUOTA_NOTIFY_LOCALE (zh-CN) each fall back to their CCQUOTA_WECOM_ name.
// hubURL is the public address links are built on.
func FindingNotifierFromEnv(getenv func(string) string, hubURL string) (*FindingNotifier, error) {
	n := &FindingNotifier{Repeat: defaultNotifyRepeat, HubURL: strings.TrimRight(hubURL, "/"), Locale: i18n.ZhCN,
		Client: &http.Client{Timeout: 10 * time.Second}}
	kfURL, kfKey := strings.TrimSpace(getenv("CCQUOTA_NOTIFY_URL")), strings.TrimSpace(getenv("CCQUOTA_NOTIFY_KEY"))
	switch {
	case kfURL != "" && kfKey != "":
		if !isHTTPURL(kfURL) {
			return nil, errors.New("CCQUOTA_NOTIFY_URL is not an http(s) URL")
		}
		n.KfURL, n.KfKey = strings.TrimRight(kfURL, "/"), kfKey
		n.KfDest = strings.TrimSpace(getenv("CCQUOTA_NOTIFY_DEST"))
	case kfURL != "" || kfKey != "":
		// Half a kf-notify config is a mistake, not a choice: say so rather
		// than quietly fall back to the webhook. Names only, never values.
		return nil, errors.New("CCQUOTA_NOTIFY_URL and CCQUOTA_NOTIFY_KEY go together: set both or neither")
	default:
		wh := strings.TrimSpace(getenv("CCQUOTA_WECOM_WEBHOOK"))
		if wh == "" {
			return nil, nil
		}
		if !isHTTPURL(wh) {
			// The value is a secret: the error says what is wrong, not what it was.
			return nil, errors.New("CCQUOTA_WECOM_WEBHOOK is not an http(s) URL")
		}
		n.Webhook = wh
	}
	if name, v := envEither(getenv, "CCQUOTA_NOTIFY_REPEAT_HOURS", "CCQUOTA_WECOM_REPEAT_HOURS"); v != "" {
		h, err := strconv.ParseFloat(v, 64)
		if err != nil || h < 0 {
			return nil, fmt.Errorf("%s=%q: want a number of hours ≥ 0", name, v)
		}
		n.Repeat = time.Duration(h * float64(time.Hour))
	}
	if _, v := envEither(getenv, "CCQUOTA_NOTIFY_LOCALE", "CCQUOTA_WECOM_LOCALE"); v != "" {
		n.Locale = i18n.Normalize(v)
	}
	return n, nil
}

// Channel names where the notifier pushes, for the log: "kf-notify" or "wecom".
func (n *FindingNotifier) Channel() string {
	if n.KfURL != "" {
		return "kf-notify"
	}
	return "wecom"
}

func isHTTPURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Host != ""
}

// envEither is the new name's value, else the old one's, with the name read.
func envEither(getenv func(string) string, name, old string) (string, string) {
	if v := strings.TrimSpace(getenv(name)); v != "" {
		return name, v
	}
	return old, strings.TrimSpace(getenv(old))
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
	log.Printf("findings notify: %s: %v — retrying after %s", n.Channel(), err, notifyBackoff)
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

// send posts one message to kf-notify when it is configured, else to the robot.
func (n *FindingNotifier) send(x notice, now time.Time) error {
	if n.KfURL != "" {
		return n.sendKf(x, now)
	}
	return n.sendWecom(x, now)
}

// kfSeverity maps a finding's severity onto kf-notify's info|warn|error.
var kfSeverity = map[string]string{"critical": "error", "warning": "warn"}

// sendKf posts one notice to kf-notify. Any 2xx is delivered — {ok:true} and
// muted / suppressed / skipped all mean the service took it; anything else
// (a 4xx for a wrong dest or key, a 429, a 5xx) is a failure.
func (n *FindingNotifier) sendKf(x notice, now time.Time) error {
	kind, problem, severity := x.finding.Kind, x.finding.Problem, kfSeverity[x.finding.Severity]
	title := ""
	if x.kind == "recovered" {
		kind, problem, severity = x.prev.Kind, x.prev.Problem, "info"
		title = noticeHeads[x.kind].In(n.locale()) + " · " + x.prev.Title
	} else {
		title = localizeFinding(x.finding, n.locale()).Title
	}
	if severity == "" {
		severity = "warn"
	}
	dest := n.KfDest
	if dest == "" {
		dest = defaultKfDest
	}
	msg := map[string]any{"dest": dest, "title": truncRunes(title, 200), "body": n.message(x, now),
		"source": "ccquota:finding:" + kind, "severity": severity, "dedupKey": "ccquota:" + problem,
		"dedupWindowSec": kfDedupWindow}
	if x.kind == "recovered" {
		msg["recovery"] = true
	}
	body, _ := json.Marshal(msg)
	req, err := http.NewRequest(http.MethodPost, n.KfURL+"/v1/notify", bytes.NewReader(body))
	if err != nil {
		return errors.New("kf-notify: cannot build the request")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+n.KfKey)
	resp, err := n.client().Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return fmt.Errorf("post: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode/100 != 2 {
		// The answer is the service's own words (`未知 dest`, `rate limited`):
		// no secret is echoed back, but keep it short.
		return fmt.Errorf("kf-notify answered %d %s", resp.StatusCode, truncRunes(strings.TrimSpace(string(raw)), 120))
	}
	return nil
}

func truncRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

func (n *FindingNotifier) client() *http.Client {
	if n.Client != nil {
		return n.Client
	}
	return &http.Client{Timeout: 10 * time.Second}
}

// sendWecom posts one markdown message to the robot. The robot answers
// {"errcode":0,"errmsg":"ok"}; anything else is a failure.
func (n *FindingNotifier) sendWecom(x notice, now time.Time) error {
	content := n.message(x, now)
	if len(content) > wecomMaxContent {
		content = content[:wecomMaxContent]
	}
	body, _ := json.Marshal(map[string]any{"msgtype": "markdown", "markdown": map[string]string{"content": content}})
	resp, err := n.client().Post(n.Webhook, "application/json", bytes.NewReader(body))
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
