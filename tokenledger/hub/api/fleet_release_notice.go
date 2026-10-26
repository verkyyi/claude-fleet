package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// Every train's one line to the person (claude-fleet#4913, EPIC #4810 S1).
// A red train used to stop the lane until the next merge, and said nothing
// beyond its run page. Now the train's `next` job (and the 10-minute backstop,
// release-train-next.yml) judge the run — shipped · flaky (re-sent) · red ·
// held — and say it here, once:
//
//	POST /v1/fleet/release/notice   the release CI's OIDC, as the ledger
//	{"run_id": "…", "sha": "<40 hex>", "verdict": "shipped|flaky|red|held|cancelled|superseded|resent",
//	 "text": "已上线 abc1234 · 含 PR #1 · 合并→生效 12 分钟"}
//
// Every notice is one audit row (release.notice, outcome = verdict). Only a
// notice the person must act on reaches the notifier (FLEET_NOTIFY_CMD, the
// alert channel — never a GitHub issue: EPIC #4895) at once (claude-fleet
// T893): red, a flaky one no re-send saved, held, rolled back, a rollback
// that failed. shipped · superseded · cancelled · resent and a re-sent flaky
// are the audit row alone; the day's shipped trains are ONE line at 09:00
// Beijing (releaseDigestTick). Optional fields shape the two-language line:
//
//	"tests": "x-selftest.sh"  red / flaky     "holds": "#5199"  held
//	"url":   the run's page                     "to": "<40 hex>"  rolledback
//	"action": "dispatch|wait" flaky (dispatch = re-sent ⇒ not pushed)
//
// Nothing gates on it; no notifier ⇒ only the audit row.

const trainNoticeMaxBytes = 4 << 10

// trainNoticeWorkflows may post a notice: the train and its backstop.
// … and the post-release watch (claude-fleet#4915).
var trainNoticeWorkflows = []string{"release-train.yml", "release-train-next.yml", "release-watch.yml"}

var trainNoticeVerdicts = map[string]bool{
	"shipped": true, "flaky": true, "red": true, "held": true,
	"cancelled": true, "superseded": true, "resent": true,
	// the post-release watch (claude-fleet#4915)
	"rolledback": true, "rollback-failed": true,
}

type trainNotice struct {
	RunID   string `json:"run_id"`
	SHA     string `json:"sha"`
	Verdict string `json:"verdict"`
	Text    string `json:"text"`
	Tests   string `json:"tests,omitempty"`
	Holds   string `json:"holds,omitempty"`
	URL     string `json:"url,omitempty"`
	To      string `json:"to,omitempty"`
	Action  string `json:"action,omitempty"`
}

func parseTrainNotice(b []byte) (*trainNotice, error) {
	if len(b) > trainNoticeMaxBytes {
		return nil, fmt.Errorf("%d bytes, at most %d", len(b), trainNoticeMaxBytes)
	}
	var n trainNotice
	if err := json.Unmarshal(b, &n); err != nil {
		return nil, fmt.Errorf("not JSON: %v", err)
	}
	n.RunID, n.Text = runLine(n.RunID, 40), runLine(n.Text, 300)
	n.Tests, n.Holds, n.Action = runLine(n.Tests, 200), runLine(n.Holds, 100), runLine(n.Action, 20)
	if n.URL = runLine(n.URL, 300); n.URL != "" && !strings.HasPrefix(n.URL, "https://") {
		n.URL = ""
	}
	if !release.ValidSHA(n.To) {
		n.To = ""
	}
	switch {
	case n.RunID == "":
		return nil, fmt.Errorf("run_id: missing")
	case !release.ValidSHA(n.SHA):
		return nil, fmt.Errorf("sha: want 40 hex, got %q", runLine(n.SHA, 50))
	case !trainNoticeVerdicts[n.Verdict]:
		return nil, fmt.Errorf("verdict: want shipped|flaky|red|held|cancelled|superseded|resent|rolledback|rollback-failed, got %q", runLine(n.Verdict, 40))
	case n.Text == "":
		return nil, fmt.Errorf("text: missing")
	}
	return &n, nil
}

// handleReleaseNotice serves POST /v1/fleet/release/notice.
func (s *Server) handleReleaseNotice(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil || rs.Publish == nil || s.Store == nil {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	who, err := rs.Publish.CheckFor(r.Context(), r, rs.Repo, trainNoticeWorkflows)
	if err != nil {
		log.Printf("fleet: release notice: %v", err)
		httpError(w, http.StatusUnauthorized, err.Error())
		return
	}
	b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, trainNoticeMaxBytes+1))
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	n, err := parseTrainNotice(b)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.Store.HubAudit("train", "release.notice", n.RunID, n.Verdict, n.SHA[:7]+" "+n.Text, time.Now()); err != nil {
		log.Printf("fleet: release notice %s: audit: %v", n.RunID, err)
	}
	log.Printf("fleet: release notice run %s %s %s by %s: %s", n.RunID, short(n.SHA), n.Verdict, who, n.Text)
	status := "recorded"
	if msg := n.message(); msg != "" {
		s.notify(msg)
		status = "sent"
	}
	writeJSON(w, http.StatusOK, map[string]any{"run_id": n.RunID, "status": status})
}

// message is the line a notice pushes at once, Chinese then English; ""
// for one the person need not act on (it waits for the 09:00 digest, or is
// never said: superseded, cancelled, a re-send).
func (n *trainNotice) message() string {
	sha := short(n.SHA)
	what := n.Tests
	if what == "" {
		what = n.Text
	}
	run := func(zh, en string) (string, string) {
		if n.URL == "" {
			return "", ""
		}
		return "\n" + zh + " › " + n.URL, "\n" + en + " › " + n.URL
	}
	var zh, en string
	switch n.Verdict {
	case "red":
		rz, re := run("点开看运行", "Open the run")
		zh = "【fleet】发布红了 · " + sha + "\n" + what + " 真红，等修复" + rz
		en = "[fleet] Release red · " + sha + "\n" + what + " failed for real — waiting for a fix" + re
	case "flaky":
		if n.Action != "wait" {
			return "" // re-sent: the next train says how it went
		}
		rz, re := run("点开看运行", "Open the run")
		zh = "【fleet】发布红了 · " + sha + "\n" + what + " 不稳，补发也没救回来" + rz
		en = "[fleet] Release red · " + sha + "\n" + what + " is flaky and re-sending did not save it" + re
	case "held":
		holds := n.Holds
		if holds == "" {
			holds = n.Text
		}
		zh = "【fleet】发布被挡住 · " + sha + "\n测完了，" + holds + " 挡着没发"
		en = "[fleet] Release held · " + sha + "\nTested, held by " + holds
	case "rolledback":
		arrow := sha
		if n.To != "" {
			arrow += " → " + short(n.To)
		}
		zh = "【fleet】已回滚 · " + arrow + "\n上线后体检不过，已退回上一版"
		en = "[fleet] Rolled back · " + arrow + "\nPost-release check failed — back on the previous release"
	case "rollback-failed":
		rz, re := run("点开看运行", "Open the run")
		zh = "【fleet】回滚失败 · " + sha + "\n" + n.Text + rz
		en = "[fleet] Rollback failed · " + sha + "\nSomething broke and the automatic rollback failed — handle it by hand" + re
	default:
		return ""
	}
	return zh + "\n\n" + en
}

// The digest: once a day, at releaseDigestHour Beijing, one line for the day
// before — how many trains shipped and with how many PRs, how many went red
// and whether a later one shipped since, whether a hold still stands. One
// line even on a day with nothing; the release.digest audit row (target = the
// day) is what makes it once.
const (
	releaseDigestHour = 9
	releaseDigestTZ   = "Asia/Shanghai"
)

var (
	noticePRRe   = regexp.MustCompile(`#\d+`)
	noticeMoreRe = regexp.MustCompile(`等 (\d+) 个`)
)

// noticePRs counts the PRs a shipped line names (fleet-train-next.py's
// 「含 PR #1 #2 等 N 个」).
func noticePRs(text string) int {
	i := strings.Index(text, "含 PR")
	if i < 0 {
		return 0
	}
	text = text[i:]
	if m := noticeMoreRe.FindStringSubmatch(text); m != nil {
		n, _ := strconv.Atoi(m[1])
		return n
	}
	if j := strings.Index(text, " · "); j >= 0 {
		text = text[:j]
	}
	return len(noticePRRe.FindAllString(text, -1))
}

func releaseDigestLoc() *time.Location {
	if loc, err := time.LoadLocation(releaseDigestTZ); err == nil {
		return loc
	}
	return time.FixedZone("CST", 8*3600)
}

// releaseDigestTick sends yesterday's digest once now is past 09:00 Beijing.
// It runs on the alerts leader's sweep; it reports whether it sent.
func (s *Server) releaseDigestTick(now time.Time) bool {
	if s.Releases == nil || s.Store == nil {
		return false
	}
	loc := releaseDigestLoc()
	local := now.In(loc)
	if local.Hour() < releaseDigestHour {
		return false
	}
	today := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
	day := today.AddDate(0, 0, -1)
	key := day.Format("2006-01-02")
	sent, err := s.Store.HubAuditByAction("release.digest", day)
	if err != nil {
		log.Printf("fleet: release digest: %v", err)
		return false
	}
	for _, e := range sent {
		if e.Target == key {
			return false
		}
	}
	rows, err := s.Store.HubAuditByAction("release.notice", day)
	if err != nil {
		log.Printf("fleet: release digest: %v", err)
		return false
	}
	msg := s.releaseDigest(rows, day, today)
	if err := s.Store.HubAudit("hub", "release.digest", key, "sent", msg, now); err != nil {
		log.Printf("fleet: release digest %s: audit: %v", key, err)
		return false // unrecorded ⇒ not sent, or it would go every tick
	}
	s.notify(msg)
	return true
}

// releaseDigest is the line for [day, end) out of the release.notice rows
// from day on (the rows after end only say whether a red got fixed since and
// whether a hold still stands).
func (s *Server) releaseDigest(rows []store.HubAuditEntry, day, end time.Time) string {
	var shipped, prs, red int
	var lastRed, lastShip, lastHeld time.Time
	for _, e := range rows {
		in := !e.Created.Before(day) && e.Created.Before(end)
		text := e.Detail
		if i := strings.IndexByte(text, ' '); i >= 0 {
			text = text[i+1:]
		}
		switch e.Outcome {
		case "shipped":
			lastShip = e.Created
			if in {
				shipped++
				prs += noticePRs(text)
			}
		case "red", "rollback-failed":
			lastRed = e.Created
			if in {
				red++
			}
		case "flaky":
			if strings.Contains(text, "没有补发") {
				lastRed = e.Created
				if in {
					red++
				}
			}
		case "held":
			lastHeld = e.Created
		}
	}
	var zh, en []string
	if shipped == 0 {
		zh = append(zh, "【fleet】昨天没有上线")
		en = append(en, "[fleet] Yesterday: no releases")
	} else {
		zh = append(zh, fmt.Sprintf("【fleet】昨天上线 %d 次 · 含 %d 个 PR", shipped, prs))
		en = append(en, fmt.Sprintf("[fleet] Yesterday: %d releases · %d PRs", shipped, prs))
	}
	var rz, re string
	switch {
	case red == 0:
		rz, re = "没有红", "nothing red"
	case lastShip.After(lastRed):
		rz, re = fmt.Sprintf("红 %d 次，都已补好", red), fmt.Sprintf("%d red, all fixed since", red)
	default:
		rz, re = fmt.Sprintf("红 %d 次，还没补好", red), fmt.Sprintf("%d red, not fixed yet", red)
	}
	if !lastHeld.IsZero() && lastHeld.After(lastShip) {
		rz, re = rz+"；有挡着的", re+"; a release is held"
	} else {
		rz, re = rz+"；没有挡着的", re+"; nothing held"
	}
	zh, en = append(zh, rz), append(en, re)
	if u := s.humanURL(nil); u != "" {
		zh = append(zh, "点开看清单 › "+u+"/admin/release")
		en = append(en, "Open the list › "+u+"/admin/release")
	}
	return strings.Join(zh, "\n") + "\n\n" + strings.Join(en, "\n")
}
