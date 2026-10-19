package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Settling legacy task records (claude-fleet#4867): a version-0 record has no
// state that ends it, so every one once attached to a worker blocks the repo's
// authority switch as "legacy task owner is unverified" forever.
//
//	POST /v1/node/tasks/settle {repo, apply?, drained?} → {repo, apply, drained, settled, kept, items}
//
// A record is settled (state closed) only when its issue is closed — the hub's
// own ticket, else GitHub read now — AND its worker holds nothing on the hub's
// books (store.LegacyWorkerLive, re-read in the write). Dry by default; every
// other record is counted by why it was kept. A node settles only its owner's
// records (the operator's machines: anyone's, like nodeOwnTask).
//
// drained (claude-fleet T479, the #4830 cutover): the work was stopped on
// purpose and goes on as a hub task, so the issue is still open. The worker
// half alone decides — gone ⇒ closed whatever the issue says (GitHub is not
// asked, the issue is left as it is); a live worker is kept all the same.
const nodeTaskSettleRef = "settle"

// IssueStateSource answers an issue's state on GitHub ("open" / "closed").
// GitHubIssueMeta is one; without it a GitHub issue's state is unknown.
type IssueStateSource interface {
	IssueState(ctx context.Context, repo string, issue int) (string, error)
}

// nodeTaskSettleBudget bounds how long one settle waits on GitHub in all.
const nodeTaskSettleBudget = 60 * time.Second

type taskSettleItem struct {
	Task     string `json:"task"`
	Issue    string `json:"issue,omitempty"`
	WorkerID string `json:"worker_id"`
	Verdict  string `json:"verdict"` // settled | settle (dry) | kept
	Why      string `json:"why,omitempty"`
}

func (s *Server) nodeTaskSettle(w http.ResponseWriter, r *http.Request, owner string) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST "+NodeTasksPath+"/"+nodeTaskSettleRef)
		return
	}
	var in struct {
		Repo    string `json:"repo"`
		Apply   bool   `json:"apply"`
		Drained bool   `json:"drained"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10)).Decode(&in); err != nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object")
		return
	}
	repo := store.NormRepo(in.Repo)
	if !leaseRepoRE.MatchString(repo) {
		httpError(w, http.StatusBadRequest, "select one explicit repo=owner/name")
		return
	}
	scope := owner
	if owner == "operator" {
		scope = ""
	}
	tasks, err := s.Store.LegacySettleCandidates(repo, scope)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	items := make([]taskSettleItem, len(tasks))
	// The worker half first: a live worker keeps its record without asking GitHub.
	need := map[string]bool{}
	for i, t := range tasks {
		items[i] = taskSettleItem{Task: t.Ref, Issue: t.Issue, WorkerID: t.WorkerID, Verdict: "kept"}
		live, err := s.Store.LegacyWorkerLive(repo, t.WorkerID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		switch {
		case live != "":
			items[i].Why = "worker live: " + live
		case in.Drained:
		case t.Issue == "":
			items[i].Why = "no issue on the record"
		default:
			need[t.Issue] = true
		}
	}
	states, whyNot := s.issueStates(r.Context(), need)
	now := time.Now()
	for i, t := range tasks {
		if items[i].Why != "" {
			continue
		}
		var evidence string
		if in.Drained {
			evidence = "drained for authority cutover; issue " + orDefault(t.Issue, "(none)") + " still open, left as is; worker " + t.WorkerID + " holds no lease, start or inventory row (#4867)"
		} else {
			switch st := states[t.Issue]; st {
			case "closed":
			case "open":
				items[i].Why = "issue open"
				continue
			default:
				items[i].Why = "issue state unknown: " + orDefault(whyNot[t.Issue], "no answer")
				continue
			}
			evidence = "settled: issue " + t.Issue + " closed; worker " + t.WorkerID + " holds no lease, start or inventory row (#4867)"
		}
		if !in.Apply {
			items[i].Verdict = "settle"
			continue
		}
		if err := s.Store.SettleLegacyTask(t.ID, t.WorkerID, evidence, now); err != nil {
			if !errors.Is(err, store.ErrTaskConflict) {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			items[i].Why = "changed while settling"
			continue
		}
		items[i].Verdict = "settled"
	}
	kept, settled := map[string]int{}, 0
	for _, it := range items {
		if it.Verdict == "kept" {
			kept[it.Why]++
		} else {
			settled++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"repo": repo, "apply": in.Apply, "drained": in.Drained, "candidates": len(items),
		"settled": settled, "kept": kept, "items": items})
}

// issueStates reads each issue's state: a hub ticket's own, else GitHub's;
// one neither answers within the budget is left out of states and named in
// whyNot (timed out · HTTP 403 rate limit exceeded · no GitHub reader …).
func (s *Server) issueStates(ctx context.Context, issues map[string]bool) (states, whyNot map[string]string) {
	out, why := map[string]string{}, map[string]string{}
	src, _ := s.IssueMeta.(IssueStateSource)
	ctx, cancel := context.WithTimeout(ctx, nodeTaskSettleBudget)
	defer cancel()
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	keys := make([]string, 0, len(issues))
	for k := range issues {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, ref := range keys {
		i := strings.LastIndexByte(ref, '#')
		n, err := strconv.Atoi(ref[i+1:])
		if i <= 0 || err != nil || n <= 0 {
			why[ref] = "not an issue reference"
			continue
		}
		repo := store.NormRepo(ref[:i])
		if t, err := s.Store.FleetTicketAt(repo, int64(n)); err == nil && t.Backend == store.TicketHub {
			mu.Lock()
			out[ref] = t.State
			mu.Unlock()
			continue
		}
		if src == nil {
			why[ref] = "this hub reads no GitHub"
			continue
		}
		wg.Add(1)
		go func(ref, repo string, n int) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				mu.Lock()
				why[ref] = "settle budget spent before asking"
				mu.Unlock()
				return
			}
			defer func() { <-sem }()
			st, err := src.IssueState(ctx, repo, n)
			mu.Lock()
			switch {
			case err != nil:
				why[ref] = err.Error()
			case st != "open" && st != "closed":
				why[ref] = "GitHub answered state " + strconv.Quote(st)
			default:
				out[ref] = st
			}
			mu.Unlock()
		}(ref, ref[:i], n)
	}
	wg.Wait()
	return out, why
}
