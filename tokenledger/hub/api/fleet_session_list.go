package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 我的会话 in the new console (claude-fleet#3927, EPIC #3923 C4).
//
//	GET /v1/fleet/sessions              the viewer's own live sessions — the
//	                                    fleet_sessions answer, on the daily
//	                                    page's cut (ownView: an admin's own too)
//	GET /v1/fleet/sessions?state=ended  the viewer's own ended sessions of the
//	                                    last sessionsEndedWindow, newest first
//
// An ended session is the history ledger row its machine handed the hub when
// it reaped it (fleet_worker_records, kind history — claude-fleet#1609),
// listed only for a fleet the viewer may see (the same FleetScope cut as the
// live list), so a member never reads another person's. Each row carries
// resume_id, the key-form worker_id worker_resume takes through the write
// door; a row whose key is live again (resumed) is left out — it is in the
// live list. Reaping and resuming are the write door's (control.WritePath)
// worker_reap / worker_resume, unchanged.

// FleetSessionListPath is the route.
const FleetSessionListPath = "/v1/fleet/sessions"

// sessionsEndedWindow is how far back the ended list reaches.
const sessionsEndedWindow = 14 * 24 * time.Hour

// sessionsEndedMax is the most ended rows one answer carries.
const sessionsEndedMax = 200

// EndedSession is one row of the ended list.
type EndedSession struct {
	WorkerID    string    `json:"worker_id"`
	ResumeID    string    `json:"resume_id"`
	Key         string    `json:"key"`
	Title       string    `json:"title,omitempty"`
	Repo        string    `json:"repo,omitempty"`
	MachineName string    `json:"machine_name"`
	OSUser      string    `json:"os_user,omitempty"`
	FleetID     string    `json:"fleet_id"`
	State       string    `json:"state,omitempty"` // the ledger's word: landed · closed · …
	EndedAt     time.Time `json:"ended_at"`
}

func (s *Server) handleFleetSessionList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	r = r.WithContext(context.WithValue(r.Context(), ownViewKey{}, true))
	switch r.URL.Query().Get("state") {
	case "", "live":
		out, err := s.CallFleetTool(r, "fleet_sessions", map[string]any{})
		writeFleetResult(w, r, out, err)
	case "ended":
		out, err := s.endedSessions(r, time.Now())
		if err != nil {
			writeFleetResult(w, r, nil, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"sessions": out, "days": int(sessionsEndedWindow / (24 * time.Hour))})
	default:
		httpError(w, http.StatusBadRequest, "state must be live or ended")
	}
}

// endedSessions is the viewer's ended sessions (see above).
func (s *Server) endedSessions(r *http.Request, now time.Time) ([]EndedSession, error) {
	p, err := s.FleetPrincipal(r)
	if err != nil {
		return nil, err
	}
	_, rows, err := s.visibleFleets(p, now)
	if err != nil {
		return nil, err
	}
	fleets := map[string]store.FleetRow{}
	live := map[[2]string]bool{} // (fleet, bare key) a window holds right now
	ids := make([]string, 0, len(rows))
	for _, f := range rows {
		fleets[f.FleetID] = f
		ids = append(ids, f.FleetID)
		var ws []map[string]any
		_ = json.Unmarshal([]byte(f.WorkersJSON), &ws)
		for _, wk := range ws {
			if k, _ := wk["key"].(string); k != "" {
				live[[2]string{f.FleetID, bareKey(k)}] = true
			}
		}
	}
	out := []EndedSession{}
	if len(ids) == 0 {
		return out, nil
	}
	recs, err := s.Store.WorkerRecords(store.WorkerRecordQuery{FleetIDs: ids, Kind: "history",
		Since: now.Add(-sessionsEndedWindow), Content: true, Limit: 5000})
	if err != nil {
		return nil, err
	}
	seen := map[[2]string]int{} // (fleet, key) → its row in out: the newest record wins
	for _, rc := range recs {
		f, ok := fleets[rc.FleetID]
		if !ok {
			continue
		}
		key := rc.Key
		if key == "" && rc.Issue > 0 {
			key = "issue-" + strconv.Itoa(rc.Issue)
		}
		if key == "" {
			continue
		}
		id := [2]string{rc.FleetID, key}
		if live[id] {
			continue
		}
		e := EndedSession{WorkerID: rc.WorkerID, ResumeID: rc.FleetID + "/" + targetKey(key, f, rc.Repo),
			Key: key, Repo: rc.Repo, MachineName: f.Hostname, OSUser: f.OSUser, FleetID: rc.FleetID,
			State: rc.Stage, EndedAt: rc.CreatedAt}
		e.Title, e.EndedAt = ledgerTitle(rc.Content), ledgerTime(rc.Content, rc.CreatedAt)
		if i, ok := seen[id]; ok {
			if e.EndedAt.After(out[i].EndedAt) {
				out[i] = e
			}
			continue
		}
		seen[id] = len(out)
		out = append(out, e)
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].EndedAt.After(out[b].EndedAt) })
	if len(out) > sessionsEndedMax {
		out = out[:sessionsEndedMax]
	}
	return out, nil
}

// bareKey is a window key without its repo slug (`slug:issue-7` → `issue-7`).
func bareKey(k string) string {
	if i := strings.LastIndex(k, ":"); i >= 0 {
		return k[i+1:]
	}
	return k
}

// ledgerCols is a history ledger row's columns (fleet-history.sh: col 1 the
// time it was written, col 3 the title).
func ledgerCols(row []byte) []string {
	line, _, _ := strings.Cut(strings.TrimRight(string(row), "\n"), "\n")
	return strings.Split(line, "\t")
}

func ledgerTitle(row []byte) string {
	c := ledgerCols(row)
	if len(c) < 3 || c[2] == "-" {
		return ""
	}
	return clip(c[2], 200)
}

func ledgerTime(row []byte, def time.Time) time.Time {
	if c := ledgerCols(row); len(c) > 0 {
		if t, err := time.Parse(time.RFC3339, strings.TrimSpace(c[0])); err == nil {
			return t
		}
	}
	return def
}
