package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Which machine runs the person's ONE orchestrating session (claude-fleet#2117,
// EPIC #1949; the session itself is bin/fleet-orchestrator.sh, #1957).
//
// Every 承载 machine of one person runs its own fleet, and each used to open its
// own orchestrator — m4 and m5 each had one, and the client took whichever came
// first by name. The person has one; the hub says which machine holds it:
//
//	GET  /v1/node/orchestrator                  → this machine may hold it (the tick's ask)
//	POST /v1/node/orchestrator {"eligible":b}   → the same, or — false — "not here"
//	                                              (FLEET_ORCHESTRATOR=0 on this machine)
//	→ {"machine": "<holder>"|"", "here": bool, "rule": "holder|sessions|name|none", "reason": "…"}
//
// The pick, for the owner of the asking node's login (the same owner rule as
// the peer certificate, #1626: the principal of its active account, else the
// same login name on an unowned machine):
//
//  1. the current holder (the setting fleet.orchestrator_host.<owner>) while it
//     is online and not 维护中 (or 维护中 with no other machine free) — sticky, so a person moving between devices or a
//     machine's load swinging never moves the conversation;
//  2. otherwise a machine that has itself asked as eligible within
//     orchSeenTTL — the one with the most of the person's sessions (the home
//     pick's second rule, #1470), then by name — not 维护中 first; a 维护中 one
//     only when nothing else is online;
//  3. none online: no holder ("" — every machine keeps its hands off).
//
// One machine holds it at a time: every machine asks on its tick, the one
// named opens it, every other closes its own (marked first, its conversation id
// kept), so a holder that goes lost or 维护中 hands it to the next machine one
// tick later. The decision is serialised here (orchMu) so two machines asking in
// the same instant cannot both be named.
//
// No hub, an old hub (404) or a hub that cannot be asked: the machine decides
// alone as before (bin/fleet-orchestrator.sh's rules).

// OrchestratorHostPrefix names the per-owner holder setting.
const OrchestratorHostPrefix = "fleet.orchestrator_host."

// orchSeenTTL is how long a machine's "I may hold it" stands: a few ticks of
// the diskguard watch (60 s), so a machine that stopped asking stops being a
// candidate for a NEW pick — a holder is judged by its heartbeat, not this.
const orchSeenTTL = 10 * time.Minute

// OrchestratorResponse is the body of /v1/node/orchestrator.
type OrchestratorResponse struct {
	Machine string `json:"machine"`
	Here    bool   `json:"here"`
	Rule    string `json:"rule"`
	Reason  string `json:"reason"`
}

type orchSeen struct {
	eligible bool
	at       time.Time
}

// orchState is the hub's in-memory half: who asked, and whether they may hold it.
type orchState struct {
	mu   sync.Mutex
	seen map[string]orchSeen // owner key + "\x1f" + machine → last ask
}


// orchOwnerKey is the setting suffix for an owner: the principal id, or — an
// unowned login — "login:<name>".
func orchOwnerKey(owner, login string) string {
	if owner != "" {
		return strings.ToLower(owner)
	}
	return "login:" + strings.ToLower(login)
}

func orchMachine(hostname string) string { return strings.ToLower(firstLabel(hostname)) }

// orchestratorPick records the asking machine's eligibility and answers who holds it.
func (s *Server) orchestratorPick(host, login string, eligible bool, now time.Time) (OrchestratorResponse, error) {
	out := OrchestratorResponse{Rule: "none"}
	owner, err := s.Store.PrincipalForLogin(host, login)
	if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
		return out, err
	}
	okey := orchOwnerKey(owner, login)
	me := orchMachine(host)

	st := &s.orchHost
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.seen == nil {
		st.seen = map[string]orchSeen{}
	}
	st.seen[okey+"\x1f"+me] = orchSeen{eligible: eligible, at: now}

	nodes, err := s.Store.Nodes()
	if err != nil {
		return out, err
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return out, err
	}
	// The owner's machines: online (any of its logins of this owner heard), 维护中.
	type cand struct {
		machine  string
		online   bool
		maint    bool
		sessions int
	}
	cands := map[string]*cand{}
	for i := range nodes {
		n := &nodes[i]
		if n.Hostname == "" || n.OSUser == "" {
			continue
		}
		who, err := s.Store.PrincipalForLogin(n.Hostname, n.OSUser)
		if err != nil && !errors.Is(err, store.ErrNoPrincipal) {
			return out, err
		}
		if (owner != "" && who != owner) || (owner == "" && (who != "" || n.OSUser != login)) {
			continue
		}
		m := orchMachine(n.Hostname)
		c := cands[m]
		if c == nil {
			c = &cand{machine: m}
			cands[m] = c
		}
		if NodeStatus(n.LastHeartbeat, n.HeartbeatMS, now) == "online" {
			c.online = true
			if _, flagged := maintenanceOf(n.Hostname, settings); flagged {
				c.maint = true
			}
		}
	}
	if rows, err := s.Store.Fleets(); err == nil {
		for _, r := range rows {
			if c := cands[orchMachine(r.Hostname)]; c != nil && r.Present {
				who, _ := s.Store.PrincipalForLogin(r.Hostname, r.OSUser)
				if (owner != "" && who == owner) || (owner == "" && r.OSUser == login) {
					c.sessions += r.WorkerCount
				}
			}
		}
	}
	mayHold := func(m string) bool {
		v, ok := st.seen[okey+"\x1f"+m]
		return !ok || v.eligible
	}
	askedEligible := func(m string) bool {
		v, ok := st.seen[okey+"\x1f"+m]
		return ok && v.eligible && now.Sub(v.at) <= orchSeenTTL
	}

	key := OrchestratorHostPrefix + okey
	holder := settings[key]
	pick, rule := "", ""
	// A 维护中 holder keeps it only while no other online machine is free of the
	// flag — so a fleet all under maintenance never flips it back and forth.
	freeElsewhere := false
	for m, c := range cands {
		if m != holder && c.online && !c.maint && askedEligible(m) {
			freeElsewhere = true
		}
	}
	if c := cands[holder]; holder != "" && c != nil && c.online && mayHold(holder) && (!c.maint || !freeElsewhere) {
		pick, rule, out.Reason = holder, "holder", "编排会话一直在这台"
	}
	if pick == "" {
		list := make([]*cand, 0, len(cands))
		for _, c := range cands {
			list = append(list, c)
		}
		sort.Slice(list, func(a, b int) bool {
			if list[a].sessions != list[b].sessions {
				return list[a].sessions > list[b].sessions
			}
			return list[a].machine < list[b].machine
		})
		for _, allowMaint := range []bool{false, true} {
			for _, c := range list {
				if c.online && (allowMaint || !c.maint) && askedEligible(c.machine) {
					pick = c.machine
					if c.sessions > 0 {
						rule, out.Reason = "sessions", "有你会话最多的在线承载机器"
					} else {
						rule, out.Reason = "name", "在线承载机器（按名字）"
					}
					if allowMaint {
						out.Reason += "（只剩维护中的机器在线）"
					}
					break
				}
			}
			if pick != "" {
				break
			}
		}
	}
	if pick == "" {
		out.Reason = "没有可以开编排会话的在线承载机器"
		return out, nil
	}
	if pick != holder {
		if err := s.Store.SetFleetSetting(key, pick, now); err != nil {
			return out, err
		}
		s.leaseAudit("node:"+login+"@"+me, "orchestrator_host", "owner:"+okey, "HOLDER "+pick+" (was "+holder+") rule="+rule, now)
	}
	out.Machine, out.Here, out.Rule = pick, pick == me, rule
	return out, nil
}

// handleNodeOrchestrator serves /v1/node/orchestrator — a machine asking, with
// its own node token, whether it is the one to hold the orchestrator.
func (s *Server) handleNodeOrchestrator(w http.ResponseWriter, r *http.Request) {
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	eligible := true
	switch r.Method {
	case http.MethodGet:
	case http.MethodPost:
		var body struct {
			Eligible *bool `json:"eligible"`
		}
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
		if err != nil {
			httpError(w, http.StatusBadRequest, err.Error())
			return
		}
		if len(strings.TrimSpace(string(raw))) > 0 {
			if err := json.Unmarshal(raw, &body); err != nil {
				httpError(w, http.StatusBadRequest, "body: "+err.Error())
				return
			}
		}
		if body.Eligible != nil {
			eligible = *body.Eligible
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
		return
	}
	host, user := s.peerSelf(ep)
	if host == "" || user == "" {
		httpError(w, http.StatusConflict, "this node has not reported yet — the hub does not know which machine it is")
		return
	}
	out, err := s.orchestratorPick(host, user, eligible, time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}
