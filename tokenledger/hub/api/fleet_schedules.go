package api

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/schedule"
)

const SchedulesPath = "/v1/schedules"
const NodeSchedulesPath = "/v1/node/schedules"

type scheduleRequest struct {
	Adopt    string             `json:"adopt,omitempty"`
	Action   string             `json:"action"`
	ID       string             `json:"id,omitempty"`
	Key      string             `json:"idempotency_key,omitempty"`
	Revision int64              `json:"revision,omitempty"`
	Name     *string            `json:"name,omitempty"`
	Prompt   *string            `json:"prompt,omitempty"`
	At       *string            `json:"at,omitempty"`
	Cron     *string            `json:"cron,omitempty"`
	Timezone *string            `json:"timezone,omitempty"`
	Delivery *schedule.Delivery `json:"delivery,omitempty"`
	Repo     *string            `json:"repo,omitempty"`
}

func scheduleHash(parts ...string) string {
	v := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(v[:])[:32]
}
func scheduleError(w http.ResponseWriter, e error) {
	status := http.StatusBadRequest
	switch {
	case errors.Is(e, sql.ErrNoRows):
		status = 404
	case errors.Is(e, store.ErrScheduleLimit):
		status = 429
	case errors.Is(e, store.ErrScheduleConflict):
		status = 409
	}
	httpError(w, status, e.Error())
}
func (s *Server) handleSchedules(w http.ResponseWriter, r *http.Request) {
	owner := principalOf(r.Context())
	if owner == "" {
		httpError(w, 401, "sign in to manage your schedules")
		return
	}
	if r.Method == http.MethodPost && !sameOrigin(r) {
		httpError(w, 403, "cross-site request refused")
		return
	}
	if r.Method == http.MethodPost {
		s.ensurePerson(r)
	}
	s.scheduleRequest(w, r, owner, nil)
}
func (s *Server) handleNodeSchedules(w http.ResponseWriter, r *http.Request) {
	ep, hash, ok := s.nodeEndpointOr(w, r, "node identity required", "unknown node")
	if !ok {
		return
	}
	host, login := s.nodeIdentity(ep)
	owner, e := s.Store.PrincipalForLogin(host, login)
	if e != nil || owner == "" {
		httpError(w, 403, "this login has no Tokenman owner")
		return
	}
	if a := r.Header.Get(workerAssertHeader); a != "" {
		c, e := verifyWorkerAssertion(a, hash, time.Now())
		if e != nil {
			httpError(w, 401, "invalid worker identity")
			return
		}
		fl, e := s.Store.Fleet(c.FleetUUID)
		if e != nil || fl.EndpointID != ep.ID {
			httpError(w, 404, "session does not belong to this login")
			return
		}
	}
	if r.URL.Path == NodeSchedulesPath+"/admit" || r.URL.Path == NodeSchedulesPath+"/finish" {
		s.scheduleRunRequest(w, r, owner, ep)
		return
	}
	s.scheduleRequest(w, r, owner, ep)
}
func (s *Server) scheduleRequest(w http.ResponseWriter, r *http.Request, owner string, ep *store.Endpoint) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodGet {
		if r.URL.Query().Get("preview") == "1" {
			q := r.URL.Query()
			spec := schedule.Spec{ID: "schedule-preview", Revision: 1, Name: "preview", Prompt: "preview", At: q.Get("at"), Cron: q.Get("cron"), Timezone: q.Get("timezone")}
			if spec.Timezone == "" {
				spec.Timezone = "Asia/Shanghai"
			}
			next, err := schedule.Preview(spec, time.Now())
			if err != nil {
				scheduleError(w, err)
				return
			}
			writeJSON(w, 200, map[string]any{"next_run": next.Unix(), "timezone": spec.Timezone})
			return
		}
		if id := r.URL.Query().Get("id"); id != "" {
			row, e := s.Store.Schedule(owner, id)
			if e != nil {
				scheduleError(w, e)
				return
			}
			if ep != nil && row.Endpoint != "" && row.Endpoint != ep.ID {
				httpError(w, 404, "no schedule in this login")
				return
			}
			runs, e := s.Store.ScheduleRuns(owner, id)
			if e != nil {
				scheduleError(w, e)
				return
			}
			for i := range runs {
				var d map[string]any
				_ = json.Unmarshal(runs[i].Delivery, &d)
				if d == nil {
					d = map[string]any{}
				}
				if n, _ := s.Store.Notice("nt-schedule-" + runs[i].ID); n != nil {
					d["wechat"] = n.State
					if n.Channel != "" {
						d["wechat_channel"] = n.Channel
					}
				}
				if n, _ := s.Store.Notice("np-schedule-" + runs[i].ID); n != nil && d["livepage"] == nil {
					d["livepage"] = n.State
				}
				runs[i].Delivery, _ = json.Marshal(d)
			}
			writeJSON(w, 200, map[string]any{"schedule": s.scheduleView(row), "runs": runs})
			return
		}
		rows, e := s.Store.Schedules(owner)
		if e != nil {
			scheduleError(w, e)
			return
		}
		out := []any{}
		for _, row := range rows {
			if ep == nil || row.Endpoint == ep.ID {
				out = append(out, s.scheduleView(row))
			}
		}
		unread, _ := s.Store.ScheduleUnread(owner)
		writeJSON(w, 200, map[string]any{"schedules": out, "unread": unread, "limits": map[string]int{"tasks": 10, "daily_slots": 24, "daily_starts": 30, "concurrent": 1}})
		return
	}
	if r.Method != http.MethodPost {
		httpError(w, 405, "GET or POST")
		return
	}
	var in scheduleRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10))
	dec.DisallowUnknownFields()
	if e := dec.Decode(&in); e != nil {
		scheduleError(w, e)
		return
	}
	if !idemRE.MatchString(in.Key) {
		httpError(w, 400, "idempotency_key required")
		return
	}
	if in.Action == "read" {
		row, e := s.Store.Schedule(owner, in.ID)
		if e != nil {
			scheduleError(w, e)
			return
		}
		if ep != nil && row.Endpoint != ep.ID {
			httpError(w, 404, "no schedule in this login")
			return
		}
		if e = s.Store.ScheduleRead(owner, in.ID); e != nil {
			scheduleError(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	raw, _ := json.Marshal(in)
	var row store.Schedule
	var e error
	if in.Action == "create" {
		if in.ID != "" || in.Revision != 0 {
			httpError(w, 400, "create assigns its own id and revision")
			return
		}
		row.Spec = schedule.Spec{Entry: in.Adopt, ID: "schedule-" + scheduleHash(owner, in.Key), Revision: 1, Enabled: true, Timezone: "Asia/Shanghai"}
		if ep != nil {
			row.Endpoint = ep.ID
			row.Hostname, row.Login = s.nodeIdentity(ep)
		}
	} else {
		if in.Adopt != "" {
			httpError(w, 400, "adopt is only accepted on create")
			return
		}
		row, e = s.Store.Schedule(owner, in.ID)
		if e != nil {
			scheduleError(w, e)
			return
		}
		if ep != nil && row.Endpoint != ep.ID {
			httpError(w, 404, "no schedule in this login")
			return
		}
		if in.Action == "run-now" {
			if row.Spec.Deleted || row.SyncState != "synced" {
				httpError(w, 409, "schedule is not ready")
				return
			}
			run := "manual-" + scheduleHash(owner, in.Key)
			if e = s.Store.ScheduleManual(owner, row.Spec.ID, run, time.Now()); e != nil {
				scheduleError(w, e)
				return
			}
			out, e := s.scheduleSend(r.Context(), row, "run-now", run)
			if e != nil {
				scheduleError(w, e)
				return
			}
			writeJSON(w, 200, out)
			return
		}
		row.Spec.Revision = in.Revision + 1
	}
	if in.Name != nil {
		row.Spec.Name = *in.Name
	}
	if in.Prompt != nil {
		row.Spec.Prompt = *in.Prompt
	}
	if in.At != nil {
		row.Spec.At = *in.At
		row.Spec.Cron = ""
	}
	if in.Cron != nil {
		row.Spec.Cron = *in.Cron
		row.Spec.At = ""
	}
	if in.At != nil && in.Cron != nil && *in.At != "" && *in.Cron != "" {
		httpError(w, 400, "at and cron are mutually exclusive")
		return
	}
	if in.Timezone != nil {
		row.Spec.Timezone = *in.Timezone
	}
	if in.Delivery != nil {
		row.Spec.Delivery = *in.Delivery
	}
	if in.Repo != nil {
		row.Spec.Repo = *in.Repo
	}
	switch in.Action {
	case "create", "update":
	case "pause":
		row.Spec.Enabled = false
	case "resume":
		row.Spec.Enabled = true
	case "delete":
		row.Spec.Deleted = true
		row.Spec.Enabled = false
	default:
		httpError(w, 400, "unknown action")
		return
	}
	if _, e = schedule.Validate(row.Spec); e != nil {
		scheduleError(w, e)
		return
	}
	row, e = s.Store.SaveSchedule(owner, in.Key, string(raw), row, in.Revision, time.Now())
	if e != nil {
		scheduleError(w, e)
		return
	}
	_ = s.Store.HubAudit(owner, "schedule."+in.Action, row.Spec.ID, "accepted", "", time.Now())
	// Installing a definition can be retried after an interrupted request: the
	// node compares full documents and revisions. No run is started by this loop.
	if row.SyncState == "pending" {
		s.installSchedule(r.Context(), row)
		row, _ = s.Store.Schedule(owner, row.Spec.ID)
	}
	writeJSON(w, 200, map[string]any{"schedule": s.scheduleView(row)})
}
func (s *Server) scheduleView(row store.Schedule) any {
	// Use the existing heartbeat as the live read, with an explicit observed time.
	nodes, _ := s.Store.Nodes()
	var observedAt *time.Time
	for _, n := range nodes {
		if n.Hostname != row.Hostname || n.LastHeartbeat == nil || (observedAt != nil && !n.LastHeartbeat.After(*observedAt)) {
			continue
		}
		var hb struct {
			Services []map[string]any `json:"services"`
		}
		if json.Unmarshal([]byte(n.StatusJSON), &hb) != nil {
			continue
		}
		for _, svc := range hb.Services {
			entry := row.Spec.Entry
			if entry == "" {
				entry = row.Spec.ID
			}
			if svc["name"] == entry && svc["login"] == row.Login {
				for _, key := range []string{"last_line", "last_error"} {
					if v, ok := svc[key].(string); ok {
						svc[key] = redactLogLine(v)
					}
				}
				svc["observed_at"] = n.LastHeartbeat
				svc["stale"] = time.Since(*n.LastHeartbeat) > 2*time.Minute
				row.Observed, _ = json.Marshal(svc)
				observedAt = n.LastHeartbeat
			}
		}
	}
	if observedAt == nil {
		var o map[string]any
		_ = json.Unmarshal(row.Observed, &o)
		if o == nil {
			o = map[string]any{}
		}
		o["stale"] = true
		row.Observed, _ = json.Marshal(o)
	}
	return row
}
func (s *Server) scheduleTarget(ctx context.Context, row store.Schedule) (store.FleetRow, error) {
	own, e := s.ownScope(row.Owner)
	if e != nil {
		return store.FleetRow{}, e
	}
	if !own(row.Hostname, row.Login) {
		return store.FleetRow{}, errors.New("schedule login no longer belongs to you")
	}
	if c := s.nodes.get(row.Endpoint); c != nil {
		if !c.canSchedule {
			return store.FleetRow{}, errors.New("runtime upgrade pending")
		}
	} else if peer, ok := s.peerOf(ctx, row.Endpoint); !ok || !peer.HasCap(schedule.Capability) {
		return store.FleetRow{}, errors.New("runtime offline or upgrade pending")
	}
	return store.FleetRow{EndpointID: row.Endpoint, Hostname: row.Hostname, OSUser: row.Login, Present: true}, nil
}
func (s *Server) scheduleSend(ctx context.Context, row store.Schedule, action, run string) (map[string]any, error) {
	target, e := s.scheduleTarget(ctx, row)
	if e != nil {
		return nil, e
	}
	body := map[string]any{"login": row.Login, "action": action, "schedule": row.Spec}
	if run != "" {
		body["run_id"] = run
	}
	b, _ := json.Marshal(body)
	key := fmt.Sprintf("schedule-%s-%d-%s-%s", row.Spec.ID, row.Spec.Revision, action, run)
	key = scheduleHash(key)
	op := store.FleetOperation{ID: "schedule-" + key, Actor: row.Owner, Idem: key, Action: "schedule_control", Request: string(b), Status: "pending", Created: time.Now(), Updated: time.Now(), TaskOwner: row.Owner}
	e = s.Store.InsertFleetOperation(op)
	if e != nil && !errors.Is(e, store.ErrIdemTaken) {
		return nil, e
	}
	if e != nil {
		prior, err := s.Store.FleetOperationByIdem(row.Owner, key)
		if err != nil {
			return nil, err
		}
		op = prior
		if prior.Status == "succeeded" {
			return operationView(prior), nil
		}
	}
	status, result := s.sendWrite(ctx, target, op, map[string]any{"operation_id": op.ID, "fleet_id": "", "action": op.Action, "params": body, "actor": row.Owner})
	if e = s.Store.UpdateFleetOperation(op.ID, status, result, time.Now()); e != nil {
		return nil, e
	}
	op, e = s.Store.FleetOperation(op.ID)
	if e != nil {
		return nil, e
	}
	if status != "succeeded" {
		return operationView(op), fmt.Errorf("runtime has not confirmed %s: %s", action, redactLogLine(result))
	}
	return operationView(op), nil
}
func (s *Server) installSchedule(ctx context.Context, row store.Schedule) {
	if row.Endpoint == "" {
		if !s.holdsLogin(row.Owner) {
			s.placePrincipalRuntime(row.Owner, "", row.Owner, true)
		}
		home, e := s.homePick(row.Owner, "", time.Now())
		if e != nil || home.Machine == nil {
			_ = s.Store.ScheduleSynced(row, "pending", "正在准备你的运行环境", "{}")
			return
		}
		login, ok, e := s.homeLoginFor(row.Owner, home.Machine.Hostname)
		if e != nil || !ok {
			return
		}
		nodes, _ := s.Store.Nodes()
		for _, n := range nodes {
			if n.Hostname == home.Machine.Hostname && n.OSUser == login {
				if s.Store.BindSchedule(row, n.EndpointID, n.Hostname, login) == nil {
					row.Endpoint, row.Hostname, row.Login = n.EndpointID, n.Hostname, login
				}
				break
			}
		}
	}
	if row.Endpoint == "" {
		return
	}
	out, e := s.scheduleSend(ctx, row, "apply", "")
	if e != nil {
		_ = s.Store.ScheduleSynced(row, "pending", clipText(e.Error(), 300), "{}")
		return
	}
	b, _ := json.Marshal(out)
	_ = s.Store.ScheduleSynced(row, "synced", "", string(b))
}

// RunScheduleInstalls reconciles requested definitions, never due times. The
// root-owned registry and its existing supervisor remain the only scheduler.
func (s *Server) RunScheduleInstalls(ctx context.Context) {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	lastPrune := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if time.Since(lastPrune) > time.Hour {
				if s.Store.PruneScheduleRuns(time.Now()) == nil {
					lastPrune = time.Now()
				}
			}
			if pending, err := s.Store.ScheduleUnqueued(); err == nil {
				for _, run := range pending {
					s.scheduleNotify(run)
				}
			}
			rows, e := s.Store.PendingSchedules()
			if e != nil {
				continue
			}
			for _, row := range rows {
				if ctx.Err() != nil {
					return
				}
				s.installSchedule(ctx, row)
			}
		}
	}
}

var scheduleSlotRE = regexp.MustCompile(`^[a-zA-Z0-9-]{1,80}$`)

func (s *Server) scheduleRunRequest(w http.ResponseWriter, r *http.Request, owner string, ep *store.Endpoint) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "POST required")
		return
	}
	var in struct {
		ID        string `json:"id"`
		Revision  int64  `json:"revision"`
		Slot      string `json:"slot"`
		Attempt   int    `json:"attempt"`
		Manual    bool   `json:"manual"`
		RunID     string `json:"run_id"`
		State     string `json:"state"`
		Summary   string `json:"summary"`
		Error     string `json:"error"`
		SessionID string `json:"session_id"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10))
	dec.DisallowUnknownFields()
	if e := dec.Decode(&in); e != nil {
		scheduleError(w, e)
		return
	}
	var run store.ScheduleRun
	var e error
	if strings.HasSuffix(r.URL.Path, "/admit") {
		if !schedule.ID.MatchString(in.ID) || !scheduleSlotRE.MatchString(in.Slot) {
			httpError(w, 400, "invalid slot")
			return
		}
		row, err := s.Store.Schedule(owner, in.ID)
		if err != nil {
			scheduleError(w, err)
			return
		}
		// Recovery of an admitted run must not be refused by the capacity
		// that this very run occupies, or by a later pause/edit.
		rid := fmt.Sprintf("%s-%s-%d", in.ID, in.Slot, in.Attempt)
		if previous, err := s.Store.ScheduleRun(owner, rid); err == nil && previous.Endpoint == ep.ID {
			writeJSON(w, 200, map[string]any{"run": previous})
			return
		}
		if !in.Manual && !schedule.DueSlot(row.Spec, in.Slot, time.Now()) {
			httpError(w, 409, "scheduled occurrence expired or does not match")
			return
		}
		target, err := s.scheduleTarget(r.Context(), row)
		if err != nil {
			httpError(w, 503, err.Error())
			return
		}
		budget, err := s.personBudgetState(owner, time.Now())
		if err != nil {
			httpError(w, 503, "usage check unavailable")
			return
		}
		if budget.Over {
			httpError(w, 429, budget.Message)
			return
		}
		if err = s.checkMemberSessions(target, time.Now()); err != nil {
			httpError(w, 429, err.Error())
			return
		}
		run, e = s.Store.AdmitSchedule(owner, ep.ID, in.ID, in.Slot, in.Revision, in.Attempt, in.Manual, time.Now())
	} else {
		if len(in.Summary) > 128<<10 || len(in.Error) > 2000 || len(in.SessionID) > 200 {
			httpError(w, 400, "result too large")
			return
		}
		run, e = s.Store.FinishSchedule(owner, ep.ID, in.RunID, in.State, redactLogLine(in.Summary), redactLogLine(in.Error), in.SessionID, time.Now())
		if e == nil {
			s.scheduleNotify(run)
		}
	}
	if e != nil {
		scheduleError(w, e)
		return
	}
	writeJSON(w, 200, map[string]any{"run": run})
}
func (s *Server) scheduleNotify(run store.ScheduleRun) {
	row, e := s.Store.Schedule(run.Owner, run.ScheduleID)
	if e != nil {
		return
	}
	if run.State == "failed" && run.Attempt < 3 {
		_ = s.Store.ScheduleQueued(run.Owner, run.ID)
		return
	}
	var snapshot struct {
		Consent schedule.Delivery `json:"consent"`
	}
	_ = json.Unmarshal(run.Delivery, &snapshot)
	if row.Spec.Deleted {
		_ = s.Store.ScheduleQueued(run.Owner, run.ID)
		return
	}
	if snapshot.Consent.WeChat && row.Spec.Delivery.WeChat {
		n := store.Notice{ID: "nt-schedule-" + run.ID, Kind: "schedule_result", Owner: run.Owner, Prefer: store.NotifyWeChat, Refs: []string{run.ID}}
		if e := s.Store.EnqueueNotice(n, time.Now()); e != nil {
			prior, err := s.Store.Notice(n.ID)
			if err != nil || prior == nil || prior.Owner != run.Owner {
				return
			}
		}
		s.notifyKick()
	}
	if snapshot.Consent.LivePage && row.Spec.Delivery.LivePage && run.State == "succeeded" {
		n := store.Notice{ID: "np-schedule-" + run.ID, Kind: "schedule_page", Owner: run.Owner, Refs: []string{run.ID}}
		if e := s.Store.EnqueueNotice(n, time.Now()); e != nil {
			prior, err := s.Store.Notice(n.ID)
			if err != nil || prior == nil || prior.Owner != run.Owner {
				return
			}
		}
		s.notifyKick()
	}
	_ = s.Store.ScheduleQueued(run.Owner, run.ID)
}
