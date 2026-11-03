package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// Connected agents (task T4DN): a person's own Claude Code, Codex, Gemini CLI
// or claude.ai reaching /mcp AS that person — never anywhere else.
//
//	personal key   Authorization: Bearer tm_…   minted on the console (POST /v1/me/agents)
//	OAuth          Authorization: Bearer tma_…  from /oauth/token (oauth.go)
//
// Either resolves to ONE grant row (store.AgentGrant): the person, the scopes
// the person ticked, an expiry, a revocation. The door admits the request as
// that person with role user — an admin's agent sees only the admin's own, as
// the design page promised — and FleetPrincipal carries the grant's scopes so
// every fleet write is checked against them as well as the person's own.
// Only /mcp opens to it: the console, /v1/* and every other route answer the
// usual 401 to the same bearer. Every admission counts on the row (calls,
// last_call_at) — what the 已连接的 Agent list shows.

// doorAgent is the door a connected agent comes in by.
const doorAgent = "agent"

// Token prefixes: the personal key, an OAuth access token, an OAuth refresh token.
const (
	agentKeyPrefix     = "tm_"
	agentAccessPrefix  = "tma_"
	agentRefreshPrefix = "tmr_"
)

// agentAccessTTL is an OAuth access token's life; a refresh rotates it.
const agentAccessTTL = time.Hour

// Grant lives: 30 days unless the person picks another, at most a year.
const (
	agentGrantDefaultTTL = 30 * 24 * time.Hour
	agentGrantMaxTTL     = 365 * 24 * time.Hour
)

// agentPermissions are the words the console and the consent page show, each
// the fleet scopes it grants. read is always included.
var agentPermissions = map[string][]string{
	"read":   {"fleet:read"},
	"talk":   {"worker:message"},
	"start":  {"worker:start"},
	"stop":   {"worker:stop", "worker:resume"},
	"answer": {"worker:answer"},
}

// agentPermissionOrder is the order the permissions are shown in.
var agentPermissionOrder = []string{"read", "talk", "start", "stop", "answer"}

// agentScopes turns permission words (or fleet scope names — an OAuth client
// may ask for either) into the fleet scopes a grant holds, read always among
// them, sorted. An unknown word is an error.
func agentScopes(words []string) ([]string, error) {
	set := map[string]bool{"fleet:read": true}
	for _, w := range words {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		if sc, ok := agentPermissions[w]; ok {
			for _, x := range sc {
				set[x] = true
			}
			continue
		}
		known := false
		for _, sc := range agentPermissions {
			for _, x := range sc {
				if x == w {
					known = true
				}
			}
		}
		if !known {
			return nil, fmt.Errorf("unknown permission %q (one of: %s)", w, strings.Join(agentPermissionOrder, ", "))
		}
		set[w] = true
	}
	out := make([]string, 0, len(set))
	for x := range set {
		out = append(out, x)
	}
	sort.Strings(out)
	return out, nil
}

// agentPermissionWords is the inverse, for display: the permission words a
// grant's scopes cover.
func agentPermissionWords(scopes []string) []string {
	out := []string{}
	for _, w := range agentPermissionOrder {
		all := true
		for _, x := range agentPermissions[w] {
			if !hasString(scopes, x) {
				all = false
			}
		}
		if all {
			out = append(out, w)
		}
	}
	return out
}

func agentSecret(prefix string) (string, error) {
	t, err := randomToken(32)
	return prefix + t, err
}

func agentID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

type agentGrantKey struct{}

// agentGrantOf is the grant a request came in on, nil for every other door.
func agentGrantOf(ctx context.Context) *store.AgentGrant {
	g, _ := ctx.Value(agentGrantKey{}).(*store.AgentGrant)
	return g
}

// agentDoorOn says whether this hub opens the agent door at all: the grants
// live in the fleet module's tables.
func (s *Server) agentDoorOn() bool { return s.Fleet && s.Store != nil }

// isAgentBearer says whether a bearer is shaped like one of ours.
func isAgentBearer(tok string) bool {
	return strings.HasPrefix(tok, agentKeyPrefix) || strings.HasPrefix(tok, agentAccessPrefix)
}

var errAgentToken = errors.New("invalid_token")

// agentGrantFor resolves a bearer to its live grant.
func (s *Server) agentGrantFor(tok string, now time.Time) (store.AgentGrant, error) {
	var g store.AgentGrant
	var err error
	switch {
	case strings.HasPrefix(tok, agentAccessPrefix):
		gid, kind, exp, _, terr := s.Store.OAuthToken(HashToken(tok))
		if terr != nil || kind != "access" || !now.Before(exp) {
			return g, errAgentToken
		}
		g, err = s.Store.AgentGrant(gid)
	case strings.HasPrefix(tok, agentKeyPrefix):
		g, err = s.Store.AgentGrantByTokenHash(HashToken(tok))
	default:
		return g, errAgentToken
	}
	if err != nil || !g.Live(now) {
		return g, errAgentToken
	}
	return g, nil
}

// agentAdmit is viewerOr's last door, for /mcp only: a connected agent's
// bearer, its grant live and its person still on the list (and not a trial).
// ok false with refused true means the bearer was ours and is no good — the
// 401 then says invalid_token, so an OAuth client refreshes.
func (s *Server) agentAdmit(r *http.Request) (ctx context.Context, ok, refused bool) {
	tok := bearer(r)
	if !s.agentDoorOn() || !isAgentBearer(tok) || !s.agentPathOK(r) {
		return nil, false, false
	}
	now := time.Now()
	g, err := s.agentGrantFor(tok, now)
	if err != nil {
		return nil, false, true
	}
	role, err := s.personRole(g.Person)
	if err != nil || role == "" || role == roleTrial {
		return nil, false, true
	}
	if err := s.Store.TouchAgentGrant(g.ID, now); err != nil {
		log.Printf("agent door: count a call on %s: %v", g.ID, err)
	}
	ctx = context.WithValue(withViewer(r.Context(), g.Person), principalKey{}, g.Person)
	ctx = context.WithValue(ctx, agentGrantKey{}, &g)
	ctx = withRole(withDoor(ctx, doorAgent), roleUser)
	return ctx, true, false
}

// agentPathOK is where the agent door opens: /mcp, and — only for a request a
// sibling replica handed on (its shared token), because the person's machine
// link sits there — the chat road a session tool calls inside the hub. The
// tool already checked the grant's scope on the first replica.
func (s *Server) agentPathOK(r *http.Request) bool {
	if r.URL.Path == "/mcp" {
		return true
	}
	return s.Replica != nil && s.Replica.Token != "" && strings.HasPrefix(r.URL.Path, ChatPathPrefix) && s.relayHopped(r)
}

// agentUnauthorized is the 401 /mcp answers when nothing let it in: it names
// the protected-resource metadata, so an MCP client can find where to sign in
// (RFC 9728 §5.1, the MCP authorization spec).
func (s *Server) agentUnauthorized(w http.ResponseWriter, r *http.Request, invalid bool) {
	v := `Bearer realm="ccquota"`
	if s.agentDoorOn() {
		v += `, resource_metadata="` + s.nodeHubURL(r) + protectedResourcePath + `/mcp"`
		if invalid {
			v += `, error="invalid_token"`
		}
	}
	w.Header().Set("WWW-Authenticate", v)
	httpError(w, http.StatusUnauthorized, "a viewer token or a connected agent's key is required")
}
