package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/release"
)

// A release goes to ONE machine first (claude-fleet#4915, EPIC #4810 S3).
//
// Until now every machine switched on its own and rolled back only itself
// (`.prev`) — a version whose doctor FAILs everywhere still reached everywhere.
// With the setting fleet.release_canary naming a machine, a new stable is
// handed to that machine alone first:
//
//   - every follower's stable — /version `stable`, /v1/fleet/release/stable,
//     the TypeRelease push — stays the previous release for everyone but the
//     canary (a follower says which machine it is: /version?machine=<host>,
//     fleet-node-update.py), for at most releaseCanaryWait (2 minutes);
//   - the canary's machine beat decides: its runtime on the sha and its
//     updater `committed` (switched, doctor PASS) ⇒ released to all at once;
//     its updater `rolled-back` from the sha (a new doctor FAIL) ⇒ blocked: the
//     sha is never handed to anyone, the person told, and release-watch.yml
//     rolls the version back; no word in 2 minutes ⇒ released (a quiet canary
//     never stops a release);
//   - a canary offline or 维护中 at the promote ⇒ released at once, saying so.
//
// The hold is a record in the shared settings table (fleet.release_hold), so
// both replicas hand out the same stable; each replica's gate tick
// (releaseGateEvery) judges it and pushes its own links what they should
// hear. The record's clock is the pointer file's own time, so two replicas
// writing it write the same thing.
//
// GET /v1/fleet/release/health?sha=<40 hex>&since=<unix> — the post-release
// watch's one read (bin/fleet-release-watch.py, the release CI's OIDC): the
// hold, the machines that rolled the sha back, the ones on it, and this
// replica's requests / 5xx since `since`.
//
// No fleet.release_canary ⇒ no record, no hold, no tick work: every stable is
// handed to everyone as before, byte for byte (TestReleaseCanaryOffAddsNothing).

const (
	ReleaseCanaryKey  = "fleet.release_canary"
	releaseHoldKey    = "fleet.release_hold"
	releaseHealthRest = "health"

	holdCanary   = "canary"
	holdReleased = "released"
	holdBlocked  = "blocked"
)

// Variables so tests can move them.
var (
	releaseCanaryWait = 2 * time.Minute
	releaseGateEvery  = 5 * time.Second
)

// releaseWatchWorkflows may read the health route: the post-release watch.
var releaseWatchWorkflows = []string{"release-watch.yml"}

// releaseHold is the record of one stable's way out.
type releaseHold struct {
	SHA     string    `json:"sha"`
	Seq     int64     `json:"seq"`
	Prev    string    `json:"prev"`
	PrevSeq int64     `json:"prev_seq"`
	Canary  string    `json:"canary"`
	State   string    `json:"state"` // canary | released | blocked
	Reason  string    `json:"reason,omitempty"`
	Since   time.Time `json:"since"`
	At      time.Time `json:"at"`
}

func (h releaseHold) prev() stablePointer { return stablePointer{SHA: h.Prev, Seq: h.PrevSeq} }

func parseHold(v string) (releaseHold, bool) {
	var h releaseHold
	if v == "" || json.Unmarshal([]byte(v), &h) != nil || !release.ValidSHA(h.SHA) {
		return releaseHold{}, false
	}
	return h, true
}

// stableSince is when the stable pointer last moved (its file's time).
func (rs *ReleaseStore) stableSince() time.Time {
	st, err := os.Stat(filepath.Join(rs.Dir, releaseStable))
	if err != nil {
		return time.Time{}
	}
	return st.ModTime()
}

// gateView is what followers are handed right now: the stable pointer, and —
// while one is held — the release everyone but the canary keeps.
type gateView struct {
	p       stablePointer
	held    stablePointer // zero = nothing held
	canary  string        // "" = everyone is held (blocked)
	holding bool
}

// forMachine is the stable handed to a follower on machine ("" = unknown).
func (v gateView) forMachine(machine string) stablePointer {
	if !v.holding {
		return v.p
	}
	if v.canary != "" && machine != "" && sameMachine(machine, v.canary) {
		return v.p
	}
	return v.held
}

// releaseGate reads the gate once: the pointer, the setting and the record.
func (s *Server) releaseGate(now time.Time) gateView {
	rs := s.Releases
	if rs == nil {
		return gateView{}
	}
	v := gateView{p: rs.stable()}
	if v.p.SHA == "" || s.Store == nil {
		return v
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return v
	}
	canary := strings.TrimSpace(settings[ReleaseCanaryKey])
	if canary == "" {
		return v
	}
	if h, ok := parseHold(settings[releaseHoldKey]); ok && h.SHA == v.p.SHA {
		switch {
		case h.State == holdBlocked && release.ValidSHA(h.Prev):
			v.holding, v.held = true, h.prev()
		case h.State == holdCanary && release.ValidSHA(h.Prev) && now.Sub(h.Since) < releaseCanaryWait:
			v.holding, v.held, v.canary = true, h.prev(), h.Canary
		}
		return v
	}
	// a pointer the gate has not judged yet: held while fresh, so the seconds
	// before the first tick hand nothing out
	if since := rs.stableSince(); !since.IsZero() && now.Sub(since) < releaseCanaryWait {
		if m := rs.manifest(v.p.SHA); m != nil && release.ValidSHA(m.Prev) && v.p.Seq > 1 {
			v.holding, v.held, v.canary = true, stablePointer{SHA: m.Prev, Seq: v.p.Seq - 1}, canary
		}
	}
	return v
}

// followerStable is the stable sha a follower request is handed: /version
// and /v1/fleet/release/stable. machine is its ?machine= ("" = not said).
func (s *Server) followerStable(machine string) (string, bool) {
	v := s.releaseGate(time.Now())
	if !v.holding {
		return "", false
	}
	return v.forMachine(machine).SHA, true
}

// RunReleaseGate judges the hold every releaseGateEvery until ctx ends.
func (s *Server) RunReleaseGate(ctx context.Context) {
	t := time.NewTicker(releaseGateEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.releaseGateTick(time.Now())
		}
	}
}

// releaseGateTick opens a record for a new stable, judges the canary, and
// pushes this replica's links what they should hear.
func (s *Server) releaseGateTick(now time.Time) {
	rs := s.Releases
	if rs == nil || s.Store == nil {
		return
	}
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return
	}
	canary := strings.TrimSpace(settings[ReleaseCanaryKey])
	if canary == "" {
		return
	}
	p := rs.stable()
	if p.SHA == "" {
		return
	}
	h, ok := parseHold(settings[releaseHoldKey])
	if !ok || h.SHA != p.SHA {
		since := rs.stableSince()
		if since.IsZero() || now.Sub(since) >= releaseCanaryWait {
			return // a stable from before the setting: not held
		}
		h = releaseHold{SHA: p.SHA, Seq: p.Seq, PrevSeq: p.Seq - 1, Canary: canary, State: holdCanary, Since: since.UTC(), At: now.UTC()}
		if m := rs.manifest(p.SHA); m != nil && release.ValidSHA(m.Prev) && p.Seq > 1 {
			h.Prev = m.Prev
		}
		switch {
		case h.Prev == "":
			h.State, h.Reason = holdReleased, "no previous release to hold"
		case !s.canaryAvailable(canary, now):
			h.State, h.Reason = holdReleased, "金丝雀 "+canary+" 不在线或维护中"
		}
		s.holdWrite(h, now)
		if h.State == holdCanary {
			s.notify("发布 " + short(p.SHA) + "：先给金丝雀 " + canary + "，体检通过再给其余")
		} else {
			s.notify("发布 " + short(p.SHA) + "：" + h.Reason + "，直接给全部")
		}
	}
	if h.State == holdCanary {
		state, why := s.canaryVerdict(h, now)
		if state != "" {
			h.State, h.Reason, h.At = state, why, now.UTC()
			s.holdWrite(h, now)
			switch state {
			case holdReleased:
				s.notify("发布 " + short(h.SHA) + "：" + why + "，发给其余机器")
			case holdBlocked:
				s.notify("发布 " + short(h.SHA) + " 被金丝雀拦住：" + why + "——其余机器不换，这一版不发（release-watch 会回退）")
			}
		}
	}
	s.pushGated(now)
}

// canaryAvailable: the canary is heard — any of its rows, its machine link
// too (a machine's own status is its logins') — and not 维护中.
func (s *Server) canaryAvailable(canary string, now time.Time) bool {
	snap, err := s.Nodes(now)
	if err != nil {
		return false
	}
	for _, m := range snap.Machines {
		if sameMachine(m.Hostname, canary) && m.Maintenance != nil {
			return false
		}
	}
	for _, v := range snap.Nodes {
		if sameMachine(v.Hostname, canary) && v.Status == "online" {
			return true
		}
	}
	return false
}

// canaryVerdict reads the canary's machine beat: released | blocked | "" (wait).
func (s *Server) canaryVerdict(h releaseHold, now time.Time) (string, string) {
	if snap, err := s.Nodes(now); err == nil {
		for _, m := range snap.Machines {
			if !sameMachine(m.Hostname, h.Canary) || m.Versions == nil {
				continue
			}
			u := m.Versions.Update
			switch {
			case u != nil && rolledBackFrom(u, h.SHA):
				return holdBlocked, "金丝雀 " + h.Canary + " 体检后回滚：" + runLine(u.Reason, 160)
			case m.Versions.Runtime == h.SHA && u != nil && (u.Result == "committed" || u.Result == "current"):
				return holdReleased, "金丝雀 " + h.Canary + " 已换版、体检通过"
			}
		}
	}
	if now.Sub(h.Since) >= releaseCanaryWait {
		return holdReleased, "金丝雀 " + h.Canary + " 2 分钟没回话"
	}
	return "", ""
}

// rolledBackFrom: the updater's last word is that it took sha back (or skips
// it for having done so).
func rolledBackFrom(u *control.UpdateState, sha string) bool {
	if u == nil || len(sha) < 12 {
		return false
	}
	return (u.Result == "rolled-back" || u.Result == "skipped") && strings.Contains(u.Reason, sha[:12])
}

func (s *Server) holdWrite(h releaseHold, now time.Time) {
	b, _ := json.Marshal(h)
	if err := s.Store.SetFleetSetting(releaseHoldKey, string(b), now); err != nil {
		log.Printf("fleet: release %s: hold: %v", short(h.SHA), err)
		return
	}
	if err := s.Store.HubAudit("hub", "release.canary", short(h.SHA), h.State, h.Canary+" "+h.Reason, now); err != nil {
		log.Printf("fleet: release %s: audit: %v", short(h.SHA), err)
	}
	log.Printf("fleet: release %s: %s (%s) %s", short(h.SHA), h.State, h.Canary, h.Reason)
}

// pushGated tells each of this replica's release links the stable it is
// handed — the canary the new one, the rest theirs.
func (s *Server) pushGated(now time.Time) {
	v := s.releaseGate(now)
	if v.p.SHA == "" {
		return
	}
	s.nodes.each(func(id string, c *nodeConn) {
		if c.canRelease {
			go s.pushRelease(id, c, v.forMachine(c.hostname()))
		}
	})
}

// --- the post-release watch's read --------------------------------------------

// handleReleaseHealth serves GET /v1/fleet/release/health.
func (s *Server) handleReleaseHealth(w http.ResponseWriter, r *http.Request) {
	rs := s.Releases
	if rs == nil || rs.Publish == nil {
		http.NotFound(w, r)
		return
	}
	if _, err := rs.Publish.CheckFor(r.Context(), r, rs.Repo, releaseWatchWorkflows); err != nil {
		httpError(w, http.StatusUnauthorized, err.Error())
		return
	}
	sha := r.URL.Query().Get("sha")
	if !release.ValidSHA(sha) {
		httpError(w, http.StatusBadRequest, "sha: want 40 hex")
		return
	}
	now := time.Now()
	since := now.Add(-15 * time.Minute)
	if n, err := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64); err == nil && n > 0 {
		since = time.Unix(n, 0)
	}
	writeJSON(w, http.StatusOK, s.releaseHealth(sha, since, now))
}

type machineWord struct {
	Machine string `json:"machine"`
	Reason  string `json:"reason,omitempty"`
}

func (s *Server) releaseHealth(sha string, since, now time.Time) map[string]any {
	out := map[string]any{"sha": sha, "stable": "", "hold": nil, "rolled_back": []machineWord{}, "reached": []string{}}
	if s.Releases != nil {
		out["stable"] = s.Releases.StableSHA()
	}
	if s.Store != nil {
		if settings, err := s.Store.FleetSettings(); err == nil {
			if h, ok := parseHold(settings[releaseHoldKey]); ok {
				out["hold"] = h
			}
		}
	}
	rolled, reached := []machineWord{}, []string{}
	if snap, err := s.Nodes(now); err == nil {
		for _, m := range snap.Machines {
			if m.Versions == nil {
				continue
			}
			if rolledBackFrom(m.Versions.Update, sha) {
				rolled = append(rolled, machineWord{Machine: m.Hostname, Reason: runLine(m.Versions.Update.Reason, 160)})
			} else if m.Versions.Runtime == sha {
				reached = append(reached, m.Hostname)
			}
		}
	}
	out["rolled_back"], out["reached"] = rolled, reached
	total, errs := s.httpStats.since(since)
	host, _ := os.Hostname()
	out["http"] = map[string]any{"replica": host, "since": since.UTC(), "total": total, "errors_5xx": errs}
	return out
}

// --- this replica's requests and 5xx, per minute ------------------------------

// httpStatsMinutes is how far back the counter remembers.
const httpStatsMinutes = 60

type httpStats struct {
	mu    sync.Mutex
	min   [httpStatsMinutes]int64 // unix minute of the bucket
	total [httpStatsMinutes]int64
	errs  [httpStatsMinutes]int64
}

func (h *httpStats) add(status int, at time.Time) {
	m := at.Unix() / 60
	i := m % httpStatsMinutes
	h.mu.Lock()
	if h.min[i] > m {
		h.mu.Unlock() // an older minute than the bucket holds: long gone
		return
	}
	if h.min[i] != m {
		h.min[i], h.total[i], h.errs[i] = m, 0, 0
	}
	h.total[i]++
	if status >= 500 {
		h.errs[i]++
	}
	h.mu.Unlock()
}

// since sums the buckets from since's minute on (at most the last hour).
func (h *httpStats) since(since time.Time) (total, errs int64) {
	from := since.Unix() / 60
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now().Unix() / 60
	for i := range h.min {
		if h.min[i] >= from && h.min[i] > now-httpStatsMinutes {
			total += h.total[i]
			errs += h.errs[i]
		}
	}
	return total, errs
}
