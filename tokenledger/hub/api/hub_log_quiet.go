package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The hub's log must not repeat itself (T906). Three lines once filled it —
// a node's fleet that did not derive (every 5 s, ~17 000 a day), refused
// requests nobody could trace back, a pool credential's quota read refused
// every round — and none of them told anyone what to do. Each now says it at
// most once per logQuietWindow per signature, and the two that are faults
// raise a fleet alert (fleet_underived, pool_relogin) that says who fixes it.

// logQuietWindow is how long one signature stays quiet after it was logged.
const logQuietWindow = time.Hour

// logQuietMax bounds the signatures remembered: past it the stale ones go,
// and if every one is fresh the memory starts over (a line or two repeats).
const logQuietMax = 4096

// logQuiet remembers when each signature was last logged. The zero value is
// ready to use.
type logQuiet struct {
	mu   sync.Mutex
	seen map[string]*quietEntry
}

type quietEntry struct {
	at      time.Time
	dropped int
}

// allow reports whether key may be logged at now, and how many lines of it
// were held back since it last was.
func (q *logQuiet) allow(key string, now time.Time) (bool, int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.seen == nil {
		q.seen = map[string]*quietEntry{}
	}
	if e, ok := q.seen[key]; ok {
		if now.Sub(e.at) < logQuietWindow {
			e.dropped++
			return false, 0
		}
		n := e.dropped
		e.at, e.dropped = now, 0
		return true, n
	}
	if len(q.seen) >= logQuietMax {
		for k, e := range q.seen {
			if now.Sub(e.at) >= logQuietWindow {
				delete(q.seen, k)
			}
		}
		if len(q.seen) >= logQuietMax {
			q.seen = map[string]*quietEntry{}
		}
	}
	q.seen[key] = &quietEntry{at: now}
	return true, 0
}

// heldBack is the suffix a line carries for the copies it stood for.
func heldBack(n int) string {
	if n == 0 {
		return ""
	}
	return fmt.Sprintf(" (+%d more in the last %s)", n, logQuietWindow)
}

// --- a fleet that does not derive ------------------------------------------------

// underivedDetail is fleet_underived's detail.
type underivedDetail struct {
	EndpointID string `json:"endpoint_id"`
	Hostname   string `json:"hostname"`
	OSUser     string `json:"os_user"`
	MachineID  string `json:"machine_id"`
	FleetID    string `json:"fleet_id"`
	Fleet      string `json:"fleet"`
	Repo       string `json:"repo,omitempty"`
	Checkout   string `json:"checkout,omitempty"`
}

// fleetUnderived is one fleet of ep's beat whose UUID does not derive from
// its machine: logged and raised once a window per (endpoint, fleet).
func (s *Server) fleetUnderived(ep store.Endpoint, host, user, machine string, f control.Fleet, at time.Time) {
	subject := ep.ID + "/" + f.FleetID
	ok, n := s.logQuiet.allow("underived/"+subject, at)
	if !ok {
		return
	}
	log.Printf("node %s (%s@%s): fleet %s (%s) does not derive from machine %s; skipped — its sessions are not on the hub's list%s",
		ep.ID, user, nodeLabel(host), f.FleetID, f.Name, machine, heldBack(n))
	if s.Store == nil {
		return
	}
	b, _ := json.Marshal(underivedDetail{EndpointID: ep.ID, Hostname: host, OSUser: user, MachineID: machine,
		FleetID: f.FleetID, Fleet: f.Name, Repo: f.Repo, Checkout: f.Checkout})
	if raised, err := s.Store.RaiseFleetAlert(store.AlertFleetUnderived, subject, string(b), at); err != nil {
		log.Printf("fleet alerts: raise fleet_underived %s: %v", subject, err)
	} else if raised {
		log.Printf("fleet alert: fleet_underived %s — fleet %s on %s@%s is off the hub's list", subject, f.Name, user, nodeLabel(host))
	}
}

// settleUnderived clears ep's fleet_underived alerts its verified beat no
// longer shows (bad holds the subjects it still does). It reads the store
// only on a connection's first beat or while this replica raised one for ep,
// not on every beat of every node.
func (s *Server) settleUnderived(ep store.Endpoint, bad map[string]bool, reconnect bool, at time.Time) {
	if s.Store == nil {
		return
	}
	s.underivedMu.Lock()
	if s.underivedEPs == nil {
		s.underivedEPs = map[string]bool{}
	}
	had := s.underivedEPs[ep.ID]
	if len(bad) > 0 {
		s.underivedEPs[ep.ID] = true
	} else {
		delete(s.underivedEPs, ep.ID)
	}
	s.underivedMu.Unlock()
	if !had && !reconnect {
		return
	}
	open, err := s.Store.OpenFleetAlertSubjects(store.AlertFleetUnderived, ep.ID+"/")
	if err != nil {
		log.Printf("fleet alerts: read fleet_underived %s: %v", ep.ID, err)
		return
	}
	for _, subject := range open {
		if bad[subject] {
			continue
		}
		if cleared, err := s.Store.ClearFleetAlert(store.AlertFleetUnderived, subject, at); err == nil && cleared {
			log.Printf("fleet alert cleared: fleet_underived %s", subject)
		}
	}
}

// --- refused requests -----------------------------------------------------------

// rejectedLine is the access-log line of a 401 / 403 — who it came from, so a
// client knocking with a dead token can be found — or "" while that source's
// signature is quiet. from is the client's address; tok the first 8 hex of
// the presented bearer's hash (never the token); ep the endpoint that holds or
// once held it.
func (s *Server) rejectedLine(r *http.Request, path string, status int, took time.Duration, now time.Time) string {
	from := "?"
	if a := chatClientIP(r); a.IsValid() {
		from = a.String()
	}
	tok, hash := "", ""
	if b := bearer(r); b != "" {
		hash = HashToken(b)
		tok = hash[:8]
	}
	ok, n := s.logQuiet.allow(fmt.Sprintf("rejected/%s %s %d/%s/%s", r.Method, path, status, from, tok), now)
	if !ok {
		return ""
	}
	line := fmt.Sprintf("%s %s %d %s from=%s", r.Method, path, status, took, from)
	if tok != "" {
		line += " tok=" + tok
		if s.Store != nil {
			if ep, err := s.Store.EndpointEverHeldToken(hash); err == nil && ep != nil {
				line += fmt.Sprintf(" ep=%s(%s@%s", ep.ID, ep.OSUser, nodeLabel(ep.Hostname))
				if ep.RetiredAt != nil {
					line += ", retired"
				}
				line += ")"
			}
		}
	}
	if ua := r.UserAgent(); ua != "" {
		if len(ua) > 60 {
			ua = ua[:60]
		}
		line += fmt.Sprintf(" ua=%q", ua)
	}
	return line + heldBack(n)
}

// --- a pool credential whose login went bad ---------------------------------------

// poolReloginAfter is how many refused reads in a row raise pool_relogin.
const poolReloginAfter = 3

// poolReloginDetail is pool_relogin's detail.
type poolReloginDetail struct {
	Provider string `json:"provider"`
	Account  string `json:"account"`
	Owner    string `json:"owner"`
	Error    string `json:"error"`
	Streak   int    `json:"streak"`
}

// authRefused says a read failed because the upstream refused the login.
func authRefused(e string) bool {
	return strings.Contains(e, "HTTP 401") || strings.Contains(e, "HTTP 403")
}

// streak records r's outcome against its credential and returns the failures
// in a row it now stands at (0 on success), and the count before it (-1 when
// this is the first read since the hub started).
func (h *HubQuota) streak(r HubQuotaRead) (now, before int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.fails == nil {
		h.fails = map[string]int{}
	}
	prev, seen := h.fails[r.CredentialID]
	if !seen {
		prev = -1
	}
	if r.OK {
		h.fails[r.CredentialID] = 0
		return 0, prev
	}
	n := max(prev, 0) + 1
	h.fails[r.CredentialID] = n
	return n, prev
}

// poolReloginSubject names a credential: "<provider>/<account>", the owner in
// front when it is a person's rather than the pool's.
func poolReloginSubject(r HubQuotaRead) string {
	subject := r.Provider + "/" + r.Account
	if r.Owner != "" && r.Owner != store.PoolPrincipal {
		subject = r.Owner + ":" + subject
	}
	return subject
}

// hubQuotaOutcome logs a failed read once a window per (credential, error)
// and raises / clears pool_relogin.
func (s *Server) hubQuotaOutcome(r HubQuotaRead, at time.Time) {
	n, before := s.HubQuota.streak(r)
	subject := poolReloginSubject(r)
	if r.OK {
		if before != 0 && s.Store != nil {
			if cleared, err := s.Store.ClearFleetAlert(store.AlertPoolRelogin, subject, at); err == nil && cleared {
				log.Printf("fleet alert cleared: pool_relogin %s", subject)
			}
		}
		return
	}
	if ok, held := s.logQuiet.allow("hubquota/"+r.CredentialID+"/"+r.Error, at); ok {
		log.Printf("hub quota: %s/%s: %s (%d in a row)%s", r.Provider, r.Account, r.Error, n, heldBack(held))
	}
	if n < poolReloginAfter || !authRefused(r.Error) || s.Store == nil {
		return
	}
	b, _ := json.Marshal(poolReloginDetail{Provider: r.Provider, Account: r.Account, Owner: r.Owner, Error: r.Error, Streak: n})
	if raised, err := s.Store.RaiseFleetAlert(store.AlertPoolRelogin, subject, string(b), at); err != nil {
		log.Printf("fleet alerts: raise pool_relogin %s: %v", subject, err)
	} else if raised {
		log.Printf("fleet alert: pool_relogin %s — %d quota reads refused in a row; re-log it in on the pool page", subject, n)
	}
}

// alertLine is the one line fleet_underived / pool_relogin says to the
// notifier: what is wrong and who does what, zh then en.
func alertLine(a store.FleetAlert) string {
	switch a.Kind {
	case store.AlertFleetUnderived:
		var d underivedDetail
		if json.Unmarshal([]byte(a.Detail), &d) != nil {
			return ""
		}
		where := d.OSUser + "@" + nodeLabel(d.Hostname)
		return fmt.Sprintf("%s 的 fleet「%s」编号 %s 与本机编号 %s 对不上，它的会话不在 hub 名单里。"+
			"那台机器的主人在该登录上删掉 ~/.config/claude-fleet/fleets/%s/identity（下一拍按本机编号重算）；这台不该承载就 fleet host off。"+
			" · fleet %q on %s reports %s, which does not derive from its machine %s, so its sessions are off the hub's list. "+
			"Its owner deletes ~/.config/claude-fleet/fleets/%s/identity on that login (re-minted on the next beat), or runs fleet host off if it should not host.",
			where, d.Fleet, short8(d.FleetID), short8(d.MachineID), d.Fleet,
			d.Fleet, where, short8(d.FleetID), short8(d.MachineID), d.Fleet)
	case store.AlertPoolRelogin:
		var d poolReloginDetail
		if json.Unmarshal([]byte(a.Detail), &d) != nil {
			return ""
		}
		return fmt.Sprintf("订阅 %s/%s 读额度连续 %d 次被拒（%s）：登录已失效，管理员到池页面重新登录这份订阅。"+
			" · %s/%s refused %d quota reads in a row (%s): its login has gone bad — an admin re-logs it in on the pool page.",
			d.Provider, d.Account, d.Streak, d.Error, d.Provider, d.Account, d.Streak, d.Error)
	}
	return ""
}

func short8(id string) string {
	if len(id) > 8 {
		return id[:8] + "…"
	}
	return id
}
