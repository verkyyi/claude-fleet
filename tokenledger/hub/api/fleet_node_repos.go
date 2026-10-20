package api

import (
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// NodeReposPath is where a managed machine reads the repos its person's
// machines host between them (claude-fleet T673, 节点选择 C): placement only
// picks among the machines that host a session's repo, so a repo hosted on
// one machine alone has no second candidate. The answer is the UNION of every
// repo the inventory reports on the person's machines — not the client's
// (claude-fleet#4886: a terminal hosts nothing), not a retired login's, not a
// fleet its node stopped reporting — and the caller's own role, so only a
// managed node follows it (bin/fleet-repo-follow.py: it adds what it lacks and
// never removes). Each machine also carries how many sessions the hub sent it
// in the last 24 hours, for the doctor's line.
//
// A login no person owns reads only its own row: there is no person's set to
// follow. Read only — nothing here changes what any node hosts.
const NodeReposPath = "/v1/node/repos"

// NodeRepoMachine is one login of the person's, with what it hosts.
type NodeRepoMachine struct {
	Hostname string   `json:"hostname"`
	Login    string   `json:"login"`
	Role     string   `json:"role,omitempty"` // managed | client | "" (untyped)
	Self     bool     `json:"self,omitempty"`
	Repos    []string `json:"repos"`
	// Starts24h is how many worker_starts the hub placed there in the last
	// 24 hours.
	Starts24h int `json:"starts_24h"`
}

// NodeReposResponse is the body of GET /v1/node/repos.
type NodeReposResponse struct {
	Owner string `json:"owner,omitempty"`
	// Role is the caller's own (managed | client | "").
	Role string `json:"role"`
	// Repos is the person's set: owner/name, each once (case-insensitively,
	// first spelling kept), sorted.
	Repos    []string          `json:"repos"`
	Machines []NodeRepoMachine `json:"machines"`
}

func (s *Server) handleNodeRepos(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	owner := s.nodeTaskOwner(ep)
	fs, err := s.Store.Fleets()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	starts, err := s.Store.FleetStartCounts(time.Now().Add(-24 * time.Hour))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := NodeReposResponse{Owner: owner, Role: s.endpointRole(ep.ID), Repos: []string{}, Machines: []NodeRepoMachine{}}
	type acc struct {
		m    NodeRepoMachine
		seen map[string]bool
	}
	byEP, order := map[string]*acc{}, []string{}
	ownerOf := map[string]string{}
	union := map[string]string{}
	for _, f := range fs {
		if !f.Present {
			continue
		}
		if f.EndpointID != ep.ID {
			if owner == "" {
				continue
			}
			o, ok := ownerOf[f.EndpointID]
			if !ok {
				if e, err := s.Store.EndpointByID(f.EndpointID); err == nil && e != nil && e.RetiredAt == nil {
					o = s.nodeTaskOwner(e)
				}
				ownerOf[f.EndpointID] = o
			}
			if o != owner {
				continue
			}
		}
		a := byEP[f.EndpointID]
		if a == nil {
			a = &acc{m: NodeRepoMachine{Hostname: f.Hostname, Login: f.OSUser, Role: s.endpointRole(f.EndpointID),
				Self: f.EndpointID == ep.ID, Repos: []string{}}, seen: map[string]bool{}}
			byEP[f.EndpointID] = a
			order = append(order, f.EndpointID)
		}
		a.m.Starts24h += starts[f.FleetID]
		for _, repo := range f.HostedRepos() {
			k := strings.ToLower(strings.TrimSpace(repo))
			if !leaseRepoRE.MatchString(k) || a.seen[k] {
				continue
			}
			a.seen[k] = true
			a.m.Repos = append(a.m.Repos, repo)
			if a.m.Role == store.NodeRoleClient {
				continue
			}
			if _, ok := union[k]; !ok {
				union[k] = repo
			}
		}
	}
	keys := make([]string, 0, len(union))
	for k := range union {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out.Repos = append(out.Repos, union[k])
	}
	for _, id := range order {
		m := byEP[id].m
		sort.Slice(m.Repos, func(i, j int) bool { return strings.ToLower(m.Repos[i]) < strings.ToLower(m.Repos[j]) })
		out.Machines = append(out.Machines, m)
	}
	writeJSON(w, http.StatusOK, out)
}
