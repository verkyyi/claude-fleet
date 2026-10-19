package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/fleetid"
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

// supersededBy names the present row that supersedes f, "" when none does
// (repo "" = any successor, for a fleet row that hosts no repo). A
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
		if !g.Present || g.FleetID == f.FleetID || !g.ObservedAt.After(f.ObservedAt) || (repo != "" && !fleetHosts(g, repo)) {
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
// terminal, which runs no task (claude-fleet#4886): a fleet it still lists in
// its inventory is a leftover, not a host, so it is listed apart and blocks
// nothing.
type repoClientHost struct {
	Fleet    string `json:"fleet_id"`
	Endpoint string `json:"endpoint_id"`
}

// endpointRole is an endpoint's role ("" when unread or never typed).
func (s *Server) endpointRole(endpointID string) string {
	et, err := s.Store.EndpointTrustOf(endpointID)
	if err != nil {
		return ""
	}
	return et.Role
}

// FleetAuthorityPath is a person's task authority (claude-fleet#4896):
//
//	GET  /v1/fleet/authority[?owner=]            → the manifest (dry run): authority,
//	                                                hosts, blockers, starts, tasks
//	GET  /v1/fleet/authority?gate=1              → the authority alone (a node's pre-start read)
//	POST /v1/fleet/authority                     {action freeze|apply|rollback|stop_ack,
//	                                              expected_revision, idempotency_key,
//	                                              worker_id?, evidence?}
//	GET|POST /v1/fleet/authority/start?repo=     a node's local start (reserve · begin ·
//	                                              observe · recover-observe · stopped ·
//	                                              cancel · unobserved; GET reservation= | list=1)
//	GET|POST /v1/fleet/authority/operation       a node's stale worker_starts: GET lists its
//	                                              own fleets' open ones, POST {operation_id,
//	                                              local} abandons one it never ran (#4978)
//
// The scope is the caller's own: a node's token speaks for its login's person
// (nodeTaskOwner), a person's sign-in for that person. Only a caller who sees
// every owner (an admin, the operator's door) may name ?owner= — never a node —
// and each such read or change is audited. The old per-repo road under
// /v1/fleet/tickets left with the hub's tickets (claude-fleet#4898, T477).
const FleetAuthorityPath = "/v1/fleet/authority"

// authorityBodyMax bounds a POST's body.
const authorityBodyMax = 80 << 10

// authorityCaller is who is asking: whose tasks they own, whether they see
// everyone's, the name an audit row of theirs carries.
type authorityCaller struct {
	owner, actor string
	all          bool
	node         bool
}

// authorityCallerOf resolves r: a node token first (a bearer that is one),
// then a person's session or the operator's door.
func (s *Server) authorityCallerOf(r *http.Request) (authorityCaller, bool) {
	if ep, _ := s.nodeAuthOpt(r); ep != nil { // its signature, else its token (claude-fleet#3710)
		host, user := s.peerSelf(ep)
		return authorityCaller{owner: s.nodeTaskOwner(ep), actor: "node:" + user + "@" + host, node: true}, true
	}
	id, ok := s.sshRelayHTTPIdentity(r)
	switch {
	case !ok:
		return authorityCaller{}, false
	case id.Admin:
		return authorityCaller{owner: id.Actor, actor: id.Actor, all: true}, true
	case id.Operator:
		return authorityCaller{owner: "operator", actor: "operator", all: true}, true
	}
	return authorityCaller{owner: id.Principal, actor: id.Principal}, true
}

// decodeAuthority reads one JSON object of the listed fields, nothing else.
func decodeAuthority(w http.ResponseWriter, r *http.Request, v any) bool {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, authorityBodyMax))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		httpError(w, http.StatusBadRequest, "the body is one JSON object of the listed fields: "+err.Error())
		return false
	}
	return true
}

func (s *Server) handleFleetAuthority(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	c, ok := s.authorityCallerOf(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a node token, a session or the viewer token is required")
		return
	}
	sub := strings.Trim(strings.TrimPrefix(r.URL.Path, FleetAuthorityPath), "/")
	if sub != "" && sub != "start" && sub != "operation" {
		httpError(w, http.StatusNotFound, "a task authority is "+FleetAuthorityPath+"[/start|/operation]")
		return
	}
	s.taskAuthority(w, r, c, sub)
}

// endpointOwner is whose task authority admits a claim made on endpoint id:
// that login's person (nodeTaskOwner), "" when the endpoint is unknown.
func (s *Server) endpointOwner(id string) string {
	ep, err := s.Store.EndpointByID(id)
	if err != nil || ep == nil {
		return ""
	}
	return s.nodeTaskOwner(ep)
}

// ownerAuthorityInventory: only registry observations are accepted — a caller
// cannot submit a reassuring inventory. The hosts are the owner's OWN fleet
// rows; another person's host is theirs, never foreign, and blocks nothing
// here (claude-fleet#4896). Absent/offline/old ones of the owner are unknown,
// never drained — a RETIRED one is neither: it is listed apart and blocks
// nothing, and so is a SUPERSEDED one (supersededBy) and a CLIENT's
// (claude-fleet#4886). endpoints are the owner's endpoints, the scope the
// store's blockers count.
func (s *Server) ownerAuthorityInventory(ctx context.Context, a store.OwnerAuthority) (nodes []repoAuthorityNode, owners []store.RepoLegacyOwner, blockers []string, retired []repoRetiredHost, superseded []repoSupersededHost, clients []repoClientHost, endpoints []string, err error) {
	nodes, owners, blockers, retired, superseded, clients, endpoints = []repoAuthorityNode{}, []store.RepoLegacyOwner{}, []string{}, []repoRetiredHost{}, []repoSupersededHost{}, []repoClientHost{}, []string{}
	fs, err := s.Store.Fleets()
	if err != nil {
		return
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
	seenEP := map[string]bool{}
	for _, f := range fs {
		ep := eps(f.EndpointID)
		if ep == nil || s.nodeTaskOwner(ep) != a.Owner {
			continue
		}
		if !seenEP[ep.ID] {
			seenEP[ep.ID] = true
			endpoints = append(endpoints, ep.ID)
		}
		if ep.RetiredAt != nil {
			retired = append(retired, repoRetiredHost{f.FleetID, f.EndpointID, *ep.RetiredAt})
			continue
		}
		if s.endpointRole(ep.ID) == store.NodeRoleClient {
			clients = append(clients, repoClientHost{f.FleetID, f.EndpointID})
			continue
		}
		if g, ok := supersededBy(f, store.NormRepo(f.Repo), fs, eps); ok {
			superseded = append(superseded, repoSupersededHost{f.FleetID, f.EndpointID, f.ObservedAt, g.FleetID, g.ObservedAt})
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
		// Every session of the owner's that is not an accepted task's
		// execution is legacy, whatever repo it works in — or none.
		for _, w := range ws {
			known, e := s.Store.TaskExecutionKnown(a.Owner, w.WorkerID)
			if e != nil {
				err = e
				return
			}
			if !known {
				owners = append(owners, store.RepoLegacyOwner{WorkerID: w.WorkerID, EndpointID: f.EndpointID})
				blockers = append(blockers, "legacy execution: "+w.WorkerID)
			}
		}
	}
	if len(nodes) == 0 {
		blockers = append(blockers, "no verified host of yours")
	}
	return
}

// authorityChangeIn is a POST's body. legacy_tickets is what the old road's
// freeze / init sent; it is accepted and ignored (# compat-1v: 下一批删).
type authorityChangeIn struct {
	store.OwnerAuthorityChange
	LegacyTickets string `json:"legacy_tickets"`
}

// taskAuthority serves the road; a repo= narrows the manifest's lists.
func (s *Server) taskAuthority(w http.ResponseWriter, r *http.Request, c authorityCaller, sub string) {
	q := r.URL.Query()
	repo := store.NormRepo(q.Get("repo"))
	if repo != "" && !leaseRepoRE.MatchString(repo) {
		httpError(w, 400, "repo is owner/name")
		return
	}
	owner, onBehalf := c.owner, false
	if o := strings.TrimSpace(q.Get("owner")); o != "" && o != c.owner {
		if !c.all || c.node {
			httpError(w, 403, "only an admin reads or moves another person's task authority")
			return
		}
		owner, onBehalf = o, true
	}
	if owner == "" {
		httpError(w, 403, "no person owns this caller's tasks")
		return
	}
	if sub == "operation" {
		if onBehalf {
			httpError(w, 403, "a start is settled by its own node")
			return
		}
		s.authorityOperation(w, r, c)
		return
	}
	if sub == "start" {
		if onBehalf {
			httpError(w, 403, "a local start is its own node's")
			return
		}
		if repo == "" {
			httpError(w, 400, "select one explicit repo=owner/name")
			return
		}
		s.authorityStart(w, r, c, repo)
		return
	}
	a, err := s.Store.OwnerAuthority(owner)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	// A node's pre-start check is a read, not a manifest or a new polling loop.
	if r.Method == http.MethodGet && q.Get("gate") == "1" {
		writeJSON(w, 200, a)
		return
	}
	nodes, owners, blockers, retired, superseded, clients, endpoints, err := s.ownerAuthorityInventory(r.Context(), a)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	inventoryBlockers := append([]string(nil), blockers...)
	dbBlockers, leaseOwners, err := s.Store.OwnerAuthorityBlockers(owner, endpoints, q.Get("rollback") == "1")
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	blockers = append(blockers, dbBlockers...)
	owners = append(owners, leaseOwners...)
	audit := func(action, outcome string) {
		if onBehalf || r.Method != http.MethodGet {
			_ = s.Store.FleetAudit(c.actor, "task_authority_"+action, "owner:"+owner, outcome, "", time.Now())
		}
	}
	if r.Method == http.MethodGet {
		tasks, err := s.Store.RepoTaskInventory(repo, owner)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		// Each retained start as fields (issue #4832): the blocker strings stay
		// as they are; this says which phase, endpoint, worker and native.
		starts, err := s.Store.RepoOpenStarts(repo, owner, "")
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		audit("read", "OK")
		writeJSON(w, 200, map[string]any{"authority": a, "nodes": nodes, "retired_hosts": retired, "superseded_hosts": superseded, "client_hosts": clients, "legacy_owners": owners, "blockers": blockers, "starts": starts, "tasks": tasks, "dry_run": true, "live_acceptance": "unverified"})
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, 405, "GET manifest or POST authority transition")
		return
	}
	var in authorityChangeIn
	if !decodeAuthority(w, r, &in) {
		return
	}
	change := in.OwnerAuthorityChange
	if change.Action == "init" {
		// # compat-1v: 下一批删 — an older node's fleet-repo.sh add asks this; it
		// falls back to the gate read, which is the person's own mode.
		httpError(w, 409, "task authority is a person's, not a repo's: a new repo selects nothing (claude-fleet#4896)")
		return
	}
	if !idemRE.MatchString(change.Key) {
		httpError(w, 400, "idempotency_key is required")
		return
	}
	change.Owners, change.Endpoints = owners, endpoints
	if change.Action == "stop_ack" {
		ep, _ := s.nodeAuthOpt(r)
		if ep == nil || s.nodeTaskOwner(ep) != owner {
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
			audit(change.Action, "REFUSED: blockers")
			writeJSON(w, 409, map[string]any{"error": "drain/verify all of your executions and hosts first", "blockers": blockers})
			return
		}
	} else if change.Action == "freeze" {
		// All of the owner's hosts must know the local dispatch rail before
		// relying on the central freeze. Active executions themselves may drain.
		if len(nodes) == 0 {
			httpError(w, 409, "no registered capable host of yours")
			return
		}
		for _, reason := range inventoryBlockers {
			if !strings.HasPrefix(reason, "legacy execution: ") {
				httpError(w, 409, "verify every host of yours before freeze: "+reason)
				return
			}
		}
		for _, n := range nodes {
			if !n.Capable {
				httpError(w, 409, "upgrade every host of yours before freeze")
				return
			}
		}
	}
	a, err = s.Store.ChangeOwnerAuthority(owner, change, time.Now())
	if err != nil {
		code := 409
		if errors.Is(err, store.ErrTaskInvalid) {
			code = 400
		}
		audit(change.Action, "REFUSED: "+err.Error())
		httpError(w, code, err.Error())
		return
	}
	audit(change.Action, "OK mode="+a.Mode+" revision="+strconv.FormatInt(a.Revision, 10))
	if change.Action == "freeze" || change.Action == "apply" || change.Action == "rollback" {
		// Every host of the owner's, not only the caller's, re-reads
		// (claude-fleet#4730). One that is offline hears it on its first beat.
		go s.pushOwnerAuthority(endpoints, a)
	}
	writeJSON(w, 200, a)
}

func (s *Server) authorityStart(w http.ResponseWriter, r *http.Request, c authorityCaller, repo string) {
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
	if !decodeAuthority(w, r, &in) {
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

// abandonAge: how old a worker_start must be before its node may abandon it.
var abandonAge = 24 * time.Hour

// authorityOperation is a node settling its own fleets' stale worker_starts
// (claude-fleet#4978): GET lists the owner's open starts whose fleet is this
// node's login; POST abandons one the node says it never ran — its journal
// has no such operation (not_accepted) or journalled it failed (failed), and
// no window or process there names it. The hub adds its own books
// (store.AbandonStaleStart) and writes one operation_abandon audit row.
func (s *Server) authorityOperation(w http.ResponseWriter, r *http.Request, c authorityCaller) {
	ep, _ := s.nodeAuthOpt(r)
	if ep == nil || (r.Method != http.MethodPost && r.Method != http.MethodGet) {
		httpError(w, 403, "a start is settled by its own authenticated node")
		return
	}
	fs, err := s.Store.Fleets()
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	mine := map[string]bool{}
	for _, f := range fs {
		if s.sameNodeLogin(f, ep) {
			mine[f.FleetID] = true
		}
	}
	if r.Method == http.MethodGet {
		ops, err := s.Store.OwnerOpenStarts(c.owner)
		if err != nil {
			httpError(w, 500, err.Error())
			return
		}
		out := []map[string]any{}
		for _, o := range ops {
			if mine[o.FleetID] {
				out = append(out, map[string]any{"operation_id": o.ID, "fleet_id": o.FleetID, "status": o.Status,
					"created": o.Created.UTC().Format(time.RFC3339), "updated": o.Updated.UTC().Format(time.RFC3339)})
			}
		}
		writeJSON(w, 200, map[string]any{"endpoint_id": ep.ID, "min_age_seconds": int(abandonAge.Seconds()), "operations": out})
		return
	}
	var in struct {
		OperationID string `json:"operation_id"`
		Local       string `json:"local"`
	}
	if !decodeAuthority(w, r, &in) {
		return
	}
	if !fleetid.IsUUID(in.OperationID) || (in.Local != "not_accepted" && in.Local != "failed") {
		httpError(w, 400, "operation_id (a UUID) and local (not_accepted | failed) are required")
		return
	}
	o, err := s.Store.FleetOperation(in.OperationID)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !mine[o.FleetID]) {
		httpError(w, 404, "no start of this node's fleets has that id")
		return
	}
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	var res struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal([]byte(o.Result), &res)
	sw := startWorkerOf(o.Request, res.Error.Message)
	said := map[string]string{"not_accepted": "has no record of it", "failed": "journalled it failed"}[in.Local]
	now := time.Now()
	result := func(priorStatus, priorResult string) string {
		var prior any
		if priorResult != "" {
			prior = json.RawMessage(priorResult)
		}
		b, _ := json.Marshal(map[string]any{"error": map[string]any{"code": "START_ABANDONED",
			"message": "abandoned: " + c.actor + " " + said + " and no window or process there names it; past " + abandonAge.String() +
				", nothing on the hub's books holds its worker",
			"actor": c.actor, "local": in.Local, "prior_status": priorStatus, "prior_result": prior}})
		return string(b)
	}
	fleetID, why, err := s.Store.AbandonStaleStart(o.ID, c.owner, sw, abandonAge, result, now)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	if why != "" {
		httpError(w, 409, why)
		return
	}
	if aerr := s.Store.FleetAudit(c.actor, "operation_abandon", fleetID, "ABANDONED: node "+said+" (local="+in.Local+")", o.ID, now); aerr != nil {
		log.Printf("fleet audit: %v", aerr)
	}
	fresh, err := s.Store.FleetOperation(o.ID)
	if err != nil {
		httpError(w, 500, err.Error())
		return
	}
	s.progressOp(fresh)
	writeJSON(w, 200, operationView(fresh))
}

// sameNodeLogin: fleet row f is ep's login's — its endpoint, or an earlier
// endpoint of the same machine and OS login (a re-joined login), the rule
// supersededBy uses.
func (s *Server) sameNodeLogin(f store.FleetRow, ep *store.Endpoint) bool {
	if f.EndpointID == ep.ID {
		return true
	}
	if old, err := s.Store.EndpointByID(f.EndpointID); err == nil && old != nil {
		return old.MachineID != "" && old.OSUser != "" && old.MachineID == ep.MachineID && old.OSUser == ep.OSUser
	}
	return f.Hostname != "" && f.OSUser != "" && f.Hostname == ep.Hostname && f.OSUser == ep.OSUser
}

// ownerDispatchGate refuses a hub dispatch the owner's authority does not
// admit: frozen refuses all, hub an unaccepted one. Another person's mode is
// never consulted (claude-fleet#4896).
func (s *Server) ownerDispatchGate(owner string, accepted bool) error {
	if owner == "" {
		return nil
	}
	a, err := s.Store.OwnerAuthority(owner)
	if err != nil {
		return err
	}
	if a.Mode == "frozen" || (a.Mode == "hub" && !accepted) {
		return fault("INVALID_STATE", "task authority requires an unfrozen accepted dispatch")
	}
	return nil
}

// taskOwner is whose task authority a principal's start is admitted by.
func (p fleetPrincipal) taskOwner() string {
	if p.TaskOwner != "" {
		return p.TaskOwner
	}
	return p.Actor
}

// endpointRepos is every repo the fleets on endpointID host.
func endpointRepos(fs []store.FleetRow, endpointID string) []string {
	seen, out := map[string]bool{}, []string{}
	for _, f := range fs {
		if f.EndpointID != endpointID {
			continue
		}
		for _, r := range append([]string{f.Repo}, f.Repos...) {
			r = store.NormRepo(r)
			if r != "" && !seen[r] {
				seen[r] = true
				out = append(out, r)
			}
		}
	}
	return out
}

// pushOwnerAuthority tells each of the owner's capable hosts that their
// authority moved (claude-fleet#4730, per person since #4896). The message is
// still the per-repo TypeRepoAuthority — once for each repo the host's fleets
// host (once with no repo when it hosts none), the owner's mode and revision —
// so an older node re-reads its overlays as before. A host that did not list CapRepoAuthority, or is
// offline, is skipped: it is told on its next connection's first beat.
func (s *Server) pushOwnerAuthority(endpoints []string, a store.OwnerAuthority) {
	fs, err := s.Store.Fleets()
	if err != nil {
		return
	}
	for _, ep := range endpoints {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if s.canRepoAuthority(ctx, ep) {
			repos := endpointRepos(fs, ep)
			if len(repos) == 0 {
				// A host with no repo yet (a new person's first login,
				// claude-fleet T490) is told once with no repo: it re-reads
				// the person's mode all the same. An older agent drops it.
				repos = []string{""}
			}
			for _, repo := range repos {
				msg, err := control.New(control.TypeRepoAuthority, control.RepoAuthority{Repo: repo, Mode: a.Mode, Revision: a.Revision})
				if err != nil {
					continue
				}
				if err := s.SendNodeWrite(ctx, ep, msg); err != nil && !errors.Is(err, ErrNodeOffline) {
					log.Printf("node %s: task authority %s (%s): %v", ep, a.Owner, repo, err)
				}
			}
		}
		cancel()
	}
}

// pushRepoAuthorities runs on a capable connection's first beat: when this
// login's person ever moved their authority, the host is told once, so a host
// offline at the cutover converges when it comes back. A person who never
// moved sends nothing — byte for byte as before (claude-fleet#4730).
func (s *Server) pushRepoAuthorities(endpointID string) {
	owner := s.endpointOwner(endpointID)
	if owner == "" {
		return
	}
	if a, err := s.Store.OwnerAuthority(owner); err == nil && a.Revision > 0 {
		s.pushOwnerAuthority([]string{endpointID}, a)
	}
}
