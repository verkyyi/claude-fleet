package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

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
// The line goes to the hub's notifier (FLEET_NOTIFY_CMD, the alert channel —
// never a GitHub issue: EPIC #4895 retires the auto-filed ones) and the audit
// log. Nothing gates on it; no notifier ⇒ only the audit row.

const trainNoticeMaxBytes = 4 << 10

// trainNoticeWorkflows may post a notice: the train and its backstop.
var trainNoticeWorkflows = []string{"release-train.yml", "release-train-next.yml"}

var trainNoticeVerdicts = map[string]bool{
	"shipped": true, "flaky": true, "red": true, "held": true,
	"cancelled": true, "superseded": true, "resent": true,
}

type trainNotice struct {
	RunID   string `json:"run_id"`
	SHA     string `json:"sha"`
	Verdict string `json:"verdict"`
	Text    string `json:"text"`
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
	switch {
	case n.RunID == "":
		return nil, fmt.Errorf("run_id: missing")
	case !release.ValidSHA(n.SHA):
		return nil, fmt.Errorf("sha: want 40 hex, got %q", runLine(n.SHA, 50))
	case !trainNoticeVerdicts[n.Verdict]:
		return nil, fmt.Errorf("verdict: want shipped|flaky|red|held|cancelled|superseded|resent, got %q", runLine(n.Verdict, 40))
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
	s.notify("发布列车 · " + n.Text)
	writeJSON(w, http.StatusOK, map[string]any{"run_id": n.RunID, "status": "sent"})
}
