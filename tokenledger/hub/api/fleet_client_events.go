package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A client's connection events (claude-fleet T689, 稳定性①).
//
// The `fleet` client (bin/fleet-thin.py, through bin/fleet_client_events.py)
// spools each thing its line did and sends the spool here when the hub
// answers — a start, the view drawn (`up`; its ms is the reconnect when it
// follows a drop), a `drop` and ssh's last word, a `fail` (a connection that
// did not come up, phase start or reconnect, and why), a `rehome`, `offline`
// (its own line down), a `quit`. Admitted the way the summary door admits a
// status bar: a session / viewer token / node token, else a connection
// certificate's signed timestamp. Every field is a code, a machine name or a
// number; anything else is refused event by event — so no credential and no
// byte of a terminal ever lands in the table.
//
// GET ?hours=N (default 24, at most 720) answers the statistics the doctor
// prints — drops, reconnect p50 / p90, open failures and their reasons — per
// device × home, per device and in total; ?events=1 adds the rows themselves.
// A person (their session, their login's node token) reads their own clients;
// the operator everyone's.

// ClientEventsRequest is one batch. Cert / Sig / TS prove a connection
// certificate (Sig over control.ClientEventsSigMessage(TS)); a bearer the
// doors accept needs none of them.
type ClientEventsRequest struct {
	Cert   string            `json:"cert,omitempty"`
	Sig    string            `json:"sig,omitempty"`
	TS     int64             `json:"ts,omitempty"`
	Device string            `json:"device"`
	Events []ClientEventWire `json:"events"`
}

// ClientEventWire is one event as a client sends it.
type ClientEventWire struct {
	ID      string `json:"id"`
	At      string `json:"at"`
	Event   string `json:"event"`
	Start   string `json:"start,omitempty"`
	Phase   string `json:"phase,omitempty"`
	Home    string `json:"home,omitempty"`
	Route   string `json:"route,omitempty"`
	To      string `json:"to,omitempty"`
	MS      int64  `json:"ms,omitempty"`
	RC      int64  `json:"rc,omitempty"`
	Reason  string `json:"reason,omitempty"`
	Version string `json:"ver,omitempty"`
}

// ClientEventsAnswer is the POST's answer: the client drops every id it sent
// (a refused event would be refused again).
type ClientEventsAnswer struct {
	Accepted  int `json:"accepted"`
	Duplicate int `json:"duplicate"`
	Refused   int `json:"refused"`
}

// ClientLineStats is one group's statistics.
type ClientLineStats struct {
	Device         string         `json:"device,omitempty"`
	Home           string         `json:"home,omitempty"`
	Starts         int            `json:"starts"`
	Ups            int            `json:"ups"`
	Drops          int            `json:"drops"`
	DropReasons    map[string]int `json:"drop_reasons"`
	Reconnects     int            `json:"reconnects"`
	ReconnectP50MS int64          `json:"reconnect_p50_ms"`
	ReconnectP90MS int64          `json:"reconnect_p90_ms"`
	// Fails / FailReasons: connections that did not come up before this
	// start's first view (起不来); ReconnectFails: those after a drop.
	Fails                int            `json:"fails"`
	StartsFailed         int            `json:"starts_failed"`
	FailReasons          map[string]int `json:"fail_reasons"`
	ReconnectFails       int            `json:"reconnect_fails"`
	ReconnectFailReasons map[string]int `json:"reconnect_fail_reasons"`
	Rehomes              int            `json:"rehomes"`
	Offline              int            `json:"offline"`
	LastAt               *time.Time     `json:"last_at,omitempty"`
}

// ClientEventsReport is the GET's answer.
type ClientEventsReport struct {
	At      time.Time                `json:"at"`
	Hours   int                      `json:"hours"`
	Total   ClientLineStats          `json:"total"`
	Devices []ClientLineStats        `json:"devices"`
	By      []ClientLineStats        `json:"by"`
	Events  []store.FleetClientEvent `json:"events,omitempty"`
}

const clientEventsMax = 500

var (
	clientEventKinds  = map[string]bool{"start": true, "up": true, "drop": true, "fail": true, "rehome": true, "offline": true, "quit": true}
	clientEventPhases = map[string]bool{"": true, "start": true, "reconnect": true}
	clientNameRE      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.@-]{0,63}$`)
	clientReasonRE    = regexp.MustCompile(`^[a-z0-9][a-z0-9_.:-]{0,47}$`)
	clientIDRE        = regexp.MustCompile(`^[0-9a-f]{8,40}$`)
	clientVersionRE   = regexp.MustCompile(`^[0-9A-Za-z._-]{1,64}$`)
)

// clientName is s when it is a short name ("" stays ""), else "?" — never the
// text itself.
func clientName(s string) (string, bool) {
	if s == "" || s == "-" {
		return "", true
	}
	return s, clientNameRE.MatchString(s)
}

func (s *Server) handleFleetClientEvents(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		s.postClientEvents(w, r)
	case http.MethodGet:
		s.getClientEvents(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

func (s *Server) postClientEvents(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	var req ClientEventsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "a JSON body {device, events} is required")
		return
	}
	id, ok := s.fleetReadIdentity(r)
	fp := ""
	if !ok {
		if req.Cert == "" || req.Sig == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
			httpError(w, http.StatusUnauthorized, "a session, a token or a connection certificate is required")
			return
		}
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		var err error
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, control.ClientEventsSigMessage(req.TS), control.ClientEventsSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if pub, _, _, _, err := ssh.ParseAuthorizedKey([]byte(req.Cert)); err == nil {
			if c, ok := pub.(*ssh.Certificate); ok {
				fp = ssh.FingerprintSHA256(c.Key)
			}
		}
	}
	if len(req.Events) > clientEventsMax {
		httpError(w, http.StatusRequestEntityTooLarge, "at most "+strconv.Itoa(clientEventsMax)+" events a batch")
		return
	}
	who := id.Principal
	if who == "" {
		who = id.Actor
	}
	// The device: the hub's own name for the certificate's key, else the
	// client's word when it is a name, else the node the token belongs to.
	device, okName := clientName(req.Device)
	if !okName {
		device = ""
	}
	if fp != "" {
		if d, err := s.Store.Device(fp); err == nil && d.Name != "" {
			if n, ok := clientName(d.Name); ok && n != "" {
				device = n
			}
		}
	}
	if device == "" && strings.HasPrefix(id.Actor, "node:") {
		device, _ = clientName(strings.SplitN(strings.TrimPrefix(id.Actor, "node:"), "/", 2)[0])
	}
	if device == "" {
		device = "?"
	}
	var ans ClientEventsAnswer
	evs := make([]store.FleetClientEvent, 0, len(req.Events))
	for _, e := range req.Events {
		ev, ok := clientEvent(e, now)
		if !ok {
			ans.Refused++
			continue
		}
		ev.ID = who + ":" + e.ID
		ev.PrincipalID, ev.DeviceFP, ev.Device = who, fp, device
		evs = append(evs, ev)
	}
	added, err := s.Store.AddClientEvents(evs, now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	ans.Accepted, ans.Duplicate = added, len(evs)-added
	writeJSON(w, http.StatusOK, ans)
}

// clientEvent checks one event field by field; ok=false refuses it.
func clientEvent(e ClientEventWire, now time.Time) (store.FleetClientEvent, bool) {
	at, err := time.Parse(time.RFC3339, e.At)
	if err != nil || at.After(now.Add(10*time.Minute)) || at.Before(now.Add(-store.ClientEventsKeep)) {
		return store.FleetClientEvent{}, false
	}
	if !clientIDRE.MatchString(e.ID) || !clientEventKinds[e.Event] || !clientEventPhases[e.Phase] {
		return store.FleetClientEvent{}, false
	}
	if e.Start != "" && !clientIDRE.MatchString(e.Start) {
		return store.FleetClientEvent{}, false
	}
	home, ok1 := clientName(e.Home)
	route, ok2 := clientName(e.Route)
	to, ok3 := clientName(e.To)
	if !ok1 || !ok2 || !ok3 {
		return store.FleetClientEvent{}, false
	}
	if e.Reason != "" && !clientReasonRE.MatchString(e.Reason) {
		return store.FleetClientEvent{}, false
	}
	if e.Version != "" && !clientVersionRE.MatchString(e.Version) {
		return store.FleetClientEvent{}, false
	}
	if e.MS < 0 || e.MS > 30*24*3600*1000 || e.RC < -1 || e.RC > 1000 {
		return store.FleetClientEvent{}, false
	}
	return store.FleetClientEvent{At: at.UTC().Truncate(time.Second), Event: e.Event, Start: e.Start,
		Phase: e.Phase, Home: home, Route: route, To: to, MS: e.MS, RC: e.RC, Reason: e.Reason,
		Version: e.Version}, true
}

func (s *Server) getClientEvents(w http.ResponseWriter, r *http.Request) {
	id, ok := s.fleetReadIdentity(r)
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a session, a viewer token or a node token is required")
		return
	}
	now := time.Now()
	hours := 24
	if v := r.URL.Query().Get("hours"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 720 {
			httpError(w, http.StatusBadRequest, "hours is 1..720")
			return
		}
		hours = n
	}
	principal := ""
	if !id.Operator {
		principal = id.Principal
		if principal == "" {
			writeJSON(w, http.StatusOK, clientEventsReport(nil, now, hours))
			return
		}
	}
	evs, err := s.Store.ClientEvents(principal, r.URL.Query().Get("device"), now.Add(-time.Duration(hours)*time.Hour), 0)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out := clientEventsReport(evs, now, hours)
	if r.URL.Query().Get("events") == "1" {
		out.Events = evs
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// clientEventsReport folds events (oldest first) into the three cuts.
func clientEventsReport(evs []store.FleetClientEvent, now time.Time, hours int) ClientEventsReport {
	out := ClientEventsReport{At: now.UTC(), Hours: hours, Devices: []ClientLineStats{}, By: []ClientLineStats{}}
	group := func(evs []store.FleetClientEvent, key func(store.FleetClientEvent) (string, string)) []ClientLineStats {
		parts := map[[2]string][]store.FleetClientEvent{}
		var keys [][2]string
		for _, e := range evs {
			d, h := key(e)
			k := [2]string{d, h}
			if _, seen := parts[k]; !seen {
				keys = append(keys, k)
			}
			parts[k] = append(parts[k], e)
		}
		sort.Slice(keys, func(i, j int) bool {
			if keys[i][0] != keys[j][0] {
				return keys[i][0] < keys[j][0]
			}
			return keys[i][1] < keys[j][1]
		})
		rows := []ClientLineStats{}
		for _, k := range keys {
			st := clientLineStats(parts[k])
			st.Device, st.Home = k[0], k[1]
			rows = append(rows, st)
		}
		return rows
	}
	out.Total = clientLineStats(evs)
	out.Devices = group(evs, func(e store.FleetClientEvent) (string, string) { return e.Device, "" })
	// A start has no home yet: it is counted on the device, not on a home.
	var homed []store.FleetClientEvent
	for _, e := range evs {
		if e.Home != "" {
			homed = append(homed, e)
		}
	}
	out.By = group(homed, func(e store.FleetClientEvent) (string, string) { return e.Device, e.Home })
	return out
}

func clientLineStats(evs []store.FleetClientEvent) ClientLineStats {
	st := ClientLineStats{DropReasons: map[string]int{}, FailReasons: map[string]int{}, ReconnectFailReasons: map[string]int{}}
	var gaps []int64
	failedStarts := map[string]bool{}
	for _, e := range evs {
		switch e.Event {
		case "start":
			st.Starts++
		case "up":
			st.Ups++
			if e.Phase == "reconnect" {
				st.Reconnects++
				gaps = append(gaps, e.MS)
			}
		case "drop":
			st.Drops++
			st.DropReasons[orDash(e.Reason)]++
		case "fail":
			if e.Phase == "reconnect" {
				st.ReconnectFails++
				st.ReconnectFailReasons[orDash(e.Reason)]++
				break
			}
			st.Fails++
			st.FailReasons[orDash(e.Reason)]++
			if e.Start != "" {
				failedStarts[e.Device+"/"+e.Start] = true
			}
		case "rehome":
			st.Rehomes++
		case "offline":
			st.Offline++
		}
		at := e.At
		if st.LastAt == nil || at.After(*st.LastAt) {
			st.LastAt = &at
		}
	}
	st.StartsFailed = len(failedStarts)
	sort.Slice(gaps, func(i, j int) bool { return gaps[i] < gaps[j] })
	st.ReconnectP50MS, st.ReconnectP90MS = nearestRank(gaps, 50), nearestRank(gaps, 90)
	return st
}

// nearestRank is the p-th percentile of sorted xs (nearest rank); 0 for none.
func nearestRank(xs []int64, p int) int64 {
	if len(xs) == 0 {
		return 0
	}
	i := (p*len(xs) + 99) / 100
	if i < 1 {
		i = 1
	}
	return xs[i-1]
}
