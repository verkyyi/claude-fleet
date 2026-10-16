package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func (s *Server) canRepoAuthority(ctx context.Context, endpoint string) bool {
	if c := s.nodes.get(endpoint); c != nil {
		return c.canRepoAuthority && c.canLaunch
	}
	if p, ok := s.peerOf(ctx, endpoint); ok {
		return p.HasCap(control.CapRepoAuthority) && p.HasCap(control.CapLaunch)
	}
	return false
}

type repoAuthorityNode struct {
	Fleet    string    `json:"fleet_id"`
	Endpoint string    `json:"endpoint_id"`
	Capable  bool      `json:"capable"`
	Observed time.Time `json:"observed_at"`
}

// Only registry observations are accepted. A caller cannot submit a reassuring
// inventory in its manifest. Absent/offline/old nodes are unknown, never drained.
func (s *Server) repoAuthorityInventory(ctx context.Context, c ticketCaller, a store.RepoAuthority) ([]repoAuthorityNode, []store.RepoLegacyOwner, []string, error) {
	nodes, owners, blockers := []repoAuthorityNode{}, []store.RepoLegacyOwner{}, []string{}
	fs, err := s.Store.Fleets()
	if err != nil {
		return nil, nil, nil, err
	}
	for _, f := range fs {
		if !fleetHosts(f, a.Repo) {
			continue
		}
		ep, e := s.Store.EndpointByID(f.EndpointID)
		if e != nil || ep == nil || (!c.all && s.nodeTaskOwner(ep) != c.owner) {
			blockers = append(blockers, "repo has an unknown or foreign host")
			continue
		}
		capable := s.canRepoAuthority(ctx, f.EndpointID)
		nodes = append(nodes, repoAuthorityNode{f.FleetID, f.EndpointID, capable, f.ObservedAt})
		if !capable || !f.Present || f.State == "unknown" || time.Since(f.ObservedAt) > 2*time.Minute || f.ObservedAt.Before(a.FrozenAt) {
			blockers = append(blockers, "host needs a fresh capable observation: "+f.FleetID)
		}
		ws, ok := parseWorkerSessions(f.FleetID, f.Repo, f.WorkersJSON)
		if !ok {
			blockers = append(blockers, "unknown workers: "+f.FleetID)
			continue
		}
		for _, w := range ws {
			if store.NormRepo(w.Repo) != a.Repo {
				if w.Repo == "" {
					blockers = append(blockers, "worker has no repo identity: "+f.FleetID)
				}
				continue
			}
			known, e := s.Store.TaskExecutionKnown(s.nodeTaskOwner(ep), w.WorkerID)
			if e != nil {
				return nil, nil, nil, e
			}
			if !known {
				owners = append(owners, store.RepoLegacyOwner{WorkerID: w.WorkerID, EndpointID: f.EndpointID})
				blockers = append(blockers, "legacy execution: "+w.WorkerID)
			}
		}
	}
	if len(nodes) == 0 {
		blockers = append(blockers, "no verified host for this repo")
	}
	return nodes, owners, blockers, nil
}

func (s *Server) ticketAuthority(w http.ResponseWriter, r *http.Request, c ticketCaller) {
	repo := store.NormRepo(r.URL.Query().Get("repo"))
	if !leaseRepoRE.MatchString(repo) {
		httpError(w, 400, "select one explicit repo=owner/name")
		return
	}
	a, err := s.Store.RepoAuthority(repo)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	if a.Owner != "" && a.Owner != c.owner {
		httpError(w, 404, "no authority selection of yours")
		return
	}
	if strings.HasSuffix(r.URL.Path, "/start") {
		s.ticketAuthorityStart(w, r, c, repo)
		return
	}
	// A node's pre-start check is a read, not a manifest or a new polling loop.
	if r.Method == http.MethodGet && r.URL.Query().Get("gate") == "1" {
		writeJSON(w, 200, a)
		return
	}
	nodes, owners, blockers, err := s.repoAuthorityInventory(r.Context(), c, a)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	dbBlockers, leaseOwners, err := s.Store.RepoAuthorityBlockers(repo, r.URL.Query().Get("rollback") == "1")
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	blockers = append(blockers, dbBlockers...)
	owners = append(owners, leaseOwners...)
	if r.Method == http.MethodGet {
		tickets, err := s.Store.FleetTickets(store.TicketFilter{Repo: repo, Owner: c.owner, All: c.all, Limit: 500})
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		tasks, err := s.Store.RepoTaskInventory(repo, c.owner)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{"authority": a, "nodes": nodes, "legacy_owners": owners, "blockers": blockers, "tickets": tickets, "tickets_may_be_truncated": len(tickets) == 500, "tasks": tasks, "dry_run": true, "live_acceptance": "unverified"})
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, 405, "GET manifest or POST authority transition")
		return
	}
	if strings.HasSuffix(r.URL.Path, "/adopt") {
		var in struct {
			Source   string `json:"source"`
			Title    string `json:"title"`
			Body     string `json:"body"`
			Revision int64  `json:"expected_revision"`
		}
		if !decodeTicket(w, r, &in) {
			return
		}
		if len(blockers) > 0 {
			httpError(w, 409, "drain/verify legacy owners before selective adoption")
			return
		}
		m, e := s.Store.AdoptRepoTicket(repo, c.owner, in.Source, in.Title, in.Body, in.Revision, time.Now())
		if e != nil {
			httpError(w, 409, e.Error())
			return
		}
		writeJSON(w, 200, m)
		return
	}
	var change store.RepoAuthorityChange
	if !decodeTicket(w, r, &change) {
		return
	}
	if !idemRE.MatchString(change.Key) {
		httpError(w, 400, "idempotency_key is required")
		return
	}
	change.Owners = owners
	if change.Action == "stop_ack" {
		ep, _ := s.nodeAuthOpt(r)
		if ep == nil {
			httpError(w, 403, "native stop must be acknowledged by its node")
			return
		}
		change.EndpointID = ep.ID
		var proof struct {
			WorkerID      string `json:"worker_id"`
			PID           int    `json:"pid"`
			Birth         string `json:"birth"`
			Executable    string `json:"executable"`
			NativeSession string `json:"native_session"`
			Stopped       bool   `json:"execution_stopped"`
		}
		if json.Unmarshal([]byte(change.Evidence), &proof) != nil || proof.WorkerID != change.WorkerID || proof.PID <= 0 || proof.Birth == "" || proof.Executable == "" || proof.NativeSession == "" || !proof.Stopped {
			httpError(w, 400, "a verified native stop receipt is required")
			return
		}
	} else if (change.Action == "apply" && a.Mode != "hub") || (change.Action == "rollback" && a.Mode != "legacy") {
		if len(blockers) > 0 {
			writeJSON(w, 409, map[string]any{"error": "drain/verify all owners and hosts first", "blockers": blockers})
			return
		}
	} else if change.Action == "freeze" {
		// All registered hosts must know the new local dispatch rail before
		// relying on the central freeze. Active owners themselves may drain.
		if len(nodes) == 0 {
			httpError(w, 409, "no registered capable host")
			return
		}
		for _, n := range nodes {
			if !n.Capable {
				httpError(w, 409, "upgrade every repo host before freeze")
				return
			}
		}
	}
	a, err = s.Store.ChangeRepoAuthority(repo, c.owner, change, time.Now())
	if err != nil {
		code := 409
		if errors.Is(err, store.ErrTaskInvalid) {
			code = 400
		}
		httpError(w, code, err.Error())
		return
	}
	writeJSON(w, 200, a)
}

func (s *Server) ticketAuthorityStart(w http.ResponseWriter, r *http.Request, c ticketCaller, repo string) {
	ep, _ := s.nodeAuthOpt(r)
	if ep == nil || r.Method != http.MethodPost {
		httpError(w, 403, "local reservation needs its authenticated node")
		return
	}
	fs, err := s.Store.Fleets()
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	hosted := false
	for _, f := range fs {
		if f.EndpointID == ep.ID && fleetHosts(f, repo) {
			hosted = true
		}
	}
	if !hosted {
		httpError(w, 403, "node does not host this repo")
		return
	}
	var in struct {
		Action  string                    `json:"action"`
		Key     string                    `json:"reservation"`
		Worker  string                    `json:"worker_id"`
		Native  *store.RepoNativeIdentity `json:"native_identity"`
		Stopped bool                      `json:"execution_stopped"`
	}
	if !decodeTicket(w, r, &in) {
		return
	}
	if !idemRE.MatchString(in.Key) || (in.Action == "stopped" && !in.Stopped) {
		httpError(w, 400, "reservation / native stop proof required")
		return
	}
	if in.Worker != "" {
		owned := false
		for _, f := range fs {
			if f.EndpointID == ep.ID && fleetHosts(f, repo) && strings.HasPrefix(in.Worker, f.FleetID+"/") {
				owned = true
			}
		}
		if !owned {
			httpError(w, 403, "worker belongs to another node")
			return
		}
	}
	start, err := s.Store.RepoLocalStart(repo, c.owner, ep.ID, in.Key, in.Action, in.Worker, in.Native, time.Now())
	if err != nil {
		httpError(w, 409, err.Error())
		return
	}
	writeJSON(w, 200, start)
}

func (s *Server) repoDispatchGate(repo string, accepted bool) error {
	if repo == "" {
		return nil
	}
	a, err := s.Store.RepoAuthority(repo)
	if err != nil {
		return err
	}
	if a.Mode == "frozen" || (a.Mode == "hub" && !accepted) {
		return fault("INVALID_STATE", "repo task authority requires an unfrozen accepted dispatch")
	}
	return nil
}
