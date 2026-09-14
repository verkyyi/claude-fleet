// internal/api/repo.go
package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

// maxRepoBody caps one repo snapshot. A first ship of a 2,688-issue backlog is
// roughly 1 MB of JSON; this leaves two orders of magnitude of headroom and
// still refuses a runaway shipper.
const maxRepoBody = 16 << 20

// defaultRepoDays is the flow window when the caller names none. Long enough
// that weekly flow has several points, short enough to stay cheap.
const defaultRepoDays = 90

// handleRepoIngest accepts one repository snapshot.
//
// It sits beside /v1/ingest rather than inside it, and that is a deliberate
// split. A usage batch is authenticated as an endpoint AND carries an
// identity: a machine, an OS login, a subscription. A repo shipper has none of
// those — it is a cron job with a GitHub token, and forcing it to invent an
// account_uuid to be let in would put a fabricated attribution on every row it
// writes. What the two DO share is the credential: an enrollment token, minted
// per shipper and revocable on its own, so a leaked repo shipper cannot read
// the dashboard and cannot be used to push usage either.
//
// The hub is a sink. Producing these facts — which repositories, which
// credentials, how often, behind which firewall — is a per-team concern, and
// keeping the collector out of this binary is what stops hub releases from
// being coupled to collection logic.
func (s *Server) handleRepoIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	tok := bearer(r)
	if tok == "" {
		httpError(w, http.StatusUnauthorized, "missing bearer token")
		return
	}
	ep, err := s.Store.EndpointByTokenHash(HashToken(tok))
	if err != nil {
		// Same deliberate vagueness as /v1/ingest: distinguishing "unknown
		// token" from "known token, other failure" tells a prober which
		// guesses were close.
		httpError(w, http.StatusUnauthorized, "unrecognised enrollment token")
		return
	}

	var snap model.RepoSnapshot
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRepoBody))
	if err := dec.Decode(&snap); err != nil {
		httpError(w, http.StatusBadRequest, "malformed snapshot: "+err.Error())
		return
	}
	// A 400, not a 500. Everything Validate rejects is a shipper bug the
	// shipper can fix, and answering "internal error" would send whoever wrote
	// it reading hub logs instead of their own payload.
	if err := snap.Validate(time.Now()); err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}

	issues, days, err := s.Store.UpsertRepoSnapshot(snap)
	if err != nil {
		log.Printf("repo ingest from %s: %v", ep.ID, err)
		httpError(w, http.StatusInternalServerError, "could not store snapshot")
		return
	}
	// This token is a repo shipper, not an agent. Say so, or the fleet roster
	// and the stale-agent finding spend forever reporting a machine that never
	// reports usage -- which is what this one is for.
	//
	// After the snapshot, and non-fatal: the facts are already stored, and
	// failing the push over a label would make a cosmetic problem into a
	// data-loss one.
	if err := s.Store.MarkRepoShipper(ep.ID); err != nil {
		log.Printf("mark repo shipper %s: %v", ep.ID, err)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"repo": snap.Repo, "issues": issues, "days": days,
	})
}

// handleRepos lists the repositories the hub holds progress for.
func (s *Server) handleRepos(w http.ResponseWriter, r *http.Request) {
	repos, err := s.Store.Repos()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if repos == nil {
		repos = []store.Repo{}
	}
	writeJSON(w, http.StatusOK, repos)
}

// handleRepoFlow serves the day rows plus the repo's own close-time scale.
//
// The scale travels with the data rather than being fetched separately,
// because every number in the response is meaningless without it: "149 issues
// past p95" is a fact, "149 issues older than 30 days" is a number about a
// constant somebody picked.
func (s *Server) handleRepoFlow(w http.ResponseWriter, r *http.Request) {
	repo, start, end, ok := repoScope(w, r)
	if !ok {
		return
	}
	days, err := s.Store.RepoDays(repo, start, end)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if days == nil {
		days = []model.RepoDay{}
	}
	scale, err := s.Store.RepoCloseScale(repo)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"repo":  repo,
		"since": start.UTC().Format(model.RepoDayLayout),
		"until": end.UTC().Format(model.RepoDayLayout),
		"days":  days,
		// Null when no shipper has ever computed percentiles. Readers must
		// render that as "scale unknown" and must not substitute one.
		"scale": scale,
	})
}

// handleRepoIssues serves the backlog, oldest first.
//
// `stale=1` is the only way to ask for "too old" — the threshold is always the
// repo's own p95, never a number in the query string. Letting a caller pass a
// day count would reintroduce exactly the hardcoded scale this feature exists
// to remove, one URL at a time.
func (s *Server) handleRepoIssues(w http.ResponseWriter, r *http.Request) {
	// The repo name, and deliberately not a range: this endpoint answers about
	// the backlog as it stands, so there is no window to scope. Parsing
	// since/until here and then not using them would be worse than not
	// accepting them — a caller would get a confidently wrong answer to a
	// question the handler never asked.
	repo, ok := repoName(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()

	f := store.RepoIssueFilter{Repo: repo, State: q.Get("state"), Now: time.Now()}
	if f.State != "" && f.State != model.RepoStateOpen && f.State != model.RepoStateClosed {
		httpError(w, http.StatusBadRequest, "state: want open or closed")
		return
	}
	f.ShippedOnly = q.Get("shipped") == "1"
	f.Limit = 200
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > 1000 {
			httpError(w, http.StatusBadRequest, "limit: want 1..1000")
			return
		}
		f.Limit = n
	}

	scale, err := s.Store.RepoCloseScale(repo)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	stale := q.Get("stale") == "1"
	if stale {
		// No scale means no honest answer. Refusing is the point: a fallback
		// threshold here would be a fabricated claim about this repo, and the
		// caller cannot tell a fabricated one from a measured one.
		if scale == nil || scale.P95Seconds == nil {
			httpError(w, http.StatusConflict,
				"no close-time percentiles have been shipped for "+repo+
					": staleness has no scale to be measured against")
			return
		}
		f.MinAgeSeconds = *scale.P95Seconds
	}

	rows, err := s.Store.RepoIssues(f)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if rows == nil {
		rows = []store.RepoIssueRow{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"repo": repo, "stale": stale, "issues": rows, "scale": scale,
	})
}

// repoScope reads the repo name and the day range every repo endpoint shares.
//
// A malformed range is a 400 rather than a silently substituted default, for
// the same reason it is on the usage side: showing the wrong week with
// confidence is worse than showing an error.
func repoScope(w http.ResponseWriter, r *http.Request) (repo string, start, end time.Time, ok bool) {
	repo, ok = repoName(w, r)
	if !ok {
		return "", time.Time{}, time.Time{}, false
	}
	q := r.URL.Query()
	now := time.Now().UTC()
	end = now.AddDate(0, 0, 1) // exclusive, so today's own row is included
	if v := q.Get("until"); v != "" {
		t, valid := parseWhen(v, now)
		if !valid {
			httpError(w, http.StatusBadRequest, "until: want RFC3339 or a relative duration like 7d")
			return "", time.Time{}, time.Time{}, false
		}
		end = t
	}
	start = end.AddDate(0, 0, -defaultRepoDays)
	if v := q.Get("since"); v != "" {
		t, valid := parseWhen(v, now)
		if !valid {
			httpError(w, http.StatusBadRequest, "since: want RFC3339 or a relative duration like 7d")
			return "", time.Time{}, time.Time{}, false
		}
		start = t
	}
	if !start.Before(end) {
		httpError(w, http.StatusBadRequest, "since must be before until")
		return "", time.Time{}, time.Time{}, false
	}
	return repo, start, end, true
}

// repoName reads the required repository, refusing anything that is not the
// owner/name spelling GitHub uses.
//
// Required rather than defaulted: a backlog blended across repositories would
// be scaled by one repo's percentiles and read as though it applied to all of
// them, which is the one mistake every surface here is built to prevent.
func repoName(w http.ResponseWriter, r *http.Request) (string, bool) {
	repo := r.URL.Query().Get("repo")
	if err := model.ValidRepoName(repo); err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return "", false
	}
	return repo, true
}
