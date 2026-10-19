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

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Settling legacy task records (claude-fleet#4867): a version-0 record has no
// state that ends it, so every one once attached to a worker blocks the repo's
// authority switch as "legacy task owner is unverified" forever.
//
//	POST /v1/node/tasks/settle {repo, apply?} → {repo, apply, settled, kept, items}
//
// A record is settled (state closed) only when its issue is closed — the hub's
// own ticket, else GitHub read now — AND its worker holds nothing on the hub's
// books (store.LegacyWorkerLive, re-read in the write). Dry by default; every
// other record is counted by why it was kept. A node settles only its owner's
// records (the operator's machines: anyone's, like nodeOwnTask).
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
		Repo  string `json:"repo"`
		Apply bool   `json:"apply"`
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
		case t.Issue == "":
			items[i].Why = "no issue on the record"
		default:
			need[t.Issue] = true
		}
	}
	states := s.issueStates(r.Context(), need)
	now := time.Now()
	for i, t := range tasks {
		if items[i].Why != "" {
			continue
		}
		switch st := states[t.Issue]; st {
		case "closed":
		case "open":
			items[i].Why = "issue open"
			continue
		default:
			items[i].Why = "issue state unknown"
			continue
		}
		if !in.Apply {
			items[i].Verdict = "settle"
			continue
		}
		evidence := "settled: issue " + t.Issue + " closed; worker " + t.WorkerID + " holds no lease, start or inventory row (#4867)"
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
	writeJSON(w, http.StatusOK, map[string]any{"repo": repo, "apply": in.Apply, "candidates": len(items),
		"settled": settled, "kept": kept, "items": items})
}

// issueStates reads each issue's state: a hub ticket's own, else GitHub's,
// "" when neither answers within the budget.
func (s *Server) issueStates(ctx context.Context, issues map[string]bool) map[string]string {
	out := map[string]string{}
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
			continue
		}
		wg.Add(1)
		go func(ref, repo string, n int) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-sem }()
			if st, err := src.IssueState(ctx, repo, n); err == nil {
				mu.Lock()
				out[ref] = st
				mu.Unlock()
			}
		}(ref, ref[:i], n)
	}
	wg.Wait()
	return out
}
