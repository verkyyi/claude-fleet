package api

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Can the outside reach a home machine's entry port? (claude-fleet#3072,
// EPIC #3067 C6)
//
// Every five minutes the machine's node program POSTs EntryReachReport: its
// entry port and host key, its global IPv6 addresses, and what its router
// said when asked to forward the port. The public IPv4 is never the
// machine's say — it is the address the hub sees the report come from. The
// hub then dials each address from where it stands: an address counts only
// when an sshd answers there AND shows the entry port's host key (another
// box behind the same address, or the system sshd, never counts). The rows go
// to fleet_entry_reach, the verdict back to the machine (the doctor's
// `public` row), and EntryReachable — reachable(machine) — is all the
// address record (C7) and the client's route (C9) read.
//
// The hub dials only what a machine could legitimately be reached at: a
// public unicast address, never a private, loopback, link-local or carrier-
// NAT one — a report cannot turn the hub into a scanner of its own network.

// entryProbeTimeout bounds one dial + the key exchange (a var for tests).
var entryProbeTimeout = 6 * time.Second

const (
	// entryReachGap is the least time between two checks of one machine; a
	// report inside it is answered from the last check.
	entryReachGap = time.Minute
	// EntryReachFresh is how old a check may be and still count: a machine
	// reports every 5 minutes, so three missed reports and its addresses
	// stop counting.
	EntryReachFresh = 15 * time.Minute
	// entryReachV6Max bounds the IPv6 addresses one report may have dialled.
	entryReachV6Max = 4
)

// entryCGNAT is 100.64.0.0/10: carrier NAT's (and the tailnet's) space.
var entryCGNAT = netip.MustParsePrefix("100.64.0.0/10")

// entryNotPublic are the unicast ranges no one outside reaches a home at.
var entryNotPublic = []netip.Prefix{
	entryCGNAT,
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("64:ff9b::/96"),
}

// entryPublicAddr: an address the open internet routes to.
func entryPublicAddr(a netip.Addr) bool {
	a = a.Unmap()
	if !a.IsValid() || !a.IsGlobalUnicast() || a.IsPrivate() {
		return false
	}
	for _, p := range entryNotPublic {
		if p.Contains(a) {
			return false
		}
	}
	return true
}

// entryDialable is the injection point for tests: which addresses the hub
// may dial.
var entryDialable = entryPublicAddr

// errReachDone ends a probe's handshake once the host key is seen: nothing
// is ever tried as a login, so the entry sshd counts no failed attempt.
var errReachDone = errors.New("entry reach: host key seen")

// prefixConn is a conn whose first bytes were already peeked.
type prefixConn struct {
	net.Conn
	r *bufio.Reader
}

func (c prefixConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// entryProbeSSH dials addr:port and reads the sshd's host key: "" when it is
// want, else why not (control.Reach*).
func entryProbeSSH(ctx context.Context, addr string, port int, want ssh.PublicKey) string {
	ctx, cancel := context.WithTimeout(ctx, entryProbeTimeout)
	defer cancel()
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(addr, strconv.Itoa(port)))
	if err != nil {
		return entryDialReason(err)
	}
	defer conn.Close()
	dl, _ := ctx.Deadline()
	_ = conn.SetDeadline(dl)
	br := bufio.NewReader(conn)
	head, err := br.Peek(4)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return control.ReachTimeout
		}
		return control.ReachNotSSH
	}
	if string(head) != "SSH-" {
		return control.ReachNotSSH
	}
	algos := []string{want.Type()}
	if want.Type() == ssh.KeyAlgoRSA {
		algos = []string{ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSA}
	}
	matched := false
	cfg := &ssh.ClientConfig{
		User:              "fleet-reach",
		HostKeyAlgorithms: algos,
		HostKeyCallback: func(_ string, _ net.Addr, k ssh.PublicKey) error {
			matched = bytes.Equal(k.Marshal(), want.Marshal())
			return errReachDone
		},
	}
	_, _, _, err = ssh.NewClientConn(prefixConn{conn, br}, addr, cfg)
	switch {
	case matched:
		return ""
	case err != nil && errors.Is(err, errReachDone):
		return control.ReachHostKey
	case err != nil && strings.Contains(err.Error(), "no common algorithm"):
		// It offers no key of the entry's kind: not the entry's sshd.
		return control.ReachHostKey
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return control.ReachTimeout
	}
	return control.ReachNotSSH
}

// entryDialReason names a failed dial.
func entryDialReason(err error) string {
	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return control.ReachRefused
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, syscall.ETIMEDOUT):
		return control.ReachTimeout
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		return control.ReachTimeout
	}
	return control.ReachNoRoute
}

// entryProbe is the injection point for tests.
var entryProbe = entryProbeSSH

// entryReportSource is the address a request came from: the right-most
// public X-Forwarded-For entry (the one our ingress appended), else the
// socket's peer. forwarded says it came through the ingress — a carrier-NAT
// address there is the carrier's, while a direct peer in 100.64/10 is as
// likely the tailnet's.
func entryReportSource(r *http.Request) (netip.Addr, bool) {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		for i := len(parts) - 1; i >= 0; i-- {
			a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
			if err == nil && !a.IsPrivate() && !a.IsLoopback() && !a.IsLinkLocalUnicast() {
				return a.Unmap(), true
			}
		}
	}
	ap, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}, false
	}
	return ap.Addr().Unmap(), false
}

// entryCandidate is one address to dial.
type entryCandidate struct {
	addr netip.Addr
	port int
	via  string
}

func entryFamily(a netip.Addr) string {
	if a.Is4() {
		return "ipv4"
	}
	return "ipv6"
}

// entryReachCandidates is what the hub dials for one report: the report's
// source when it is public (on the router's forwarded port when the router
// said one), the router's own outside address when it differs, the
// machine's global IPv6 addresses. noPublic is "cgnat" when the machine looks
// to sit behind carrier NAT: its router's outside address is not public, or
// it is but the hub saw the machine come from another one.
func entryReachCandidates(rep control.EntryReachReport, src netip.Addr, forwarded bool, routeAddrs ...netip.Addr) (out []entryCandidate, noPublic string) {
	seen := map[string]bool{}
	add := func(a netip.Addr, port int, via string) {
		a = a.Unmap()
		if port <= 0 || port > 65535 || !entryDialable(a) {
			return
		}
		k := netip.AddrPortFrom(a, uint16(port)).String()
		if seen[k] {
			return
		}
		seen[k] = true
		out = append(out, entryCandidate{a, port, via})
	}
	var wan netip.Addr
	extPort := rep.Port
	if rep.EntryPort > 0 {
		// The router forwards this public port to the entry (the machine's
		// entry= route): that, not the entry's own, is where to knock.
		extPort = rep.EntryPort
	}
	if pm := rep.PortMap; pm != nil && pm.Error == "" {
		wan, _ = netip.ParseAddr(pm.ExternalIP)
		wan = wan.Unmap()
		if pm.ExternalPort > 0 {
			extPort = pm.ExternalPort
		}
	}
	if src.IsValid() {
		if (wan.IsValid() && src == wan) || rep.EntryPort > 0 {
			add(src, extPort, "source")
		} else {
			add(src, rep.Port, "source")
		}
	}
	for _, a := range routeAddrs {
		add(a, extPort, "route")
	}
	if wan.IsValid() {
		add(wan, extPort, "portmap")
		switch {
		case wan.Is4() && (entryCGNAT.Contains(wan) || wan.IsPrivate()):
			noPublic = "cgnat"
		case wan.Is4() && src.Is4() && entryPublicAddr(src) && src != wan:
			noPublic = "cgnat"
		}
	}
	if noPublic == "" && forwarded && src.Is4() && entryCGNAT.Contains(src) {
		noPublic = "cgnat"
	}
	n := 0
	for _, s := range rep.V6 {
		a, err := netip.ParseAddr(strings.TrimSpace(s))
		if err != nil || !a.Is6() || a.Is4In6() || !entryDialable(a) || n == entryReachV6Max {
			continue
		}
		n++
		add(a, rep.Port, "ipv6")
	}
	return out, noPublic
}

// entryResolve is the entry route's host's addresses (an IP literal is
// itself); nothing when there is none or it does not resolve in 3 s.
var entryResolve = func(ctx context.Context, host string) []netip.Addr {
	host = strings.TrimSpace(host)
	if host == "" || len(host) > 253 {
		return nil
	}
	if a, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{a}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return nil
	}
	if len(ips) > 4 {
		ips = ips[:4]
	}
	return ips
}

// handleNodeEntryReach serves EntryReachNodePath.
func (s *Server) handleNodeEntryReach(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	host := s.entryMachineOf(w, r)
	if host == "" {
		return
	}
	var rep control.EntryReachReport
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&rep); err != nil {
		httpError(w, http.StatusBadRequest, "body must be JSON {port, host_key, listening, v6?, lan?, portmap?}")
		return
	}
	if rep.Port <= 0 || rep.Port > 65535 {
		httpError(w, http.StatusBadRequest, "port must be 1–65535")
		return
	}
	var want ssh.PublicKey
	if rep.Listening {
		k, _, _, rest, err := ssh.ParseAuthorizedKey([]byte(rep.HostKey))
		if err != nil || len(bytes.TrimSpace(rest)) > 0 {
			httpError(w, http.StatusBadRequest, "host_key must be the entry port's public host key \"<type> <base64>\"")
			return
		}
		want = k
	}
	now := time.Now().UTC()
	key := strings.ToLower(host)
	s.entryReachSeen.Store(key, entryReachSeen{At: now, Listening: rep.Listening})
	if last, ok := s.entryReachAt.Load(key); ok && now.Sub(last.(time.Time)) < entryReachGap {
		v, err := s.entryReachVerdict(host, now)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		v.Throttled = true
		writeJSON(w, http.StatusOK, v)
		return
	}
	s.entryReachAt.Store(key, now)

	if rep.EntryPort < 0 || rep.EntryPort > 65535 {
		httpError(w, http.StatusBadRequest, "entry_port must be 1–65535")
		return
	}
	src, fwd := entryReportSource(r)
	cands, noPublic := entryReachCandidates(rep, src, fwd, entryResolve(r.Context(), rep.EntryHost)...)
	if !rep.Listening {
		cands = nil // nothing listens: no address counts, none is dialled
	}
	rows := make([]store.EntryReach, len(cands))
	var wg sync.WaitGroup
	for i, c := range cands {
		wg.Add(1)
		go func(i int, c entryCandidate) {
			defer wg.Done()
			why := entryProbe(r.Context(), c.addr.String(), c.port, want)
			rows[i] = store.EntryReach{Addr: c.addr.String(), Port: c.port, Family: entryFamily(c.addr), Via: c.via,
				Reachable: why == "", Reason: why, CheckedAt: now}
		}(i, c)
	}
	wg.Wait()
	written, err := s.Store.SetEntryReach(host, rows)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	v := control.EntryReachVerdict{CheckedAt: now, NoPublic: noPublic, Addrs: entryReachAddrs(written)}
	if src.IsValid() {
		v.Source = src.String()
	}
	ok := 0
	for _, a := range v.Addrs {
		if a.Reachable {
			ok++
		}
	}
	log.Printf("entry reach %s: %d of %d address(es) reachable%s", host, ok, len(v.Addrs),
		map[bool]string{true: " · no public IPv4 (" + noPublic + ")", false: ""}[noPublic != ""])
	writeJSON(w, http.StatusOK, v)
}

func entryReachAddrs(rows []store.EntryReach) []control.EntryReachAddr {
	out := make([]control.EntryReachAddr, 0, len(rows))
	for _, r := range rows {
		out = append(out, control.EntryReachAddr{Addr: r.Addr, Family: r.Family, Port: r.Port, Via: r.Via,
			Reachable: r.Reachable, Reason: r.Reason, LastOK: r.LastOK})
	}
	return out
}

// entryReachRows is machine's rows (any spelling of its name).
func (s *Server) entryReachRows(machine string) ([]store.EntryReach, error) {
	all, err := s.Store.EntryReachAll()
	if err != nil {
		return nil, err
	}
	var out []store.EntryReach
	for _, r := range all {
		if sameMachine(r.Machine, machine) || sameMachine(machine, r.Machine) {
			out = append(out, r)
		}
	}
	return out, nil
}

// entryReachVerdict is the last check of machine, as a verdict.
func (s *Server) entryReachVerdict(machine string, now time.Time) (control.EntryReachVerdict, error) {
	rows, err := s.entryReachRows(machine)
	if err != nil {
		return control.EntryReachVerdict{}, err
	}
	v := control.EntryReachVerdict{CheckedAt: now, Addrs: entryReachAddrs(rows)}
	for _, r := range rows {
		if r.CheckedAt.Before(v.CheckedAt) {
			v.CheckedAt = r.CheckedAt
		}
	}
	return v, nil
}

// entryReachSeen is a machine's last report, as the keys page reads it.
type entryReachSeen struct {
	At        time.Time
	Listening bool
}

// entryLastReport is machine's last report since the hub started, ok=false
// when none.
func (s *Server) entryLastReport(machine string) (entryReachSeen, bool) {
	var out entryReachSeen
	found := false
	s.entryReachSeen.Range(func(k, v any) bool {
		if sameMachine(k.(string), machine) || sameMachine(machine, k.(string)) {
			if r := v.(entryReachSeen); !found || r.At.After(out.At) {
				out, found = r, true
			}
		}
		return true
	})
	return out, found
}

// EntryReachable is one address the outside reaches a home machine's entry
// port at.
type EntryReachable struct {
	Addr   string `json:"addr"`
	Family string `json:"family"`
	Port   int    `json:"port"`
}

// EntryReachable is reachable(machine) (EPIC #3067 C6 → C7, C9): the
// addresses the hub reached machine's entry port at on a check no older than
// EntryReachFresh, IPv4 first. An address that only resolves — that the
// machine reported but nothing answered at, or something else answered —
// is never in it.
func (s *Server) EntryReachable(machine string, now time.Time) ([]EntryReachable, error) {
	rows, err := s.entryReachRows(machine)
	if err != nil {
		return nil, err
	}
	out := []EntryReachable{}
	for _, r := range rows {
		if r.Reachable && now.Sub(r.CheckedAt) <= EntryReachFresh {
			out = append(out, EntryReachable{Addr: r.Addr, Family: r.Family, Port: r.Port})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Family < out[j].Family })
	return out, nil
}
