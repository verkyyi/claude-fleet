package api

import (
	"context"
	"log"
	"net/netip"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The hub keeps a live door's reach fresh by itself (claude-fleet#4149).
//
// A home's node program reports `entry reach` every 5 minutes; the door has
// none, and only a door image that carries #4116's loop reports again after
// its start — the door runs its image's runtime, so an older image reported
// once and its rows went stale EntryReachFresh later: a person's pod lost its
// door route though the door was up. What the door does on every pass, on any
// version, is pull its table (GET /v1/node/entry-routes). So on that pull, when
// its last check is older than doorReachEvery, the hub dials the addresses the
// door last reported and holds each to the door's last host key — the same
// test a report gets, never a new address: an address only counts while an
// sshd showing the door's key answers there. A door that stops pulling is
// re-checked by no one and its rows lapse as before.

// doorReachEvery is how old a door's last check may be before its pull
// re-checks it (a var for tests).
var doorReachEvery = 5 * time.Minute

// doorReachAsync runs the re-check off the request (tests run it inline).
var doorReachAsync = true

// doorReachKeep re-checks the door host's reach when it is due.
func (s *Server) doorReachKeep(host string, now time.Time) {
	key := strings.ToLower(host)
	if last, ok := s.entryReachAt.Load(key); ok && now.Sub(last.(time.Time)) < doorReachEvery {
		return
	}
	rows, err := s.entryReachRows(host)
	if err != nil || len(rows) == 0 {
		return // nothing reported yet: the door's own first report does it
	}
	newest := rows[0].CheckedAt
	for _, r := range rows {
		if r.CheckedAt.After(newest) {
			newest = r.CheckedAt
		}
	}
	if now.Sub(newest) < doorReachEvery {
		return
	}
	line, err := s.Store.EntryHostKey(host)
	if err != nil || line == "" {
		return // no key to hold an address to: never count one blind
	}
	want, _, _, _, err := ssh.ParseAuthorizedKey([]byte(line))
	if err != nil {
		return
	}
	s.entryReachAt.Store(key, now)
	run := func() { s.doorReachRecheck(host, rows, want, now) }
	if doorReachAsync {
		go run()
		return
	}
	run()
}

// doorReachRecheck dials each of rows' addresses again and writes the result.
func (s *Server) doorReachRecheck(host string, rows []store.EntryReach, want ssh.PublicKey, now time.Time) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*entryProbeTimeout)
	defer cancel()
	out := make([]store.EntryReach, len(rows))
	var wg sync.WaitGroup
	for i, r := range rows {
		wg.Add(1)
		go func(i int, r store.EntryReach) {
			defer wg.Done()
			why := ""
			if r.Port <= 0 || r.Port > 65535 || !entryDialableString(r.Addr) {
				why = r.Reason
				if why == "" {
					why = "not dialable"
				}
			} else {
				why = entryProbe(ctx, r.Addr, r.Port, want)
			}
			out[i] = store.EntryReach{Addr: r.Addr, Port: r.Port, Family: r.Family, Via: r.Via,
				Reachable: why == "", Reason: why, CheckedAt: now}
		}(i, r)
	}
	wg.Wait()
	written, err := s.Store.SetEntryReach(host, out)
	if err != nil {
		log.Printf("door reach %s: %v", host, err)
		return
	}
	ok := 0
	for _, r := range written {
		if r.Reachable {
			ok++
		}
	}
	log.Printf("door reach %s (hub re-check on its pull): %d of %d address(es) reachable", host, ok, len(written))
}

// entryDialableString: a stored address the hub may still dial.
func entryDialableString(addr string) bool {
	a, err := netip.ParseAddr(addr)
	return err == nil && entryDialable(a)
}
