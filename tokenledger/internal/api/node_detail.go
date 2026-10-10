package api

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// One machine's page (claude-fleet#2796, EPIC #2792 C4): GET /v1/nodes/<host>
// puts together what the roster scatters — its logins, its services and
// tasks, its versions, its load and memory, its sessions — each block with
// the time it was measured at the source (共同约定 3: nil = 时间未知, never
// the hub's clock passed off as fresh).
//
// The cut is the roster's, FleetScope: a user opens only a machine one of
// their logins is on (else 404, the same answer as no such machine) and sees
// only their own logins, services and sessions there; the rest of the
// machine's logins are a count, OtherLogins. An admin outside a daily page's
// route sees all of it.

// NodeDetailPrefix is the route; the rest of the path is the machine.
const NodeDetailPrefix = "/v1/nodes/"

// NodeDetail is GET /v1/nodes/<host>'s answer.
type NodeDetail struct {
	At      time.Time   `json:"at"`
	Machine MachineView `json:"machine"`
	// Logins are the machine's login rows the reader may see (the machine
	// link is no login); OtherLogins how many more the machine has.
	Logins      []NodeView `json:"logins"`
	OtherLogins int        `json:"other_logins,omitempty"`
	LoginsAt    *time.Time `json:"logins_at"`
	// Services is the register, cut like the roster's (claude-fleet#2526).
	Services   []control.ServiceStatus `json:"services"`
	ServicesAt *time.Time              `json:"services_at"`
	Version    NodeDetailVersion       `json:"version"`
	Load       NodeDetailLoad          `json:"load"`
	Mem        NodeDetailMem           `json:"mem"`
	// Sessions are fleet_sessions' rows on this machine, cut the same way.
	Sessions   []FleetSession `json:"sessions"`
	SessionsAt *time.Time     `json:"sessions_at"`
}

// NodeDetailVersion is 版本与更新: the node program and claude-fleet the
// machine runs, the release it should run (期望 / 实际), and — from a node
// that reports them (claude-fleet#2798) — every component and the updater's
// phase. Components / Phase / At empty = 节点太旧，未报.
type NodeDetailVersion struct {
	Agent       string            `json:"agent,omitempty"`
	Fleet       string            `json:"fleet,omitempty"`
	Release     string            `json:"release,omitempty"`
	WantRelease string            `json:"want_release,omitempty"`
	Want        int               `json:"want,omitempty"`
	Reached     int               `json:"reached,omitempty"`
	Diff        string            `json:"diff,omitempty"`
	Runtime     string            `json:"runtime,omitempty"`
	Components  map[string]string `json:"components,omitempty"`
	WantComps   map[string]string `json:"want_components,omitempty"`
	Phase       string            `json:"phase,omitempty"`
	Result      string            `json:"result,omitempty"`
	Reason      string            `json:"reason,omitempty"`
	UpdatedAt   *time.Time        `json:"updated_at,omitempty"`
	At          *time.Time        `json:"at"`
}

// NodeDetailLoad is load: the newest reading, the cores, and the roster's
// per-core trend (five minutes a point, oldest first; empty after a hub
// restart — HistFrom says how far back it reaches).
type NodeDetailLoad struct {
	Now      float64    `json:"now"`
	NCPU     int        `json:"ncpu"`
	Hist     []float64  `json:"hist"`
	HistStep int        `json:"hist_step_sec"`
	HistFrom *time.Time `json:"hist_from,omitempty"`
	Unread   []string   `json:"unread,omitempty"`
	At       *time.Time `json:"at"`
}

// NodeDetailMem is memory in bytes; Pressure is used / total (0..1).
type NodeDetailMem struct {
	Used     uint64     `json:"used"`
	Total    uint64     `json:"total"`
	Pressure *float64   `json:"pressure"`
	At       *time.Time `json:"at"`
}

// handleNodeDetail serves GET /v1/nodes/<host>.
func (s *Server) handleNodeDetail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	host := strings.Trim(strings.TrimPrefix(r.URL.Path, NodeDetailPrefix), "/")
	if host == "" || strings.Contains(host, "/") {
		httpError(w, http.StatusNotFound, "no such machine")
		return
	}
	visible, err := s.FleetScope(r)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	d, err := s.nodeDetail(time.Now(), host, visible)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if d == nil {
		// Not there, or none of the reader's logins is: one answer, so a
		// user cannot learn which machines exist.
		httpError(w, http.StatusNotFound, "no such machine")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, d)
}

// machineMatches is whether name addresses m: its hostname, the hostname's
// first label, or its alias — case aside.
func machineMatches(m MachineView, name string) bool {
	return strings.EqualFold(m.Hostname, name) || strings.EqualFold(firstLabel(m.Hostname), name) ||
		(m.Alias != "" && strings.EqualFold(m.Alias, name))
}

// nodeDetail is one machine's page as visible (nil: all) lets the reader see
// it; nil when the reader sees no such machine.
func (s *Server) nodeDetail(now time.Time, name string, visible func(hostname, osUser string) bool) (*NodeDetail, error) {
	snap, err := s.nodesWhere(now, visible)
	if err != nil {
		return nil, err
	}
	var m *MachineView
	for i := range snap.Machines {
		if machineMatches(snap.Machines[i], name) {
			m = &snap.Machines[i]
			break
		}
	}
	if m == nil {
		return nil, nil
	}
	d := &NodeDetail{At: now.UTC(), Machine: *m, Logins: []NodeView{}, Services: []control.ServiceStatus{}, Sessions: []FleetSession{}}
	host := m.Hostname

	// Logins: the reader's rows on it; the link carries them, it is none.
	var link *NodeView
	for i := range snap.Nodes {
		n := snap.Nodes[i]
		if n.Hostname != host {
			continue
		}
		if n.MachineLink {
			link = &snap.Nodes[i]
			continue
		}
		if n.LoginsRefused == nil && m.LoginsRefused[n.OSUser] != "" {
			n.LoginsRefused = map[string]string{n.OSUser: m.LoginsRefused[n.OSUser]}
		}
		d.Logins = append(d.Logins, n)
		d.LoginsAt = newer(d.LoginsAt, n.LastHeartbeat)
	}
	sort.Slice(d.Logins, func(a, b int) bool { return d.Logins[a].OSUser < d.Logins[b].OSUser })
	if visible != nil {
		// The machine's other logins, as a count: the whole roster's count
		// for it (the link is no login there either) minus the ones shown.
		if all, err := s.nodesWhere(now, nil); err == nil {
			for _, am := range all.Machines {
				if am.Hostname == host && am.Logins > len(d.Logins) {
					d.OtherLogins = am.Logins - len(d.Logins)
				}
			}
		}
		// A user reads only their own logins' refusals.
		d.Machine.LoginsRefused = nil
		for _, n := range d.Logins {
			if why := n.LoginsRefused[n.OSUser]; why != "" {
				if d.Machine.LoginsRefused == nil {
					d.Machine.LoginsRefused = map[string]string{}
				}
				d.Machine.LoginsRefused[n.OSUser] = why
			}
		}
	}

	// Services: already the reader's cut.
	if len(m.Services) > 0 {
		d.Services = m.Services
	}
	d.ServicesAt = m.ServicesAt

	// What a node from claude-fleet#2798 on adds to the machine row — read
	// through its JSON, so this page works with or without those fields.
	var extra struct {
		SysAt      *time.Time `json:"sys_at"`
		SysUnread  []string   `json:"sys_unread"`
		VersionsAt *time.Time `json:"versions_at"`
		Versions   *struct {
			Runtime string            `json:"runtime"`
			Actual  map[string]string `json:"actual"`
			Want    map[string]string `json:"want"`
			Update  *struct {
				Result string     `json:"result"`
				Phase  string     `json:"phase"`
				At     *time.Time `json:"at"`
				Reason string     `json:"reason"`
			} `json:"update"`
		} `json:"versions"`
	}
	if b, err := json.Marshal(m); err == nil {
		_ = json.Unmarshal(b, &extra)
	}

	// Version.
	v := &d.Version
	v.Fleet = m.FleetVersion
	var verAt *time.Time
	pick := func(n NodeView) {
		if n.AgentVersion != "" && (verAt == nil || (n.LastHeartbeat != nil && n.LastHeartbeat.After(*verAt))) {
			v.Agent, verAt = n.AgentVersion, n.LastHeartbeat
		}
		if dv := n.Desired; dv != nil && dv.Want >= v.Want {
			v.Want, v.Reached, v.Release, v.WantRelease, v.Diff = dv.Want, dv.Reached, dv.Release, dv.WantRelease, dv.Diff
		}
	}
	if link != nil {
		pick(*link)
	}
	for _, n := range d.Logins {
		if link == nil || v.Agent == "" {
			pick(n)
		}
	}
	if ex := extra.Versions; ex != nil {
		v.Runtime, v.Components, v.WantComps = ex.Runtime, ex.Actual, ex.Want
		if u := ex.Update; u != nil {
			v.Phase, v.Result, v.Reason, v.UpdatedAt = u.Phase, u.Result, u.Reason, u.At
		}
		v.At = extra.VersionsAt
	}

	// Load and memory: measured at sys_at by a node that says so.
	d.Load = NodeDetailLoad{Now: m.Load1, NCPU: m.NCPU, Hist: m.LoadHist, HistStep: int(loadBucket / time.Second), Unread: extra.SysUnread, At: extra.SysAt}
	if d.Load.Hist == nil {
		d.Load.Hist = []float64{}
	}
	if k := len(d.Load.Hist); k > 0 {
		from := now.Truncate(loadBucket).Add(-time.Duration(k-1) * loadBucket).UTC()
		d.Load.HistFrom = &from
	}
	d.Mem = NodeDetailMem{Total: m.MemTotal, At: extra.SysAt}
	if m.MemTotal > 0 && m.MemFree <= m.MemTotal {
		d.Mem.Used = m.MemTotal - m.MemFree
		p := float64(d.Mem.Used) / float64(m.MemTotal)
		d.Mem.Pressure = &p
	}

	// Sessions: fleet_sessions' rows on this machine, the same cut.
	if fleets, err := s.Store.Fleets(); err == nil {
		avail := s.nodeAvailability(now)
		for _, r := range fleets {
			if r.Hostname != host || !r.Present || (visible != nil && !visible(r.Hostname, r.OSUser)) {
				continue
			}
			obs := r.ObservedAt
			d.SessionsAt = newer(d.SessionsAt, &obs)
			a := avail[r.EndpointID]
			if a == "" {
				a = "lost"
			}
			var ws []map[string]any
			_ = json.Unmarshal([]byte(r.WorkersJSON), &ws)
			for _, w := range ws {
				var id *string
				if x, ok := w["worker_id"].(string); ok && x != "" {
					id = &x
				}
				d.Sessions = append(d.Sessions, FleetSession{WorkerID: id, MachineName: r.Hostname, OSUser: r.OSUser,
					FleetID: r.FleetID, FleetName: r.Name, Availability: a, Worker: w,
					ObservedAt: r.ObservedAt, AgeSec: now.Sub(r.ObservedAt).Seconds()})
			}
		}
		sort.SliceStable(d.Sessions, func(a, b int) bool {
			x, y := d.Sessions[a], d.Sessions[b]
			if x.OSUser != y.OSUser {
				return x.OSUser < y.OSUser
			}
			ka, _ := x.Worker["key"].(string)
			kb, _ := y.Worker["key"].(string)
			return ka < kb
		})
	}
	return d, nil
}

// newer is the later of a and b (either may be nil).
func newer(a, b *time.Time) *time.Time {
	if b == nil || (a != nil && !b.After(*a)) {
		return a
	}
	t := b.UTC()
	return &t
}
