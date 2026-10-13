package api

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Spare alerts (claude-fleet#3509, EPIC #3500 R3). A place that keeps spares
// — a machine or a cluster — stops refilling the moment one spare fails, and
// nothing said so: the operator found out by reading fleet hub accounts. So
// the alert sweep (RunNodeAlerts, one replica) looks at every place's spares
// and tells the operator through the hub's alert channel (fleet_alerts, plus
// one hub_audit spare.alert line per alert):
//
//   - spare_empty: a place that should hold spares (its target > 0) has had
//     none ready for spareEmptyAfter (30 minutes). Cleared once one is ready
//     (or none is wanted, or the place stops keeping spares). The clock starts
//     when this hub first saw it empty — a restart starts it again.
//   - spare_failed: a spare there failed to be made, or a person's login
//     failed its wash (a reset that came back dirty / not separated) — the
//     login is never handed out and the place gets no more spares until the
//     operator forgets it. Raised at once; cleared when none is left.
//
// Each (kind, place) is raised at most once per spareAlertQuiet (24 hours),
// whether or not the last one was cleared in between. Spares off ⇒ nothing is
// read and nothing raised; an open alert is left for the prune.

const (
	spareEmptyAfter = 30 * time.Minute
	spareAlertQuiet = 24 * time.Hour
)

// spareAlertEvery is how often the sweep looks at the spares. A variable so
// tests can move it.
var spareAlertEvery = time.Minute

// spareFailedRow is one failed login the spare_failed detail names.
type spareFailedRow struct {
	Login  string `json:"login"`
	Op     string `json:"op"`
	Detail string `json:"detail,omitempty"`
}

// sparePlace is one place's spares as the sweep reads them.
type sparePlace struct {
	host    string
	cluster bool
	keeps   bool // it is a place that keeps spares right now
	ready   int
	target  int
	failed  []spareFailedRow
}

// SpareAlertTick is one pass at now; since is when this hub started watching.
func (s *Server) SpareAlertTick(since, now time.Time) {
	if !s.Fleet || s.Store == nil || !s.sparesOn() {
		return
	}
	s.spareAlertMu.Lock()
	defer s.spareAlertMu.Unlock()
	if !s.spareAlertAt.IsZero() && now.Sub(s.spareAlertAt) < spareAlertEvery {
		return
	}
	s.spareAlertAt = now
	places, err := s.sparePlaces(now)
	if err != nil {
		log.Printf("fleet alerts: spares: %v", err)
		return
	}
	if s.spareEmptySince == nil {
		s.spareEmptySince = map[string]time.Time{}
	}
	seen := map[string]bool{}
	for _, p := range places {
		k := strings.ToLower(p.host)
		seen[k] = true
		if p.keeps && p.target > 0 && p.ready == 0 {
			from, ok := s.spareEmptySince[k]
			if !ok {
				from = now
				if from.Before(since) {
					from = since
				}
				s.spareEmptySince[k] = from
			}
			if now.Sub(from) >= spareEmptyAfter {
				s.raiseSpareAlert(store.AlertSpareEmpty, p, map[string]any{
					"hostname": p.host, "cluster": p.cluster, "ready": 0, "target": p.target,
					"empty_since": from.UTC(), "after_secs": int(spareEmptyAfter / time.Second),
				}, fmt.Sprintf("%s: 0 ready of %d for %s", p.host, p.target, now.Sub(from).Round(time.Minute)), now)
			}
		} else {
			delete(s.spareEmptySince, k)
			s.clearSpareAlert(store.AlertSpareEmpty, p.host, now)
		}
		if len(p.failed) > 0 {
			names := make([]string, 0, len(p.failed))
			for _, f := range p.failed {
				names = append(names, f.Login+" ("+f.Op+": "+truncate(f.Detail, 120)+")")
			}
			s.raiseSpareAlert(store.AlertSpareFailed, p, map[string]any{
				"hostname": p.host, "cluster": p.cluster, "failed": p.failed,
			}, fmt.Sprintf("%s: %d failed, left for the operator (fleet hub accounts) — %s", p.host, len(p.failed), strings.Join(names, "; ")), now)
		} else {
			s.clearSpareAlert(store.AlertSpareFailed, p.host, now)
		}
	}
	for k := range s.spareEmptySince {
		if !seen[k] {
			delete(s.spareEmptySince, k)
		}
	}
	// A place no longer read at all (off the roster, its accounts gone).
	for _, kind := range []string{store.AlertSpareEmpty, store.AlertSpareFailed} {
		open, err := s.Store.OpenFleetAlertSubjects(kind, "")
		if err != nil {
			continue
		}
		for _, sub := range open {
			if !seen[strings.ToLower(sub)] {
				s.clearSpareAlert(kind, sub, now)
			}
		}
	}
}

// raiseSpareAlert opens (kind, p.host) unless it is open or was raised within
// spareAlertQuiet; a new one leaves one hub_audit spare.alert line.
func (s *Server) raiseSpareAlert(kind string, p sparePlace, detail map[string]any, line string, now time.Time) {
	last, err := s.Store.LastFleetAlertRaised(kind, p.host)
	if err != nil {
		log.Printf("fleet alerts: read %s %s: %v", kind, p.host, err)
		return
	}
	if !last.IsZero() && now.Sub(last) < spareAlertQuiet {
		return
	}
	b, _ := json.Marshal(detail)
	raised, err := s.Store.RaiseFleetAlert(kind, p.host, string(b), now)
	if err != nil {
		log.Printf("fleet alerts: raise %s %s: %v", kind, p.host, err)
		return
	}
	if !raised {
		return
	}
	log.Printf("fleet alert: %s %s", kind, line)
	outcome := strings.TrimPrefix(kind, "spare_")
	if err := s.Store.HubAudit("hub", "spare.alert", p.host, outcome, line, now); err != nil {
		log.Printf("fleet alerts: audit %s %s: %v", kind, p.host, err)
	}
}

func (s *Server) clearSpareAlert(kind, host string, now time.Time) {
	if cleared, err := s.Store.ClearFleetAlert(kind, host, now); err != nil {
		log.Printf("fleet alerts: clear %s %s: %v", kind, host, err)
	} else if cleared {
		log.Printf("fleet alert cleared: %s %s", kind, host)
	}
}

// sparePlaces is every machine and cluster with spares to look at: the
// machines that keep spares (spareMachines, without the load gate — a busy
// machine that holds none for half an hour is still worth a word), every
// machine holding a spare row, and every cluster whose ops link is up.
func (s *Server) sparePlaces(now time.Time) ([]sparePlace, error) {
	keeps := s.spareMachines(now, false)
	pic, err := s.sparePicture(keeps...)
	if err != nil {
		return nil, err
	}
	kept := map[string]bool{}
	for _, h := range keeps {
		kept[strings.ToLower(h)] = true
	}
	var out []sparePlace
	names := map[string]string{}
	all, err := s.Store.FleetAccounts("")
	if err != nil {
		return nil, err
	}
	failed := map[string][]spareFailedRow{}
	for _, a := range all {
		if isUserPodName(a.Hostname) {
			continue // a pod's row is its cluster's, read below
		}
		k := strings.ToLower(a.Hostname)
		if names[k] == "" {
			names[k] = a.Hostname
		}
		if washFailed(a) {
			failed[k] = append(failed[k], spareFailedRow{Login: a.Login, Op: a.Op, Detail: a.Detail})
		}
	}
	for _, h := range keeps {
		names[strings.ToLower(h)] = h
	}
	for k, m := range pic {
		if isUserPodName(k) || s.isCluster(k) {
			continue
		}
		host := names[k]
		if host == "" {
			host = k
		}
		if !kept[k] && len(failed[k]) == 0 {
			continue
		}
		out = append(out, sparePlace{host: host, keeps: kept[k], ready: m.Ready, target: m.Target, failed: failed[k]})
	}
	if s.clusterPoolOn() {
		settings, err := s.Store.FleetSettings()
		if err != nil {
			return nil, err
		}
		for _, cluster := range s.clusters() {
			_, c := s.nodes.opsFor(cluster)
			cp, err := s.clusterPicture(cluster)
			if err != nil {
				log.Printf("fleet alerts: spare pods of %s: %v", cluster, err)
				continue
			}
			p := sparePlace{host: cluster, cluster: true, keeps: c != nil, ready: len(cp.ready),
				target: s.clusterSpareTarget(cluster, settings, cp.used)}
			for _, pod := range cp.all {
				if a := cp.acct[pod.Pod]; a != nil && store.IsSparePrincipal(pod.PrincipalID) && a.State == store.AccountFailed {
					p.failed = append(p.failed, spareFailedRow{Login: a.Login + "@" + pod.Pod, Op: a.Op, Detail: a.Detail})
				}
			}
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].host < out[j].host })
	return out, nil
}

// washFailed says a machine's row is a login the operator must look at
// before that machine refills: a spare that failed (its create, or not
// credential-separated), or a person's login whose wash failed (a reset that
// came back dirty / not separated / never answered).
func washFailed(a store.FleetAccount) bool {
	if !a.Managed() || a.State != store.AccountFailed {
		return false
	}
	return store.IsSparePrincipal(a.PrincipalID) || a.Op == control.AccountReset
}
