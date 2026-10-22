package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 紧急开关 (WACK C5): one admin page, /admin/emergency (the old spelling
// /app/admin/emergency moves on there), for the four things an incident
// needs at once — each one a press, each audited and told to the admins:
//
//	GET  /v1/admin/emergency                 the switches' state
//	POST /v1/admin/emergency {action, target?, reason?}
//
//	trial_stop     every road into a NEW trial answers 「试用暂停，稍后再来」:
//	               /app/try (start and claim), a 试用二维码's scan and its line.
//	               A trial already running goes on. fleet.trial.halt holds
//	               who pressed it and when.
//	trial_resume   lifts it.
//	code_disable   one 试用二维码 stops (target: its id) — the trial-codes
//	               page's stop; those it already let in keep their trial.
//	person_stop    one person (target: a principal or a GitHub username) is
//	               taken off the list, their devices, web sessions and
//	               subscriptions revoked, and every session on their logins
//	               stopped through its node (worker_stop → fleet_win_retire);
//	               for the next hour the alerts tick stops any that is still
//	               or again listed. Their logins and files are not touched.
//	machine_pause  one machine takes no one new (target: its name) — the
//	               maintenance flag, fleet.node_maintenance.<machine>.
//
// Every press is a fleet_audit row emergency.<action> (actor, target,
// outcome) and one line to the admins' WeChat through the hub's notifier
// (FLEET_NOTIFY_CMD → FLEET_NOTIFY_KF), the same (action, target) at most once
// in 30 minutes. An admin only: anyone else is answered 403.

// AdminEmergencyPath is the page's one road.
const AdminEmergencyPath = "/v1/admin/emergency"

// TrialHaltKey is the brake: "" off, else who pressed it, when and why.
// Kept apart from fleet.trial (whose off has always meant «no /app/try road»,
// the 试用二维码 working on regardless): the brake closes every new trial.
const TrialHaltKey = "fleet.trial.halt"

// PersonStopPrefix + <principal> is a person_stop's record, which the sweep
// reads for personStopWatch.
const PersonStopPrefix = "fleet.person_stop."

const (
	emTrialStop    = "trial_stop"
	emTrialResume  = "trial_resume"
	emCodeDisable  = "code_disable"
	emPersonStop   = "person_stop"
	emMachinePause = "machine_pause"

	// trialWaitHalted is the claim's queue reason while the brake is on.
	trialWaitHalted = "halted"

	// personStopWatch: a stopped person's sessions are stopped again on the
	// alerts tick for this long after the press.
	personStopWatch = time.Hour
	// emNotifyQuiet: the same (action, target) is told the admins at most
	// once in it (WACK 共同约定 4).
	emNotifyQuiet = 30 * time.Minute
	// emStopTimeout bounds one worker_stop's send.
	emStopTimeout = 10 * time.Second
)

var emActions = map[string]bool{emTrialStop: true, emTrialResume: true, emCodeDisable: true,
	emPersonStop: true, emMachinePause: true}

func init() {
	hubSettings[TrialHaltKey] = hubSetting{def: "",
		help:  "the emergency brake (WACK C5, the console's 紧急开关): set, no new trial starts on any road — /app/try, a 试用二维码 — and the page says 「试用暂停，稍后再来」; running trials go on. Pressed and lifted on /admin/emergency, which writes who and when; \"\" lifts it. 紧急停止所有新试用",
		check: checkTrialHalt}
}

// emRecord is a press's who · when · why, the value of fleet.trial.halt and
// of fleet.person_stop.<pid>.
type emRecord struct {
	By     string    `json:"by,omitempty"`
	Name   string    `json:"name,omitempty"` // a person_stop's person as the list named them
	At     time.Time `json:"at"`
	Reason string    `json:"reason,omitempty"`
}

func checkTrialHalt(_ *Server, v string) (string, string) {
	v = strings.TrimSpace(v)
	switch {
	case v == "", strings.EqualFold(v, "off"):
		return "", ""
	case strings.EqualFold(v, "on"):
		b, _ := json.Marshal(emRecord{At: time.Now().UTC(), Reason: "set by hand"})
		return string(b), ""
	}
	var rec emRecord
	if json.Unmarshal([]byte(v), &rec) != nil {
		return "", TrialHaltKey + ` is "" (off), on, or {"by","at","reason"}`
	}
	return v, ""
}

// trialHalt is the brake's record, ok false when it is off.
func (s *Server) trialHalt() (emRecord, bool) {
	v := strings.TrimSpace(s.setting(TrialHaltKey))
	if v == "" || strings.EqualFold(v, "off") {
		return emRecord{}, false
	}
	var rec emRecord
	if json.Unmarshal([]byte(v), &rec) != nil {
		rec = emRecord{Reason: v}
	}
	return rec, true
}

func (s *Server) trialHalted() bool {
	if s.Store == nil {
		return false
	}
	_, on := s.trialHalt()
	return on
}

// trialHaltWords is what a person meets while the brake is on.
func trialHaltWords(en bool) string {
	return ternary(en, "Trials are paused — try again later.", "试用暂停，稍后再来。")
}

// emergencyView is GET's answer and every POST's.
type emergencyView struct {
	Trial    emTrialView   `json:"trial"`
	Codes    []emCodeView  `json:"codes"`
	People   []emPerson    `json:"people"`
	Stopped  []emPerson    `json:"stopped"`
	Machines []emMachine   `json:"machines"`
	Done     *emergencyRun `json:"done,omitempty"`
}

type emTrialView struct {
	Stopped bool       `json:"stopped"`
	By      string     `json:"by,omitempty"`
	At      *time.Time `json:"at,omitempty"`
	Reason  string     `json:"reason,omitempty"`
	// Saw is how many people met the pause since it was pressed.
	Saw int `json:"saw"`
	// Trying is how many people are in a trial now — the ones a stop leaves alone.
	Trying int `json:"trying"`
}

type emCodeView struct {
	ID      string `json:"id"`
	Channel string `json:"channel"`
	State   string `json:"state"`
	// Granted is how many it let in — the people a stop leaves their trial.
	Granted int `json:"granted"`
}

type emPerson struct {
	Principal string `json:"principal"`
	Login     string `json:"login"`
	Role      string `json:"role,omitempty"`
	Trial     bool   `json:"trial,omitempty"`
	// Sessions is how many sessions a stop would end.
	Sessions int        `json:"sessions"`
	By       string     `json:"by,omitempty"`
	At       *time.Time `json:"at,omitempty"`
}

type emMachine struct {
	Hostname string `json:"hostname"`
	Status   string `json:"status"`
	Paused   bool   `json:"paused"`
	// Sessions is how many sessions run there — a pause leaves them.
	Sessions int        `json:"sessions"`
	Since    *time.Time `json:"since,omitempty"`
	By       string     `json:"by,omitempty"`
}

// emergencyRun is what one press did.
type emergencyRun struct {
	Action  string `json:"action"`
	Target  string `json:"target,omitempty"`
	Outcome string `json:"outcome"`
	// Sessions / Stopped: a person_stop's sessions found and stops the
	// nodes took; Devices the devices revoked.
	Sessions int `json:"sessions,omitempty"`
	Stopped  int `json:"stopped,omitempty"`
	Devices  int `json:"devices,omitempty"`
}

func (s *Server) handleAdminEmergency(w http.ResponseWriter, r *http.Request) {
	if s.Store == nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		v, err := s.emergencyState(time.Now())
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, v)
	case http.MethodPost:
		if !sameOrigin(r) {
			httpError(w, http.StatusForbidden, "cross-site request refused")
			return
		}
		s.adminEmergencyPost(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// emFault is a refusal with its status.
type emFault struct {
	status int
	msg    string
}

func (e *emFault) Error() string { return e.msg }

func (s *Server) adminEmergencyPost(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Action string `json:"action"`
		Target string `json:"target"`
		Reason string `json:"reason"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10)).Decode(&in); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, `want {"action", "target"?, "reason"?}`)
		return
	}
	in.Action, in.Target = strings.TrimSpace(in.Action), strings.TrimSpace(in.Target)
	in.Reason = clipRunes(oneLine(strings.TrimSpace(in.Reason)), 200)
	if !emActions[in.Action] {
		httpError(w, http.StatusBadRequest, "action is trial_stop | trial_resume | code_disable | person_stop | machine_pause")
		return
	}
	actor, now := principalOf(r.Context()), time.Now()
	if actor == "" {
		actor = actorOf(r)
	}
	run, err := s.emergency(r.Context(), actor, in.Action, in.Target, in.Reason, now)
	if err != nil {
		var f *emFault
		status := http.StatusInternalServerError
		if errors.As(err, &f) {
			status = f.status
		}
		s.emAudit(actor, in.Action, in.Target, "refused: "+err.Error(), now)
		httpError(w, status, err.Error())
		return
	}
	v, err := s.emergencyState(time.Now())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	v.Done = &run
	writeJSON(w, http.StatusOK, v)
}

// emergency runs one press; its audit row and the admins' line are written
// here for a press that did something.
func (s *Server) emergency(ctx context.Context, actor, action, target, reason string, now time.Time) (emergencyRun, error) {
	run := emergencyRun{Action: action, Target: target, Outcome: "ok"}
	var line string
	switch action {
	case emTrialStop:
		if rec, on := s.trialHalt(); on {
			run.Outcome = "already"
			if !rec.At.IsZero() {
				run.Outcome += " since " + rec.At.UTC().Format(time.RFC3339)
			}
			break
		}
		b, _ := json.Marshal(emRecord{By: actor, At: now.UTC(), Reason: reason})
		if err := s.Store.SetFleetSetting(TrialHaltKey, string(b), now); err != nil {
			return run, err
		}
		line = "停止了所有新试用 · stopped all new trials"
	case emTrialResume:
		if _, on := s.trialHalt(); !on {
			run.Outcome = "not_stopped"
			break
		}
		if err := s.Store.SetFleetSetting(TrialHaltKey, "", now); err != nil {
			return run, err
		}
		line = "恢复了新试用 · resumed new trials"
	case emCodeDisable:
		code, err := s.Store.TrialCode(target)
		switch {
		case err != nil:
			return run, err
		case code == nil:
			return run, &emFault{http.StatusNotFound, "no such trial code"}
		}
		changed, err := s.Store.SetTrialCodeState(code.ID, store.TrialCodeStopped, "", now)
		if err != nil {
			return run, err
		}
		if !changed {
			run.Outcome = "already"
			break
		}
		_ = s.Store.HubAudit(actor, "trialcode.stop", code.Channel+" ("+code.ID+")", "ok", code.State+" → "+store.TrialCodeStopped+" · 紧急开关", now)
		run.Target = code.Channel + " (" + code.ID + ")"
		line = "停用了试用码「" + clipRunes(oneLine(code.Channel), 20) + "」 · disabled a trial code"
	case emPersonStop:
		if err := s.emPersonStop(ctx, actor, target, reason, &run, now); err != nil {
			return run, err
		}
		line = fmt.Sprintf("停用了 %s，结束其 %d 个会话 · disabled a person, %d session(s) stopped", run.Target, run.Stopped, run.Stopped)
	case emMachinePause:
		host, err := s.emMachine(target)
		if err != nil {
			return run, err
		}
		why := reason
		if why == "" {
			why = "紧急开关 · emergency"
		}
		_, already, err := s.enterMaintenance(host, why, actor, now)
		if err != nil {
			return run, err
		}
		run.Target = host
		if already {
			run.Outcome = "already"
			break
		}
		s.maintenanceAudit(actor, host, "ENTER "+why, now)
		line = "暂停了机器 " + host + " 接新人 · paused a machine for new people"
	}
	s.emAudit(actor, action, run.Target, run.Outcome, now)
	if line != "" {
		if reason != "" {
			line += "（" + reason + "）"
		}
		s.emNotify(action, run.Target, "ClaudeFleet 紧急开关 · "+actor+" "+line, now)
	}
	return run, nil
}

// emAudit is the press's fleet_audit row.
func (s *Server) emAudit(actor, action, target, outcome string, now time.Time) {
	if err := s.Store.FleetAudit(actor, "emergency."+action, target, outcome, "", now); err != nil {
		log.Printf("emergency: audit %s %s: %v", action, target, err)
	}
}

// emNotified paces the admins' line per (action, target), per Server.
var emNotified sync.Map // *Server → *emNotifyLog

type emNotifyLog struct {
	mu   sync.Mutex
	last map[string]time.Time
}

func (s *Server) emNotify(action, target, msg string, now time.Time) {
	v, _ := emNotified.LoadOrStore(s, &emNotifyLog{last: map[string]time.Time{}})
	nl := v.(*emNotifyLog)
	key := action + "\x00" + target
	nl.mu.Lock()
	last, seen := nl.last[key]
	if seen && now.Sub(last) < emNotifyQuiet {
		nl.mu.Unlock()
		return
	}
	nl.last[key] = now
	nl.mu.Unlock()
	s.notify(msg)
}

// emMachine is target as a machine the roster knows, its first label.
func (s *Server) emMachine(target string) (string, error) {
	if target == "" {
		return "", &emFault{http.StatusBadRequest, "name the machine"}
	}
	nodes, err := s.Store.Nodes()
	if err != nil {
		return "", err
	}
	for _, n := range nodes {
		if sameMachine(n.Hostname, target) || strings.EqualFold(n.Hostname, target) {
			return strings.ToLower(firstLabel(n.Hostname)), nil
		}
	}
	return "", &emFault{http.StatusNotFound, "no machine named " + target}
}

// emPersonStop is person_stop.
func (s *Server) emPersonStop(ctx context.Context, actor, target, reason string, run *emergencyRun, now time.Time) error {
	if target == "" {
		return &emFault{http.StatusBadRequest, "name the person"}
	}
	_, pid, known, err := s.listedPerson(target)
	if err != nil {
		return err
	}
	if !known {
		pid = ""
		if isPerson(target) {
			pid = target // a trial person the list never named
		}
	}
	if pid == "" {
		return &emFault{http.StatusNotFound, target + " is not anyone the hub knows"}
	}
	if pid == actor {
		return &emFault{http.StatusForbidden, "you cannot stop yourself"}
	}
	name := target
	if u, err := s.Store.HubUserByPrincipal(pid); err == nil && u != nil {
		if u.Role == roleAdmin || s.GitHub.isAdminName(u.Login) {
			return &emFault{http.StatusForbidden, "an admin is not stopped from here"}
		}
		if u.Login != "" {
			name = u.Login
		}
	}
	run.Target = name + " (" + pid + ")"
	if _, err := s.Store.DeleteHubPrincipal(pid); err != nil {
		return err
	}
	run.Devices = s.revokePersonDevices(pid, actor, now)
	if err := s.Store.CutSessions(pid, actor, now); err != nil {
		log.Printf("emergency: cut %s's sessions: %v", pid, err)
	}
	if s.Fleet {
		why := "紧急开关 · emergency"
		if reason != "" {
			why += " · " + reason
		}
		if err := s.Store.Revoke("", pid, why, now); err != nil {
			log.Printf("emergency: revoke %s's subscriptions: %v", pid, err)
		} else {
			_ = s.Store.AddCredAudit(store.CredAudit{Action: store.CredRevoke, PrincipalID: pid, Detail: joinDetail(why, "by "+actor)})
			s.relayCacheReset()
			s.sessCred.drop("")
			s.BroadcastCreds(store.CredRevoke)
		}
	}
	b, _ := json.Marshal(emRecord{By: actor, Name: name, At: now.UTC(), Reason: reason})
	if err := s.Store.SetFleetSetting(PersonStopPrefix+pid, string(b), now); err != nil {
		return err
	}
	run.Sessions, run.Stopped = s.stopPersonSessions(ctx, pid, now)
	return nil
}

// personWorkers is every worker_id the registry lists on pid's logins: their
// fleet_accounts rows and their entry home.
func (s *Server) personWorkers(pid string) ([]string, error) {
	type pair struct{ host, login string }
	var pairs []pair
	if as, err := s.Store.FleetAccounts(pid); err == nil {
		for _, a := range as {
			if a.Login != "" {
				pairs = append(pairs, pair{a.Hostname, a.Login})
			}
		}
	} else {
		return nil, err
	}
	if homes, err := s.Store.EntryHomes(); err == nil {
		for _, h := range homes {
			if h.Person == pid && h.Login != "" {
				pairs = append(pairs, pair{h.Machine, h.Login})
			}
		}
	}
	if len(pairs) == 0 {
		return nil, nil
	}
	fleets, err := s.Store.Fleets()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []string
	for _, f := range fleets {
		if !f.Present {
			continue
		}
		mine := false
		for _, p := range pairs {
			if f.OSUser == p.login && (sameMachine(f.Hostname, p.host) || sameMachine(p.host, f.Hostname)) {
				mine = true
			}
		}
		if !mine {
			continue
		}
		for _, ss := range workerSessions(f.FleetID, f.Repo, f.WorkersJSON) {
			if ss.WorkerID != "" && !seen[ss.WorkerID] {
				seen[ss.WorkerID] = true
				out = append(out, ss.WorkerID)
			}
		}
	}
	sort.Strings(out)
	return out, nil
}

// stopPersonSessions sends worker_stop for every session on pid's logins, at
// most once a minute per session (the idempotency key carries the minute);
// found and the stops a node took.
func (s *Server) stopPersonSessions(ctx context.Context, pid string, now time.Time) (found, stopped int) {
	wids, err := s.personWorkers(pid)
	if err != nil {
		log.Printf("emergency: sessions of %s: %v", pid, err)
		return 0, 0
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	minute := strconv.FormatInt(now.Unix()/60, 10)
	for _, wid := range wids {
		wg.Add(1)
		go func(wid string) {
			defer wg.Done()
			sum := sha256.Sum256([]byte(pid + "\x00" + wid))
			key := "emergency:" + hex.EncodeToString(sum[:12]) + ":" + minute
			c, cancel := context.WithTimeout(ctx, emStopTimeout)
			defer cancel()
			op, err := s.SubmitWrite(c, fleetPrincipal{Actor: "emergency"}, "worker_stop",
				map[string]any{"worker_id": wid, "idempotency_key": key})
			if err != nil {
				log.Printf("emergency: stop %s of %s: %v", wid, pid, err)
				return
			}
			if st, _ := op["status"].(string); st == "failed" {
				log.Printf("emergency: stop %s of %s: the node refused it", wid, pid)
				return
			}
			mu.Lock()
			stopped++
			mu.Unlock()
		}(wid)
	}
	wg.Wait()
	return len(wids), stopped
}

// EmergencySweep runs on the alerts tick: a person stopped in the last
// personStopWatch whose session is still (or again) listed is stopped again.
func (s *Server) EmergencySweep(now time.Time) {
	if s.Store == nil || !s.Fleet {
		return
	}
	set, err := s.Store.FleetSettings()
	if err != nil {
		return
	}
	for k, v := range set {
		pid, ok := strings.CutPrefix(k, PersonStopPrefix)
		if !ok || v == "" {
			continue
		}
		var rec emRecord
		if json.Unmarshal([]byte(v), &rec) != nil || now.Sub(rec.At) > personStopWatch {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*emStopTimeout)
		if found, stopped := s.stopPersonSessions(ctx, pid, now); found > 0 {
			log.Printf("emergency: sweep of %s: %d session(s) still listed, %d stop(s) taken", pid, found, stopped)
		}
		cancel()
	}
}

// emergencyState is the page's read.
func (s *Server) emergencyState(now time.Time) (emergencyView, error) {
	v := emergencyView{Codes: []emCodeView{}, People: []emPerson{}, Stopped: []emPerson{}, Machines: []emMachine{}}
	set, err := s.Store.FleetSettings()
	if err != nil {
		return v, err
	}
	if rec, on := s.trialHalt(); on {
		v.Trial.Stopped, v.Trial.By, v.Trial.Reason = true, rec.By, rec.Reason
		if !rec.At.IsZero() {
			at := rec.At
			v.Trial.At = &at
			qr, _ := s.Store.TrialScanOutcomesSince(qrHalted, at)
			try, _ := s.Store.HubAuditTargetsSince("trial.queued", "reason="+trialWaitHalted, at)
			v.Trial.Saw = qr + try
		}
	}
	users, err := s.Store.HubUsers()
	if err != nil {
		return v, err
	}
	trying := map[string]bool{}
	for _, u := range users {
		trial := s.trialIdentity(set, u.PrincipalID)
		if trial {
			trying[u.PrincipalID] = true
		}
		if u.Role == roleAdmin || s.GitHub.isAdminName(u.Login) {
			continue
		}
		p := emPerson{Principal: u.PrincipalID, Login: orDefault(u.Login, u.PrincipalID), Role: u.Role, Trial: trial}
		if wids, err := s.personWorkers(u.PrincipalID); err == nil {
			p.Sessions = len(wids)
		}
		v.People = append(v.People, p)
	}
	if s.Fleet {
		if placed, err := s.Store.PlacedTrials(); err == nil {
			for _, t := range placed {
				trying[t.Principal] = true
			}
		}
	}
	v.Trial.Trying = len(trying)
	sort.Slice(v.People, func(i, j int) bool { return strings.ToLower(v.People[i].Login) < strings.ToLower(v.People[j].Login) })
	for k, val := range set {
		pid, ok := strings.CutPrefix(k, PersonStopPrefix)
		if !ok || val == "" {
			continue
		}
		var rec emRecord
		_ = json.Unmarshal([]byte(val), &rec)
		at := rec.At
		v.Stopped = append(v.Stopped, emPerson{Principal: pid, Login: orDefault(rec.Name, pid), By: rec.By, At: &at})
	}
	sort.Slice(v.Stopped, func(i, j int) bool { return v.Stopped[i].At.After(*v.Stopped[j].At) })
	if codes, err := s.Store.TrialCodes(); err == nil {
		for _, c := range codes {
			cv := emCodeView{ID: c.ID, Channel: c.Channel, State: c.State}
			if gs, err := s.Store.TrialGrantsOfCode(c.ID); err == nil {
				for _, g := range gs {
					if g.State == store.GrantGranted {
						cv.Granted++
					}
				}
			}
			v.Codes = append(v.Codes, cv)
		}
	}
	running := map[string]int{}
	if s.Fleet {
		if fleets, err := s.Store.Fleets(); err == nil {
			for _, f := range fleets {
				if f.Present {
					running[strings.ToLower(firstLabel(f.Hostname))] += len(workerSessions(f.FleetID, f.Repo, f.WorkersJSON))
				}
			}
		}
	}
	if nodes, err := s.Store.Nodes(); err == nil {
		seen := map[string]bool{}
		for _, n := range nodes {
			host := strings.ToLower(firstLabel(n.Hostname))
			if host == "" || seen[host] || s.endpointRole(n.EndpointID) == store.NodeRoleClient {
				continue
			}
			seen[host] = true
			m := emMachine{Hostname: host, Status: nodeAvail(n.Hostname, n.LastHeartbeat, n.HeartbeatMS, set, now), Sessions: running[host]}
			if rec, ok := maintenanceOf(n.Hostname, set); ok {
				m.Paused, m.By = true, rec.By
				if !rec.Since.IsZero() {
					since := rec.Since
					m.Since = &since
				}
			}
			v.Machines = append(v.Machines, m)
		}
		sort.Slice(v.Machines, func(i, j int) bool { return v.Machines[i].Hostname < v.Machines[j].Hostname })
	}
	return v, nil
}
