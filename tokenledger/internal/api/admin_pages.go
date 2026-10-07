package api

import (
	"encoding/csv"
	"io/fs"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The admin pages (claude-fleet#1990, EPIC #1982 C8): Subscriptions,
// Machines, Users, Settings and Audit. Each is a thin HTML file that mounts
// its script into the app shell (web/dist/app-shell.js) under the page id
// /v1/me lists for an admin (pagesFor).
//
// A user is refused the page the same way adminOnly refuses an admin API: one
// role_denied audit row and a 403. The body is still the page — its shell sees
// /v1/me leave the id off the menu and draws 「这一页不在你的菜单里」 rather
// than a bare JSON error in a browser tab.

// adminPageRoutes are the admin pages outside the fleet block; Machines is
// /nodes, mounted with the roster.
var adminPageRoutes = []struct{ path, id, file string }{
	{"/subscriptions", "subscriptions", "subscriptions.html"},
	{"/admin/users", "people", "users.html"},
	{"/admin/settings", "settings", "settings.html"},
	{"/admin/audit", "audit", "audit.html"},
}

// adminPage serves one admin page, or its 403 to a user.
func (s *Server) adminPage(id, file string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if roleOf(r.Context()) != roleUser {
			s.serveStandalonePage(w, r, file)
			return
		}
		s.auditRoleDenied(r)
		if s.UI == nil {
			httpError(w, http.StatusForbidden, "只有管理员可以使用这一页（only an admin can use this page）")
			return
		}
		b, err := fs.ReadFile(s.UI, file)
		if err != nil {
			httpError(w, http.StatusForbidden, "只有管理员可以使用这一页（only an admin can use this page）")
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write(b)
	})
}

// loadHistory is each machine's load per core, one bucket per five minutes
// for the last two hours, fed by every heartbeat (claude-fleet#1990). One
// machine, one load: every login reads the same kernel, so a bucket keeps the
// newest reading of any of them. Memory only — a restart starts it again.
type loadHistory struct {
	mu sync.Mutex
	by map[string]map[int64]float64 // machine → bucket → load/core
}

const (
	loadBucket  = 5 * time.Minute
	loadBuckets = 24
)

func (h *loadHistory) add(host string, load1 float64, ncpu int, at time.Time) {
	host = firstLabel(host)
	if host == "" {
		return
	}
	if ncpu < 1 {
		ncpu = 1
	}
	b := at.Unix() / int64(loadBucket/time.Second)
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.by == nil {
		h.by = map[string]map[int64]float64{}
	}
	m := h.by[host]
	if m == nil {
		m = map[int64]float64{}
		h.by[host] = m
	}
	m[b] = load1 / float64(ncpu)
	for k := range m {
		if k <= b-loadBuckets {
			delete(m, k)
		}
	}
}

// series is the last two hours, oldest first; a bucket no heartbeat reached
// carries the one before it, and the buckets before the first reading are
// left out. Never nil.
func (h *loadHistory) series(host string, now time.Time) []float64 {
	out := []float64{}
	h.mu.Lock()
	defer h.mu.Unlock()
	m := h.by[firstLabel(host)]
	if len(m) == 0 {
		return out
	}
	end := now.Unix() / int64(loadBucket/time.Second)
	seen, last := false, 0.0
	for b := end - loadBuckets + 1; b <= end; b++ {
		v, ok := m[b]
		if ok {
			seen, last = true, v
		}
		if seen {
			out = append(out, math.Round(last*100)/100)
		}
	}
	return out
}

// AuditPath is the one audit the Audit page reads (claude-fleet#1990): the
// fleet audit, the credential audit, the device audit and the hub's own
// (people, settings, sign-ins) merged, newest first, each row sorted into the
// page's filters. ?kind= keeps one filter, ?days= the window (default and
// at most auditDays), ?format=csv answers a download.
const AuditPath = "/v1/admin/audit"

// auditDays is how far back the page reads: the prototype's 「保留 60 天」.
const auditDays = 60

// auditPerSource caps each source's read; auditMax the merged answer.
const (
	auditPerSource = 2000
	auditMax       = 2000
)

// The page's filters.
const (
	auditSubs     = "sub"
	auditMachines = "mach"
	auditDevices  = "dev"
	auditUsers    = "user"
	auditSettings = "set"
	auditSessions = "sess"
)

// AuditEvent is one row of the merged audit. Text stays as each source
// stored it: the page translates the labels around it, never the record.
type AuditEvent struct {
	At      time.Time `json:"at"`
	Kind    string    `json:"kind"`
	Source  string    `json:"source"` // fleet | credential | device | hub
	Actor   string    `json:"actor"`
	Action  string    `json:"action"`
	Target  string    `json:"target,omitempty"`
	Outcome string    `json:"outcome,omitempty"`
	Detail  string    `json:"detail,omitempty"`
}

// fleetAuditKind sorts a fleet_audit action; every Fleet tool call (spawn,
// send, …) is a session's.
func fleetAuditKind(action string) string {
	switch {
	case action == "role_denied":
		return auditUsers
	case action == "session_bind" || action == "session_cred":
		return auditSubs
	case action == "team_bundle_put" || action == "person_bundle_put":
		return auditSettings
	case action == "client_action" || action == "client_revoke":
		return auditDevices
	case strings.HasPrefix(action, "spot_"), strings.HasPrefix(action, "node_"), strings.HasPrefix(action, "compute_"),
		action == "relay_cred", action == "place":
		return auditMachines
	}
	return auditSessions
}

// hubAuditKind sorts a hub_audit row: a setting by its key, the rest are
// people (user.add / user.remove / pin / signin / role_denied).
func hubAuditKind(action, target string) string {
	if action != "setting" {
		return auditUsers
	}
	switch {
	case strings.HasPrefix(target, "pool."):
		return auditSubs
	case strings.HasPrefix(target, "fleet.node_"), target == SpotKey, target == SpotWeightKey, target == ComputeAutoKey:
		return auditMachines
	case strings.HasPrefix(target, userSettingPrefix):
		return auditUsers
	}
	return auditSettings
}

// credActor reads the "by <actor>" a credential write carries in its detail.
func credActor(detail string) string {
	for _, part := range strings.Split(detail, " · ") {
		if a, ok := strings.CutPrefix(part, "by "); ok {
			return a
		}
	}
	return ""
}

// auditEvents is the merged audit since since, newest first. A source the
// hub does not have (no fleet module, no vault) is skipped, not an error.
func (s *Server) auditEvents(since time.Time) ([]AuditEvent, error) {
	out := []AuditEvent{}
	add := func(e AuditEvent) {
		if !e.At.Before(since) {
			out = append(out, e)
		}
	}
	hub, err := s.Store.HubAuditLog(auditPerSource)
	if err != nil {
		return nil, err
	}
	for _, h := range hub {
		add(AuditEvent{At: h.Created, Kind: hubAuditKind(h.Action, h.Target), Source: "hub", Actor: h.Actor,
			Action: h.Action, Target: h.Target, Outcome: h.Outcome, Detail: h.Detail})
	}
	if s.Fleet {
		// A Fleet read (fleet_sessions, gh_pr_view, …) is traffic: every
		// open page polls one. The writes and everything else stay.
		var reads []string
		for _, tool := range FleetTools {
			if !fleetWriteTools[tool] {
				reads = append(reads, tool)
			}
		}
		fa, err := s.Store.FleetAuditLog(auditPerSource, reads...)
		if err != nil {
			return nil, err
		}
		for _, f := range fa {
			actor := f.Actor
			if f.WorkerKey != "" {
				actor = joinDetail(actor, f.WorkerKey)
			}
			add(AuditEvent{At: f.Created, Kind: fleetAuditKind(f.Action), Source: "fleet", Actor: actor,
				Action: f.Action, Target: f.FleetID, Outcome: f.Outcome})
		}
		ca, err := s.Store.CredAuditLog("", 1000)
		if err != nil {
			return nil, err
		}
		for _, c := range ca {
			e := AuditEvent{At: c.At, Kind: auditSubs, Source: "credential", Actor: credActor(c.Detail),
				Action: c.Action, Detail: c.Detail}
			switch c.Action {
			case store.CredIssue, store.CredRefresh, store.CredDeny:
				continue // every lease and refresh: traffic, not a change
			case store.CredRevoke, store.CredUnrevoke:
				e.Kind, e.Target = auditUsers, c.PrincipalID
				if c.Hostname != "" {
					e.Kind, e.Target = auditMachines, joinDetail(c.Hostname, c.PrincipalID)
				}
			default:
				e.Target = joinDetail(c.Provider, joinDetail(c.Account, c.PrincipalID))
			}
			add(e)
		}
		da, err := s.Store.DeviceAuditLog("", auditPerSource)
		if err != nil {
			return nil, err
		}
		for _, d := range da {
			if strings.HasPrefix(d.Action, "renew") {
				continue // a device renewing itself every few hours
			}
			actor := d.Actor
			if actor == "" {
				actor = d.PrincipalID
			}
			add(AuditEvent{At: d.At, Kind: auditDevices, Source: "device", Actor: actor,
				Action: d.Action, Target: joinDetail(d.PrincipalID, d.Fingerprint), Detail: d.Detail})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	if len(out) > auditMax {
		out = out[:auditMax]
	}
	return out, nil
}

// handleAdminAudit answers AuditPath.
func (s *Server) handleAdminAudit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	if s.Store == nil {
		httpError(w, http.StatusNotFound, "no store")
		return
	}
	q := r.URL.Query()
	days := auditDays
	if v := q.Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			httpError(w, http.StatusBadRequest, "days is a whole number of days")
			return
		}
		days = min(n, auditDays)
	}
	kind := q.Get("kind")
	switch kind {
	case "", "all", auditSubs, auditMachines, auditDevices, auditUsers, auditSettings, auditSessions:
	default:
		httpError(w, http.StatusBadRequest, "kind is all | sub | mach | dev | user | set | sess")
		return
	}
	now := time.Now()
	all, err := s.auditEvents(now.Add(-time.Duration(days) * 24 * time.Hour))
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	counts := map[string]int{}
	events := []AuditEvent{}
	for _, e := range all {
		counts[e.Kind]++
		if kind == "" || kind == "all" || e.Kind == kind {
			events = append(events, e)
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	if q.Get("format") == "csv" {
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="audit-`+now.UTC().Format("2006-01-02")+`.csv"`)
		cw := csv.NewWriter(w)
		_ = cw.Write([]string{"at", "kind", "source", "actor", "action", "target", "outcome", "detail"})
		for _, e := range events {
			_ = cw.Write([]string{e.At.UTC().Format(time.RFC3339), e.Kind, e.Source, csvSafe(e.Actor), csvSafe(e.Action),
				csvSafe(e.Target), csvSafe(e.Outcome), csvSafe(e.Detail)})
		}
		cw.Flush()
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events, "counts": counts, "days": days, "total": len(all)})
}

// csvSafe keeps a spreadsheet from reading a cell as a formula: a value an
// actor typed (a reason, a label) could start with = + - or @.
func csvSafe(v string) string {
	if v != "" && strings.ContainsRune("=+-@\t\r", rune(v[0])) {
		return "'" + v
	}
	return v
}
