package api

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/credvault"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The Singapore relay's door (claude-fleet#1974, EPIC #1967 C7).
//
// A trusted machine that cannot reach the upstream directly sends its
// session's traffic through a forwarder in Singapore. That forwarder holds no
// subscription credential and parses none: it asks the hub, per request,
// whether the request may pass — Caddy's forward_auth against
// GET /v1/relay/check — and the hub answers from what it already records about
// the machine. The `Authorization` header (the subscription) is never sent to
// the hub and never read by the forwarder; the pass travels in its own header,
// X-Fleet-Relay, which the forwarder strips before it forwards.
//
//   - A relay credential is per machine and per login: POST
//     /v1/node/relay-credential, with the node's enrollment token, mints
//     `frl1.<random>` for a TRUSTED machine with an active fleet account that
//     is not revoked. Only its SHA-256 is kept, in the fleet setting
//     `fleet.node_relay.<machine>` (the same table and machine match as
//     C1's `fleet.node_trust.<machine>`) as `<login>:<hash>` words, so
//     several logins on one machine each hold their own and re-minting one
//     replaces only that login's.
//   - Revocable: the operator's PUT /v1/fleet/settings with
//     fleet.node_relay.<machine> = "" drops every one of that machine's
//     (bin/fleet-relay-cred.sh revoke); marking it untrusted, or a
//     credential revocation for the machine, refuses it at the next check
//     too. No route sets a hash by hand.
//   - The check also takes an ingress-issued session pass (`fcp-h1.`, C2) —
//     the central proxy (C6) egresses with it — verified by C2's
//     verifySessionCred for the provider the path goes to (/anthropic/ →
//     claude, /chatgpt/ and /openai-auth/ → codex). Its verdicts are C2's
//     cache's, never this one's, so a pass revoked through C2's routes stops
//     at once.
//   - A relay credential's verdict is cached for relayCheckTTL (keyed by the
//     token's hash, never the token), and every write that can change one — a
//     relay credential minted or dropped, a trust change, a credential
//     revocation — empties the cache, so a revocation takes effect at once on
//     this replica and within relayCheckTTL on any other.

const (
	// NodeRelayPrefix names the per-machine relay-credential setting.
	NodeRelayPrefix = "fleet.node_relay."
	// RelayCheckPath is the forwarder's forward_auth target.
	RelayCheckPath = "/v1/relay/check"
	// RelayHeader carries the pass from the machine to the forwarder.
	RelayHeader = "X-Fleet-Relay"

	relayTokenPrefix = "frl1."
	hubPassPrefix    = "fcp-h1."
	relayCheckTTL    = 30 * time.Second
)

// relayPrefixes are the forwarder's routes (docs/CRED-RELAY.md); a check that
// names another path is refused, so a pass opens nothing else on that host.
var relayPrefixes = []string{"/anthropic/", "/chatgpt/", "/openai-auth/"}

var relayLoginRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)

// relayProvider is the subscription a relay path goes to ("" = none).
func relayProvider(uri string) string {
	switch {
	case strings.HasPrefix(uri, "/anthropic/"):
		return credvault.Claude
	case strings.HasPrefix(uri, "/chatgpt/"), strings.HasPrefix(uri, "/openai-auth/"):
		return credvault.Codex
	}
	return ""
}

// verifyHubSessionPass checks an ingress-issued session pass (`fcp-h1.`,
// EPIC #1967 C2) for the provider uri goes to, and names whose it is.
func (s *Server) verifyHubSessionPass(tok, uri string, now time.Time) relayVerdict {
	v, _ := s.verifySessionCred(tok, "", relayProvider(uri), false, now)
	if !v.Valid {
		why := v.Reason
		if why == "" {
			why = "invalid"
		}
		return relayVerdict{why: "session pass refused: " + why}
	}
	return relayVerdict{ok: true, who: v.Principal + "@" + v.Machine}
}

// relayVerdict is one cached answer.
type relayVerdict struct {
	ok    bool
	who   string // machine (frl1.) or the pass's holder (fcp-h1.)
	why   string
	until time.Time
}

// relayCache holds recent verdicts by token hash.
type relayCache struct {
	mu sync.Mutex
	m  map[string]relayVerdict
}

var relayCaches sync.Map // *Server → *relayCache

func (s *Server) relayCache() *relayCache {
	c, _ := relayCaches.LoadOrStore(s, &relayCache{m: map[string]relayVerdict{}})
	return c.(*relayCache)
}

// relayCacheReset drops every cached verdict: called on each write that can
// change one.
func (s *Server) relayCacheReset() {
	c := s.relayCache()
	c.mu.Lock()
	c.m = map[string]relayVerdict{}
	c.mu.Unlock()
}

// relayEntries parses a setting value: login → hash.
func relayEntries(v string) map[string]string {
	out := map[string]string{}
	for _, w := range strings.Fields(v) {
		if i := strings.LastIndexByte(w, ':'); i > 0 {
			out[w[:i]] = w[i+1:]
		}
	}
	return out
}

func relayValue(e map[string]string) string {
	logins := make([]string, 0, len(e))
	for l := range e {
		logins = append(logins, l)
	}
	sort.Strings(logins)
	words := make([]string, 0, len(logins))
	for _, l := range logins {
		words = append(words, l+":"+e[l])
	}
	return strings.Join(words, " ")
}

// relayKey is the setting key for a machine name as given.
func relayKey(machine string) string {
	return NodeRelayPrefix + strings.ToLower(firstLabel(machine))
}

// relayMachineOf finds the machine whose relay setting holds hash ("" = none).
func relayMachineOf(hash string, settings map[string]string) string {
	for k, v := range settings {
		if !strings.HasPrefix(k, NodeRelayPrefix) || v == "" {
			continue
		}
		for _, h := range relayEntries(v) {
			if subtle.ConstantTimeCompare([]byte(h), []byte(hash)) == 1 {
				return k[len(NodeRelayPrefix):]
			}
		}
	}
	return ""
}

// NodeRelayCredential is POST /v1/node/relay-credential's answer. Token is
// shown once; the hub keeps only its hash.
type NodeRelayCredential struct {
	Token    string    `json:"token"`
	Machine  string    `json:"machine"`
	Login    string    `json:"login"`
	IssuedAt time.Time `json:"issued_at"`
}

// handleNodeRelayCredential mints this login's relay credential.
func (s *Server) handleNodeRelayCredential(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	ep, ok := s.nodeEndpoint(w, r)
	if !ok {
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	host, osUser := s.nodeIdentity(ep)
	machine := strings.ToLower(firstLabel(host))
	refuse := func(code int, reason, msg string) {
		s.leaseAudit(osUser+"@"+machine, "relay_cred", "machine:"+machine, "DENY "+reason, now)
		writeJSON(w, code, map[string]string{"error": reason, "message": msg})
	}
	if machine == "" || !relayLoginRE.MatchString(osUser) {
		refuse(http.StatusForbidden, LeaseNoPrincipal, "this enrollment names no machine and login")
		return
	}
	principal, err := s.Store.PrincipalForLogin(host, osUser)
	if errors.Is(err, store.ErrNoPrincipal) {
		refuse(http.StatusForbidden, LeaseNoPrincipal, "no active fleet account is "+osUser+" on "+host)
		return
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if rev, err := s.Store.RevokedFor(host, principal); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	} else if rev != nil {
		refuse(http.StatusForbidden, LeaseRevoked, "credentials for "+machine+" were revoked at "+rev.RevokedAt.Format(time.RFC3339))
		return
	}
	settings, err := s.trustSettings(now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if trustOf(host, settings) != TrustTrusted {
		refuse(http.StatusForbidden, LeaseUntrusted, machine+" is not a trusted machine — an untrusted machine's sessions go through the central proxy, never the relay with their own credential")
		return
	}
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	tok := relayTokenPrefix + base64.RawURLEncoding.EncodeToString(b[:])
	key := relayKey(host)
	entries := relayEntries(settings[key])
	entries[osUser] = HashToken(tok)
	if err := s.Store.SetFleetSetting(key, relayValue(entries), now); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.relayCacheReset()
	s.leaseAudit(osUser+"@"+machine, "relay_cred", "machine:"+machine, "ISSUE "+osUser, now)
	writeJSON(w, http.StatusOK, NodeRelayCredential{Token: tok, Machine: machine, Login: osUser, IssuedAt: now.UTC()})
}

// handleRelayCheck is the forwarder's forward_auth: 200 lets the request
// through, 403 refuses it. It reads only X-Fleet-Relay and the forwarded
// path; a subscription Authorization header, if a forwarder sent one anyway,
// is never read or logged.
func (s *Server) handleRelayCheck(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	deny := func(why string) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "relay_refused", "message": why})
	}
	if uri := r.Header.Get("X-Forwarded-Uri"); uri != "" && !relayPathOK(uri) {
		deny("the relay forwards only " + strings.Join(relayPrefixes, ", "))
		return
	}
	tok := strings.TrimSpace(r.Header.Get(RelayHeader))
	if tok == "" {
		deny("no " + RelayHeader + " pass")
		return
	}
	v := s.relayVerdictFor(tok, r.Header.Get("X-Forwarded-Uri"), time.Now())
	if !v.ok {
		log.Printf("relay check: refused %s<redacted:%d>: %s", tokPrefix(tok), len(tok), v.why)
		deny(v.why)
		return
	}
	w.Header().Set("X-Fleet-Relay-Who", v.who)
	w.WriteHeader(http.StatusOK)
}

func relayPathOK(uri string) bool {
	for _, p := range relayPrefixes {
		if strings.HasPrefix(uri, p) {
			return true
		}
	}
	return false
}

// tokPrefix is the token's kind for a log line — never more of it.
func tokPrefix(tok string) string {
	switch {
	case strings.HasPrefix(tok, relayTokenPrefix):
		return relayTokenPrefix
	case strings.HasPrefix(tok, hubPassPrefix):
		return hubPassPrefix
	}
	return ""
}

// relayVerdictFor answers a session pass from C2's verifier, a relay
// credential from the cache, else from the settings.
func (s *Server) relayVerdictFor(tok, uri string, now time.Time) relayVerdict {
	if strings.HasPrefix(tok, hubPassPrefix) {
		return s.verifyHubSessionPass(tok, uri, now)
	}
	hash := HashToken(tok)
	c := s.relayCache()
	c.mu.Lock()
	v, hit := c.m[hash]
	c.mu.Unlock()
	if hit && now.Before(v.until) {
		return v
	}
	v = s.relayJudge(tok, hash, now)
	v.until = now.Add(relayCheckTTL)
	c.mu.Lock()
	if len(c.m) > 4096 {
		c.m = map[string]relayVerdict{}
	}
	c.m[hash] = v
	c.mu.Unlock()
	return v
}

func (s *Server) relayJudge(tok, hash string, now time.Time) relayVerdict {
	switch {
	case strings.HasPrefix(tok, relayTokenPrefix):
		settings, err := s.trustSettings(now)
		if err != nil {
			return relayVerdict{why: "the hub could not read its settings"}
		}
		machine := relayMachineOf(hash, settings)
		if machine == "" {
			return relayVerdict{why: "unknown or revoked relay credential"}
		}
		if trustOf(machine, settings) != TrustTrusted {
			return relayVerdict{why: machine + " is not a trusted machine"}
		}
		if rev, err := s.Store.RevokedFor(machine, ""); err != nil {
			return relayVerdict{why: "the hub could not read its revocations"}
		} else if rev != nil && rev.Hostname != "" && rev.PrincipalID == "" {
			return relayVerdict{why: machine + " was revoked"}
		}
		return relayVerdict{ok: true, who: machine}
	}
	return relayVerdict{why: "not a relay pass"}
}

// revokeRelay drops every relay credential of machine (each spelling of
// it), and audits the operator's call.
func (s *Server) revokeRelay(machine string, now time.Time) error {
	settings, err := s.Store.FleetSettings()
	if err != nil {
		return err
	}
	n := 0
	for k, v := range settings {
		if strings.HasPrefix(k, NodeRelayPrefix) && v != "" &&
			(sameMachine(machine, k[len(NodeRelayPrefix):]) || sameMachine(k[len(NodeRelayPrefix):], machine)) {
			n += len(relayEntries(v))
			if err := s.Store.SetFleetSetting(k, "", now); err != nil {
				return err
			}
		}
	}
	s.relayCacheReset()
	s.leaseAudit("operator", "relay_cred", "machine:"+strings.ToLower(firstLabel(machine)), "REVOKE "+strconv.Itoa(n), now)
	return nil
}

// relayRedact is a settings map for display: a relay setting shows the
// logins that hold a credential, never a hash.
func relayRedact(settings map[string]string) map[string]string {
	out := make(map[string]string, len(settings))
	for k, v := range settings {
		if strings.HasPrefix(k, NodeRelayPrefix) && v != "" {
			logins := []string{}
			for l := range relayEntries(v) {
				logins = append(logins, l)
			}
			sort.Strings(logins)
			v = strings.Join(logins, " ")
		}
		out[k] = v
	}
	return out
}
