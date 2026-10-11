package api

import (
	"context"
	"log"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/dns"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Every person's address points at their home (claude-fleet#3073, EPIC
// #3067 C7 · 共同约定 6).
//
// One loop on one replica (leader job "entry-dns") every minute: for each
// address name that answers (a current one, and a retired one for its seven
// days) the target is its person's home machine's reachable entry addresses
// (C6's EntryReachable — A for IPv4, AAAA for IPv6); the zone's marked
// records are compared with it and only the difference is written, each
// write one line of the door's audit (kind "dns"). A home nobody reaches
// right now is left alone — its records keep the last address, the keys
// page says 从外面连不上 — never pointed elsewhere. A record nothing answers
// for any more (a name past its seven days) goes. A record someone changed
// by hand while the target stood still is put back next tick, its audit
// line saying 有人手改.
//
// Off — no token in the environment (dns.FromEnv), or fleet.entry off —
// the loop makes no call at all and the page reads as before.

// EntryDNSEvery is how often the records are compared.
const EntryDNSEvery = time.Minute

// entryDNSMaxWrites bounds one tick's writes (DNSPod rate-limits); the rest
// are the next tick's.
const entryDNSMaxWrites = 40

// EntryDNS is the address-record writer; Server.EntryDNS nil = off.
type EntryDNS struct {
	Provider  dns.Provider
	Subdomain string // the label every address sits under: cf

	mu sync.Mutex
	// wrote is what each (host, type) was last set to by this loop —
	// a record that differs from it while the target did not move was
	// changed by hand.
	wrote map[entryDNSKey][]string
}

type entryDNSKey struct{ host, typ string }

// NewEntryDNS is the writer for p under sub.
func NewEntryDNS(p dns.Provider, sub string) *EntryDNS {
	return &EntryDNS{Provider: p, Subdomain: sub, wrote: map[entryDNSKey][]string{}}
}

// RunEntryDNS compares every EntryDNSEvery until ctx ends, on the replica
// that leads "entry-dns". Off: returns at once.
func (s *Server) RunEntryDNS(ctx context.Context) {
	if s.EntryDNS == nil {
		return
	}
	t := time.NewTicker(EntryDNSEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if !s.Elector.Leader(ctx, "entry-dns") {
				continue
			}
			s.EntryDNSTick(ctx, now)
		}
	}
}

// entryDNSTarget is one host's wanted records: its person and home, and
// hold when the home is not reachable (leave whatever stands).
type entryDNSTarget struct {
	person, machine string
	hold            bool
	want            map[string][]string // A / AAAA → sorted values
}

// EntryDNSTick compares once at now and writes the difference; it answers
// how many writes it made.
func (s *Server) EntryDNSTick(ctx context.Context, now time.Time) int {
	d := s.EntryDNS
	if d == nil || !s.entryOn() {
		return 0
	}
	targets, err := s.entryDNSTargets(d.Subdomain, now)
	if err != nil {
		log.Printf("entry dns: read the book: %v", err)
		return 0
	}
	recs, err := d.Provider.List(ctx)
	if err != nil {
		log.Printf("entry dns: list: %v", err)
		return 0
	}
	have := map[entryDNSKey][]dns.Record{}
	for _, r := range recs {
		if dns.NameOf(r.Name, d.Subdomain) == "" {
			continue // List answers only ours; under the subdomain, twice sure
		}
		k := entryDNSKey{strings.ToLower(r.Name), r.Type}
		have[k] = append(have[k], r)
	}
	keys := map[entryDNSKey]bool{}
	for k := range have {
		keys[k] = true
	}
	for host, t := range targets {
		for typ := range t.want {
			keys[entryDNSKey{host, typ}] = true
		}
	}
	order := make([]entryDNSKey, 0, len(keys))
	for k := range keys {
		order = append(order, k)
	}
	sort.Slice(order, func(i, j int) bool {
		if order[i].host != order[j].host {
			return order[i].host < order[j].host
		}
		return order[i].typ < order[j].typ
	})

	d.mu.Lock()
	defer d.mu.Unlock()
	writes := 0
	for _, k := range order {
		t, named := targets[k.host]
		if named && t.hold {
			continue
		}
		var want []string
		if named {
			want = t.want[k.typ]
		}
		ex := have[k]
		if sameValues(recValues(ex), want) {
			d.wrote[k] = want
			continue
		}
		last, known := d.wrote[k]
		byHand := known && sameValues(last, want)
		n, done := s.entryDNSApply(ctx, d, k, ex, want, t, byHand, now, entryDNSMaxWrites-writes)
		writes += n
		if done {
			d.wrote[k] = want
		}
		if writes >= entryDNSMaxWrites {
			break
		}
	}
	return writes
}

// entryDNSTargets is every answering name's host → its target.
func (s *Server) entryDNSTargets(sub string, now time.Time) (map[string]entryDNSTarget, error) {
	names, err := s.Store.EntryNames(now)
	if err != nil {
		return nil, err
	}
	homes, err := s.Store.EntryHomes()
	if err != nil {
		return nil, err
	}
	home := map[string]store.EntryHome{}
	for _, h := range homes {
		home[h.Person] = h
	}
	out := map[string]entryDNSTarget{}
	for _, n := range names {
		host := dns.Host(n.Name, sub)
		h, ok := home[n.Person]
		if !ok {
			// No home yet: nothing to point at, nothing to keep.
			out[host] = entryDNSTarget{person: n.Person}
			continue
		}
		t := entryDNSTarget{person: n.Person, machine: h.Machine}
		reach, err := s.EntryReachable(h.Machine, now)
		if err != nil || len(reach) == 0 {
			t.hold = true
			out[host] = t
			continue
		}
		// The port is not in DNS: one name, one port for Termius. With an
		// IPv4 the router forwards on its own port, an IPv6 reached on
		// another port would send a phone with IPv6 to the wrong one — so an
		// AAAA only where its port is the A's.
		v4port := 0
		for _, r := range reach {
			if r.Family == "ipv4" {
				v4port = r.Port
				break
			}
		}
		t.want = map[string][]string{}
		for _, r := range reach {
			typ := "A"
			if r.Family == "ipv6" {
				if v4port != 0 && r.Port != v4port {
					continue
				}
				typ = "AAAA"
			}
			t.want[typ] = append(t.want[typ], r.Addr)
		}
		for typ, v := range t.want {
			t.want[typ] = uniqSorted(v)
		}
		out[host] = t
	}
	return out, nil
}

// entryPublicPort is the port the outside reaches machine's door at: the
// router's forwarded port C6 knocked on (its entry= route — two homes
// behind one router differ by it), else the door's own. A reachable row
// speaks first (IPv4 before IPv6, as the records), then any IPv4 row, then
// entryPort.
func (s *Server) entryPublicPort(machine string, now time.Time) int {
	if machine == "" {
		return entryPort
	}
	if reach, err := s.EntryReachable(machine, now); err == nil && len(reach) > 0 && reach[0].Port > 0 {
		return reach[0].Port // IPv4 first: the A's port, else the AAAA's
	}
	rows, err := s.entryReachRows(machine)
	if err == nil {
		for _, r := range rows {
			if r.Family == "ipv4" && r.Port > 0 {
				return r.Port
			}
		}
	}
	return entryPort
}

// entryDNSApply turns ex into want with at most budget writes: a record
// already holding a wanted value stays, a surplus one is changed to a
// missing value, the rest made or removed. done = every write went through.
func (s *Server) entryDNSApply(ctx context.Context, d *EntryDNS, k entryDNSKey, ex []dns.Record, want []string,
	t entryDNSTarget, byHand bool, now time.Time, budget int) (int, bool) {
	wanted := map[string]bool{}
	for _, v := range want {
		wanted[v] = true
	}
	var spare []dns.Record
	for _, r := range ex {
		if wanted[r.Value] {
			delete(wanted, r.Value)
		} else {
			spare = append(spare, r)
		}
	}
	missing := make([]string, 0, len(wanted))
	for _, v := range want {
		if wanted[v] {
			missing = append(missing, v)
		}
	}
	note := ""
	if byHand {
		note = "（有人手改，改回）"
	}
	audit := func(result string) {
		s.entryAudit(store.EntryAudit{At: now, Kind: "dns", Person: t.person, Machine: t.machine, Result: result, Actor: "hub"})
	}
	n, done := 0, true
	for len(missing) > 0 || len(spare) > 0 {
		if n >= budget {
			return n, false
		}
		var err error
		switch {
		case len(missing) > 0 && len(spare) > 0:
			r := spare[0]
			old := r.Value
			r.Value, r.TTL = missing[0], dns.TTL
			if _, err = d.Provider.Upsert(ctx, r); err == nil {
				audit(k.typ + " " + k.host + " " + old + " → " + r.Value + note)
			}
			spare, missing = spare[1:], missing[1:]
		case len(missing) > 0:
			r := dns.Record{Name: k.host, Type: k.typ, Value: missing[0], TTL: dns.TTL}
			if _, err = d.Provider.Upsert(ctx, r); err == nil {
				audit(k.typ + " " + k.host + " + " + r.Value + note)
			}
			missing = missing[1:]
		default:
			r := spare[0]
			if err = d.Provider.Delete(ctx, r.ID); err == nil {
				audit(k.typ + " " + k.host + " − " + r.Value + note)
			}
			spare = spare[1:]
		}
		n++
		if err != nil {
			done = false
			log.Printf("entry dns: %s %s: %v", k.typ, k.host, err)
		}
	}
	return n, done
}

func recValues(rs []dns.Record) []string {
	out := make([]string, 0, len(rs))
	for _, r := range rs {
		out = append(out, r.Value)
	}
	return out
}

// sameValues reports a and b hold the same values, each once (a duplicate
// record is a difference: one of the two goes).
func sameValues(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	x, y := append([]string(nil), a...), append([]string(nil), b...)
	sort.Strings(x)
	sort.Strings(y)
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}

func uniqSorted(v []string) []string {
	sort.Strings(v)
	return slices.Compact(v)
}
