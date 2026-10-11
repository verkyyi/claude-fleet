package api

import (
	"encoding/json"
	"net/http"
	"sort"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// CIRunnersPath lists every machine's test runner (claude-fleet#3144, EPIC
// #3139 C5) as its machine link last said it: the train's macOS job (C6) reads
// it to decide whether a machine of ours can take the run or GitHub's must.
const CIRunnersPath = "/v1/fleet/ci-runners"

// ciRunnerStale: a machine link unheard this long no longer speaks for its
// runner — `online: false`, whatever it said last.
const ciRunnerStale = 3 * time.Minute

// CIRunnerView is one machine's runner.
type CIRunnerView struct {
	Machine string                 `json:"machine"`
	Online  bool                   `json:"online"`
	HeardAt *time.Time             `json:"heard_at,omitempty"`
	Runner  control.CIRunnerStatus `json:"runner"`
}

// CIRunners is the answer: every machine with a runner, and how many are
// online and idle (ready to take a job now).
type CIRunners struct {
	At      time.Time      `json:"at"`
	Runners []CIRunnerView `json:"runners"`
	Idle    int            `json:"idle"`
	Online  int            `json:"online"`
}

func (s *Server) ciRunners(now time.Time) (CIRunners, error) {
	out := CIRunners{At: now.UTC(), Runners: []CIRunnerView{}}
	rows, err := s.Store.Nodes()
	if err != nil {
		return out, err
	}
	best := map[string]CIRunnerView{}
	for _, n := range rows {
		if n.StatusJSON == "" {
			continue
		}
		var hb struct {
			CIRunner *control.CIRunnerStatus `json:"ci_runner"`
		}
		if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil || hb.CIRunner == nil {
			continue
		}
		old, ok := best[n.Hostname]
		if ok && (n.LastHeartbeat == nil || (old.HeardAt != nil && !n.LastHeartbeat.After(*old.HeardAt))) {
			continue
		}
		v := CIRunnerView{Machine: n.Hostname, HeardAt: n.LastHeartbeat, Runner: *hb.CIRunner}
		v.Online = n.LastHeartbeat != nil && now.Sub(*n.LastHeartbeat) <= ciRunnerStale
		best[n.Hostname] = v
	}
	for _, v := range best {
		out.Runners = append(out.Runners, v)
		if v.Online {
			out.Online++
			if v.Runner.State == "idle" {
				out.Idle++
			}
		}
	}
	sort.Slice(out.Runners, func(i, j int) bool { return out.Runners[i].Machine < out.Runners[j].Machine })
	return out, nil
}

func (s *Server) handleCIRunners(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	v, err := s.ciRunners(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, v)
}
