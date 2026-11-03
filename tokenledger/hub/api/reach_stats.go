package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Reachability from the views (task FQAR; docs/dev/HEALTH.md «会话可达性»).
//
// Each view machine folds its own ledgers into hourly counts —
// bin/fleet-reach-report.py reads view-switch.ndjson (every session enter) and
// peerlink.ndjson (every standing link's up / down) — and POSTs them here,
// admitted the way a client's connection events are: a session, a viewer
// token or a node token as a bearer, else a connection certificate's signed
// timestamp. Nothing in a batch names anyone: a link is the client's own
// 16-hex hash, the caller becomes a 16-hex hash here (src), and every other
// field is a route class or a number. A row the checks refuse is dropped
// alone. /v1/status folds the rows into the public reach_24h / reach_30d
// (publicReachOf), every figure with fewer than reachMinN samples behind it
// published as null ("—").
const (
	ReachStatsPath     = "/v1/fleet/reach-stats"
	reachSigNamespace  = "fleet-reach-stats@claude-fleet"
	reachRowsMax       = 2000
	reachCountMax      = 100000
	reachMinN          = 20
	reachRouteLocal    = "local"
	reachRouteDirect   = "direct"
	reachRouteRelay    = "relay"
	reachRouteUnknown  = "unknown"
	reachHourMS        = 3600 * 1000
	reachRecoveriesMax = 10000
)

// reachSigMessage is what a client signs to send its reach rows with a
// connection certificate, same shape as the connection events' message.
func reachSigMessage(unix int64) string { return fmt.Sprintf("fleet-reach-stats %d", unix) }

var (
	reachLinkRE = regexp.MustCompile(`^[0-9a-f]{16}$`)
	reachRoutes = map[string]bool{reachRouteLocal: true, reachRouteDirect: true, reachRouteRelay: true, reachRouteUnknown: true}
)

// ReachStatsRequest is one batch: Cert / Sig / TS prove a connection
// certificate (Sig over reachSigMessage(TS)); a bearer the doors accept needs
// none of them.
type ReachStatsRequest struct {
	Cert string         `json:"cert,omitempty"`
	Sig  string         `json:"sig,omitempty"`
	TS   int64          `json:"ts,omitempty"`
	Rows []ReachRowWire `json:"rows"`
}

// ReachRowWire is one hour of one link and route class, as a client sends it.
type ReachRowWire struct {
	Hour     int64   `json:"hour"`
	Link     string  `json:"link"`
	Route    string  `json:"route"`
	Attempts int64   `json:"attempts"`
	OK       int64   `json:"ok"`
	Enter    []int64 `json:"enter"`
	WantMS   int64   `json:"want_ms"`
	UpMS     int64   `json:"up_ms"`
	Recover  []int64 `json:"recover"`
}

// ReachStatsAnswer is the POST's answer.
type ReachStatsAnswer struct {
	Accepted int `json:"accepted"`
	Refused  int `json:"refused"`
}

// reachSrc is the caller as a row keeps it: a hash, never the name.
func reachSrc(id sshRelayIdentity) string {
	sum := sha256.Sum256([]byte("fleet-reach-src\x00" + id.Principal + "\x00" + id.Actor))
	return hex.EncodeToString(sum[:8])
}

func reachHist(xs []int64, max int64) ([store.ReachBuckets]int64, int64, bool) {
	var out [store.ReachBuckets]int64
	if len(xs) == 0 {
		return out, 0, true
	}
	if len(xs) != store.ReachBuckets {
		return out, 0, false
	}
	var sum int64
	for i, v := range xs {
		if v < 0 || v > max {
			return out, 0, false
		}
		out[i] = v
		sum += v
	}
	return out, sum, sum <= max
}

// reachRow checks one row field by field; ok=false refuses it.
func reachRow(x ReachRowWire, src string, now time.Time) (store.ReachRow, bool) {
	cur := now.Unix() / 3600
	if x.Hour > cur || x.Hour < now.Add(-store.ReachKeep).Unix()/3600 {
		return store.ReachRow{}, false
	}
	if !reachRoutes[x.Route] || (x.Link != "" && !reachLinkRE.MatchString(x.Link)) || (x.Route == reachRouteLocal && x.Link != "") {
		return store.ReachRow{}, false
	}
	if x.Attempts < 0 || x.Attempts > reachCountMax || x.OK < 0 || x.OK > x.Attempts {
		return store.ReachRow{}, false
	}
	if x.WantMS < 0 || x.WantMS > reachHourMS || x.UpMS < 0 || x.UpMS > x.WantMS {
		return store.ReachRow{}, false
	}
	enter, n, ok := reachHist(x.Enter, reachCountMax)
	if !ok || n > x.OK {
		return store.ReachRow{}, false
	}
	recov, _, ok := reachHist(x.Recover, reachRecoveriesMax)
	if !ok {
		return store.ReachRow{}, false
	}
	return store.ReachRow{Hour: x.Hour, Src: src, Link: x.Link, Route: x.Route, Attempts: x.Attempts, OK: x.OK,
		Enter: enter, WantMS: x.WantMS, UpMS: x.UpMS, Recover: recov, At: now}, true
}

func (s *Server) handleReachStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		httpError(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	now := time.Now()
	var req ReachStatsRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, "a JSON body {rows} is required")
		return
	}
	id, ok := s.fleetReadIdentity(r)
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
		if id, err = s.verifySSHRelayCert(req.Cert, req.Sig, reachSigMessage(req.TS), reachSigNamespace, now); err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if len(req.Rows) > reachRowsMax {
		httpError(w, http.StatusRequestEntityTooLarge, "at most "+strconv.Itoa(reachRowsMax)+" rows a batch")
		return
	}
	src := reachSrc(id)
	var ans ReachStatsAnswer
	rows := make([]store.ReachRow, 0, len(req.Rows))
	seen := map[string]bool{}
	for _, x := range req.Rows {
		row, ok := reachRow(x, src, now)
		k := strconv.FormatInt(x.Hour, 10) + "\x00" + x.Link + "\x00" + x.Route
		if !ok || seen[k] {
			ans.Refused++
			continue
		}
		seen[k] = true
		rows = append(rows, row)
	}
	if err := s.Store.PutReachRows(rows); err != nil {
		httpError(w, http.StatusInternalServerError, "could not save the rows")
		return
	}
	ans.Accepted = len(rows)
	writeJSON(w, http.StatusOK, ans)
}

// ── the public fold ─────────────────────────────────────────────────────

// publicReachClass is one class's figures; a nil is a figure with fewer
// than reachMinN samples behind it (or none), shown as "—".
type publicReachClass struct {
	SessionReach     *float64 `json:"session_reach"`
	LinkAvailability *float64 `json:"link_availability"`
	EnterP50MS       *int64   `json:"enter_p50_ms"`
	EnterP95MS       *int64   `json:"enter_p95_ms"`
	RecoverP50MS     *int64   `json:"recover_p50_ms"`
	RecoverP95MS     *int64   `json:"recover_p95_ms"`
}

// publicReach is one window: every class together, then local (a session on
// the view's own machine), direct (tailnet / lan / entry) and relay
// (peer-relay / hub-relay). At is the newest hour folded in (ms).
type publicReach struct {
	All    publicReachClass `json:"all"`
	Local  publicReachClass `json:"local"`
	Direct publicReachClass `json:"direct"`
	Relay  publicReachClass `json:"relay"`
	At     int64            `json:"at"`
}

type reachAcc struct {
	attempts, ok int64
	enter, recov [store.ReachBuckets]int64
	want, up     int64
	linkHours    int64
}

func (a *reachAcc) add(r store.ReachRow) {
	a.attempts += r.Attempts
	a.ok += r.OK
	for i := range r.Enter {
		a.enter[i] += r.Enter[i]
		a.recov[i] += r.Recover[i]
	}
	if r.Link != "" && r.WantMS > 0 {
		a.want += r.WantMS
		a.up += r.UpMS
		a.linkHours++
	}
}

// reachPct is the histogram's upper bound at quantile q (the open bucket
// answers the last bound).
func reachPct(b [store.ReachBuckets]int64, q float64) (int64, int64) {
	var total int64
	for _, v := range b {
		total += v
	}
	if total == 0 {
		return 0, 0
	}
	want := int64(float64(total)*q + 0.5)
	if want < 1 {
		want = 1
	}
	var acc int64
	for i, v := range b {
		acc += v
		if acc >= want {
			if i < len(store.ReachBounds) {
				return store.ReachBounds[i], total
			}
			break
		}
	}
	return store.ReachBounds[len(store.ReachBounds)-1], total
}

func (a reachAcc) public() publicReachClass {
	var out publicReachClass
	if a.attempts >= reachMinN {
		v := float64(a.ok) / float64(a.attempts)
		out.SessionReach = &v
	}
	if a.linkHours >= reachMinN && a.want > 0 {
		v := float64(a.up) / float64(a.want)
		out.LinkAvailability = &v
	}
	if p50, n := reachPct(a.enter, 0.5); n >= reachMinN {
		p95, _ := reachPct(a.enter, 0.95)
		out.EnterP50MS, out.EnterP95MS = &p50, &p95
	}
	if p50, n := reachPct(a.recov, 0.5); n >= reachMinN {
		p95, _ := reachPct(a.recov, 0.95)
		out.RecoverP50MS, out.RecoverP95MS = &p50, &p95
	}
	return out
}

// publicReachOf folds the rows at or after since into the public window.
func publicReachOf(rows []store.ReachRow, since time.Time) publicReach {
	var all, local, direct, relay reachAcc
	out := publicReach{}
	h := since.Unix() / 3600
	for _, r := range rows {
		if r.Hour < h {
			continue
		}
		all.add(r)
		switch r.Route {
		case reachRouteLocal:
			local.add(r)
		case reachRouteDirect:
			direct.add(r)
		case reachRouteRelay:
			relay.add(r)
		}
		if r.Hour*reachHourMS > out.At {
			out.At = r.Hour * reachHourMS
		}
	}
	out.All, out.Local, out.Direct, out.Relay = all.public(), local.public(), direct.public(), relay.public()
	return out
}
