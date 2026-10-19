package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
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

// repoRetiredHost is a fleet row whose endpoint was retired: it can never
// launch or observe again, so it is no host of the repo (claude-fleet#4831).
type repoRetiredHost struct {
	Fleet     string    `json:"fleet_id"`
	Endpoint  string    `json:"endpoint_id"`
	RetiredAt time.Time `json:"retired_at"`
}

// repoSupersededHost is a fleet row no machine reports any more (present=0)
// whose machine — the same fleet machine, endpoint, or hardware machine_id +
// os_user — has since reported a newer present row of the same repo
// (claude-fleet#4877). That
// machine will never observe this fleet_id again, so it is no host of the repo.
type repoSupersededHost struct {
	Fleet      string    `json:"fleet_id"`
	Endpoint   string    `json:"endpoint_id"`
	ObservedAt time.Time `json:"observed_at"`
	By         string    `json:"superseded_by"`
	ByObserved time.Time `json:"superseded_observed_at"`
}

// supersededBy names the present row that supersedes f, "" when none does. A
// present row is never superseded — a host that is still there but not
// capable keeps blocking. The successor must itself be a live, unretired row
// of the same repo observed AFTER f, on the same machine: the fleet machine that reported both,
// the endpoint, or the endpoint's hardware machine_id + os_user (a re-joined
// login). An endpoint no longer on record falls back to hostname + os_user.
func supersededBy(f store.FleetRow, repo string, fs []store.FleetRow, eps func(string) *store.Endpoint) (store.FleetRow, bool) {
	if f.Present {
		return store.FleetRow{}, false
	}
	epF := eps(f.EndpointID)
	for _, g := range fs {
		if !g.Present || g.FleetID == f.FleetID || !g.ObservedAt.After(f.ObservedAt) || !fleetHosts(g, repo) {
			continue
		}
		epG := eps(g.EndpointID)
		if epG == nil || epG.RetiredAt != nil {
			continue
		}
		same := g.MachineID == f.MachineID ||
			(f.EndpointID != "" && g.EndpointID == f.EndpointID)
		if !same && epF != nil {
			same = epF.MachineID != "" && epF.OSUser != "" && epF.MachineID == epG.MachineID && epF.OSUser == epG.OSUser
		}
		if !same && epF == nil {
			same = f.Hostname != "" && f.OSUser != "" && f.Hostname == g.Hostname && f.OSUser == g.OSUser
		}
		if same {
			return g, true
		}
	}
	return store.FleetRow{}, false
}

// repoClientHost is a fleet row whose endpoint is a client — a person's
// terminal, which runs no task (claude-fleet#4886): a repo it still lists in
// its inventory is a leftover, not a host, so it is listed apart and blocks
// nothing.
type repoClientHost struct {
	Fleet    string `json:"fleet_id"`
	Endpoint string `json:"endpoint_id"`
}

// Only registry observations are accepted. A caller cannot submit a reassuring
// inventory in its manifest. Absent/offline/old nodes are unknown, never drained
// — a RETIRED one is neither: its fleet row is listed apart and blocks nothing,
// and so is a SUPERSEDED one (supersededBy) and a CLIENT's (claude-fleet#4886).
func (s *Server) repoAuthorityInventory(ctx context.Context, c ticketCaller, a store.RepoAuthority) ([]repoAuthorityNode, []store.RepoLegacyOwner, []string, []repoRetiredHost, []repoSupersededHost, []repoClientHost, error) {
	nodes, owners, blockers, retired, superseded, clients := []repoAuthorityNode{}, []store.RepoLegacyOwner{}, []string{}, []repoRetiredHost{}, []repoSupersededHost{}, []repoClientHost{}
	fs, err := s.Store.Fleets()
	if err != nil {
		return nil, nil, nil, nil, nil, nil, err
	}
	epCache := map[string]*store.Endpoint{}
	eps := func(id string) *store.Endpoint {
		if ep, ok := epCache[id]; ok {
			return ep
		}
		ep, e := s.Store.EndpointByID(id)
		if e != nil {
			ep = nil
		}
		epCache[id] = ep
		return ep
	}
	for _, f := range fs {
		if !fleetHosts(f, a.Repo) {
			continue
		}
		ep, e := s.Store.EndpointByID(f.EndpointID)
		if e == nil && ep != nil && ep.RetiredAt != nil {
			if c.all || s.nodeTaskOwner(ep) == c.owner {
				retired = append(retired, repoRetiredHost{f.FleetID, f.EndpointID, *ep.RetiredAt})
			}
			continue
		}
		if e == nil && ep != nil && s.endpointRole(ep.ID) == store.NodeRoleClient {
			if c.all || s.nodeTaskOwner(ep) == c.owner {
				clients = append(clients, repoClientHost{f.FleetID, f.EndpointID})
			}
			continue
		}
		if g, ok := supersededBy(f, a.Repo, fs, eps); ok {
			// Listed to whoever owns its successor (or sees every owner): the
			// successor is the proof, and its owner is the one reading.
			if c.all || s.nodeTaskOwner(eps(g.EndpointID)) == c.owner {
				superseded = append(superseded, repoSupersededHost{f.FleetID, f.EndpointID, f.ObservedAt, g.FleetID, g.ObservedAt})
			}
			continue
		}
		if e != nil || ep == nil || (!c.all && s.nodeTaskOwner(ep) != c.owner) {
			// Only a caller who sees every owner is told WHICH row: a person's
			// manifest never names another person's fleet (claude-fleet#4831).
			why := "repo has an unknown or foreign host"
			if c.all {
				why += ": " + f.FleetID + " (endpoint " + f.EndpointID + ")"
			}
			blockers = append(blockers, why)
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
				return nil, nil, nil, nil, nil, nil, e
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
	return nodes, owners, blockers, retired, superseded, clients, nil
}

// endpointRole is an endpoint's role ("" when unread or never typed).
func (s *Server) endpointRole(endpointID string) string {
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil {
		return ""
	}
	return et.Role
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
	nodes, owners, blockers, retired, superseded, clients, err := s.repoAuthorityInventory(r.Context(), c, a)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	inventoryBlockers := append([]string(nil), blockers...)
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
		// Each retained start as fields (issue #4832): the blocker strings stay
		// as they are; this says which phase, endpoint, worker and native.
		startOwner := c.owner
		if c.all {
			startOwner = ""
		}
		starts, err := s.Store.RepoOpenStarts(repo, startOwner, "")
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{"authority": a, "nodes": nodes, "retired_hosts": retired, "superseded_hosts": superseded, "client_hosts": clients, "legacy_owners": owners, "blockers": blockers, "starts": starts, "tickets": tickets, "tickets_may_be_truncated": len(tickets) == 500, "tasks": tasks, "dry_run": true, "live_acceptance": "unverified"})
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
		for _, reason := range inventoryBlockers {
			if !strings.HasPrefix(reason, "legacy execution: ") {
				httpError(w, 409, "verify every repo host before freeze: "+reason)
				return
			}
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
	if change.Action == "freeze" || change.Action == "apply" || change.Action == "rollback" {
		// Every host of the repo, not only the caller's, re-reads its overlay
		// (claude-fleet#4730). One that is offline hears it on its first beat.
		for _, n := range nodes {
			go s.pushRepoAuthority(n.Endpoint, a)
		}
	}
	writeJSON(w, 200, a)
}

func (s *Server) ticketAuthorityStart(w http.ResponseWriter, r *http.Request, c ticketCaller, repo string) {
	ep, _ := s.nodeAuthOpt(r)
	if ep == nil || (r.Method != http.MethodPost && r.Method != http.MethodGet) {
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
	if r.Method == http.MethodGet && r.URL.Query().Get("list") == "1" {
		// A node reads ONLY its own endpoint's open starts, to settle the dead
		// ones through the actions below (issue #4832). Never another node's.
		starts, err := s.Store.RepoOpenStarts(repo, c.owner, ep.ID)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		writeJSON(w, 200, map[string]any{"repo": repo, "endpoint_id": ep.ID, "starts": starts})
		return
	}
	if r.Method == http.MethodGet {
		key := r.URL.Query().Get("reservation")
		if !idemRE.MatchString(key) {
			httpError(w, 400, "one explicit reservation is required")
			return
		}
		start, err := s.Store.ReadRepoLocalStart(repo, c.owner, ep.ID, key)
		if err != nil {
			httpError(w, 409, "original reservation is unavailable in this scope")
			return
		}
		writeJSON(w, 200, start)
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
	// A client reserves no start (claude-fleet#4886); it may still settle
	// one it left open before it was typed, so only reserve is refused.
	if in.Action == "reserve" && s.endpointRole(ep.ID) == store.NodeRoleClient {
		httpError(w, 403, "这台是客户端，任务在托管节点上跑 (a client node runs no task)")
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

// pushRepoAuthority tells one host that repo a's authority moved
// (claude-fleet#4730). A host that did not list CapRepoAuthority, or is
// offline, is skipped: it is told on its next connection's first beat.
func (s *Server) pushRepoAuthority(endpointID string, a store.RepoAuthority) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if !s.canRepoAuthority(ctx, endpointID) {
		return
	}
	msg, err := control.New(control.TypeRepoAuthority, control.RepoAuthority{Repo: a.Repo, Mode: a.Mode, Revision: a.Revision})
	if err != nil {
		return
	}
	if err := s.SendNodeWrite(ctx, endpointID, msg); err != nil && !errors.Is(err, ErrNodeOffline) {
		log.Printf("node %s: repo authority %s: %v", endpointID, a.Repo, err)
	}
}

// pushRepoAuthorities runs on a capable connection's first beat: every repo
// this endpoint's fleets host whose authority has ever moved is told once, so
// a host offline at the cutover converges when it comes back. A repo that
// never moved sends nothing — byte for byte as before (claude-fleet#4730).
func (s *Server) pushRepoAuthorities(endpointID string) {
	fs, err := s.Store.Fleets()
	if err != nil {
		return
	}
	seen := map[string]bool{}
	for _, f := range fs {
		if f.EndpointID != endpointID {
			continue
		}
		for _, r := range append([]string{f.Repo}, f.Repos...) {
			r = store.NormRepo(r)
			if r == "" || seen[r] {
				continue
			}
			seen[r] = true
			if a, err := s.Store.RepoAuthority(r); err == nil && a.Revision > 0 {
				s.pushRepoAuthority(endpointID, a)
			}
		}
	}
}
