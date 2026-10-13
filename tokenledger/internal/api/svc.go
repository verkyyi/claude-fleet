package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The service door (claude-fleet#4003, the SPACE EPIC C1):
// /v1/svc/ answers ONLY a service principal's token, `fcs_<prefix8>_<secret>`,
// and a service token opens nothing else — it is no viewer token, no person's
// session and no node token, so every other gate treats it as no credential at
// all. Inside, each route names the one scope it needs (svcOnly); a principal
// without it gets 403. A revoked or expired token, or one whose principal is
// disabled, gets 401 at its very next call: the rows are read on every call.
//
// The principals, their tokens and the switch are an admin's: ccquota svc
// (cmd/ccquota/svc.go) on the hub's database, or POST /v1/fleet/svc. Every
// issue, revoke and call lands in the fleet audit (svc.token.issue,
// svc.token.revoke, svc.call); a revocation also goes on #3560's list.

const (
	// SvcPrefix is the service door's path prefix.
	SvcPrefix = "/v1/svc/"

	// SvcWhoamiPath answers who a token is: any live token, no scope.
	SvcWhoamiPath = "/v1/svc/whoami"

	// SvcAdminPath is the admin's road to principals and tokens.
	SvcAdminPath = "/v1/fleet/svc"

	svcTokenWord   = "fcs_"
	svcPrefixLen   = 8
	svcDefaultDays = 365
)

// MintSvcToken returns a new service token and its prefix. The token is shown
// once; only HashToken(token) and the prefix are stored.
func MintSvcToken() (tok, prefix string, err error) {
	p := make([]byte, svcPrefixLen/2)
	b := make([]byte, tokenBytes)
	if _, err := rand.Read(p); err != nil {
		return "", "", fmt.Errorf("generate token: %w", err)
	}
	if _, err := rand.Read(b); err != nil {
		return "", "", fmt.Errorf("generate token: %w", err)
	}
	prefix = hex.EncodeToString(p)
	return svcTokenWord + prefix + "_" + base64.RawURLEncoding.EncodeToString(b), prefix, nil
}

// svcTokenPrefix is the lookup key a well-formed service token carries.
func svcTokenPrefix(tok string) (string, bool) {
	if !strings.HasPrefix(tok, svcTokenWord) || len(tok) < len(svcTokenWord)+svcPrefixLen+2 {
		return "", false
	}
	rest := tok[len(svcTokenWord):]
	if rest[svcPrefixLen] != '_' {
		return "", false
	}
	p := rest[:svcPrefixLen]
	if _, err := hex.DecodeString(p); err != nil {
		return "", false
	}
	return p, true
}

// svcCaller is the principal a service request came in as.
type svcCaller struct {
	P      store.SvcPrincipal
	Prefix string
}

type svcCallerKey struct{}

// SvcCallerOf is the service principal on ctx, if the request came through
// the service door.
func SvcCallerOf(ctx context.Context) (store.SvcPrincipal, string, bool) {
	c, ok := ctx.Value(svcCallerKey{}).(*svcCaller)
	if !ok {
		return store.SvcPrincipal{}, "", false
	}
	return c.P, c.Prefix, true
}

// svcAuth resolves a bearer to a live principal. why is "" when it admits;
// known is whether the token named a real row (worth an audit line).
func (s *Server) svcAuth(tok string, now time.Time) (c *svcCaller, why string, known bool) {
	prefix, ok := svcTokenPrefix(tok)
	if !ok {
		return nil, "no service token", false
	}
	t, err := s.Store.SvcTokenByPrefix(prefix)
	if err != nil || !constantTimeEqual(t.SHA256, HashToken(tok)) {
		return nil, "unknown service token", false
	}
	c = &svcCaller{Prefix: prefix, P: store.SvcPrincipal{ID: t.Principal}}
	switch {
	case t.RevokedAt != nil:
		return c, "REVOKED", true
	case t.Expires != nil && !now.Before(*t.Expires):
		return c, "EXPIRED", true
	}
	p, err := s.Store.SvcPrincipal(t.Principal)
	if err != nil {
		return c, "NO_PRINCIPAL", true
	}
	c.P = p
	if !p.Enabled {
		return c, "DISABLED", true
	}
	return c, "", true
}

// svcGate admits a live service token and nothing else.
func (s *Server) svcGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		now := time.Now()
		c, why, known := s.svcAuth(bearer(r), now)
		if why != "" {
			if known {
				actor := c.P.ID
				if actor == "" {
					actor = "svc:?"
				}
				s.svcAudit(actor, "svc.call", "route:"+r.Method+" "+r.URL.Path, why, c.Prefix, now)
			}
			w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota-svc"`)
			httpError(w, http.StatusUnauthorized, "a live service token is required")
			return
		}
		if err := s.Store.TouchSvcToken(c.Prefix, now); err != nil {
			log.Printf("svc: touch %s: %v", c.Prefix, err)
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), svcCallerKey{}, c)))
	})
}

// svcOnly mounts a service route that needs scope ("" = any live token).
// Every call through it is one svc.call audit row, refusals included.
func (s *Server) svcOnly(scope string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, prefix, ok := SvcCallerOf(r.Context())
		target := "route:" + r.Method + " " + r.URL.Path
		if !ok {
			// Mounted outside svcGate: refuse rather than run unauthenticated.
			httpError(w, http.StatusUnauthorized, "a live service token is required")
			return
		}
		if scope != "" && !p.Has(scope) {
			s.svcAudit(p.ID, "svc.call", target, "FORBIDDEN", prefix, time.Now())
			httpError(w, http.StatusForbidden, "this service token lacks the scope "+scope)
			return
		}
		s.svcAudit(p.ID, "svc.call", target, "ok", prefix, time.Now())
		next.ServeHTTP(w, r)
	})
}

// svcMux is the service door's routes: whoami and the runs (svc_runs.go).
func (s *Server) svcMux() http.Handler {
	m := http.NewServeMux()
	m.Handle(SvcWhoamiPath, s.svcOnly("", http.HandlerFunc(s.handleSvcWhoami)))
	s.svcRunsMux(m)
	m.Handle(SvcUsagePath, s.svcOnly(store.SvcRunsRead, http.HandlerFunc(s.handleSvcUsage)))
	return s.svcGate(m)
}

func (s *Server) handleSvcWhoami(w http.ResponseWriter, r *http.Request) {
	p, prefix, _ := SvcCallerOf(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"principal": p.ID, "scopes": p.Scopes, "token": prefix})
}

// svcAudit writes one audit row: fleet_audit, else hub_audit (a database
// without the fleet module — ccquota svc on a bare hub).
func (s *Server) svcAudit(actor, action, target, outcome, detail string, at time.Time) {
	if err := SvcAudit(s.Store, actor, action, target, outcome, detail, at); err != nil {
		log.Printf("svc audit: %v", err)
	}
}

// SvcAudit is svcAudit for a caller holding only the store (ccquota svc).
func SvcAudit(st *store.Store, actor, action, target, outcome, detail string, at time.Time) error {
	if st == nil {
		return nil
	}
	if err := st.FleetAudit(actor, action, target, outcome, detail, at); err == nil {
		return nil
	}
	return st.HubAudit(actor, action, target, outcome, detail, at)
}

// SvcIssue mints a token for principal, stores its hash and audits it. days
// <= 0 = no expiry. The token is returned once and never again.
func SvcIssue(st *store.Store, principal string, days int, actor string, now time.Time) (string, store.SvcToken, error) {
	p, err := st.SvcPrincipal(principal)
	if err != nil {
		return "", store.SvcToken{}, err
	}
	tok, prefix, err := MintSvcToken()
	if err != nil {
		return "", store.SvcToken{}, err
	}
	t := store.SvcToken{Prefix: prefix, SHA256: HashToken(tok), Principal: p.ID, Created: now}
	if days > 0 {
		e := now.Add(time.Duration(days) * 24 * time.Hour).UTC()
		t.Expires = &e
	}
	if err := st.AddSvcToken(t, now); err != nil {
		_ = SvcAudit(st, actor, "svc.token.issue", p.ID, "refused", err.Error(), now)
		return "", store.SvcToken{}, err
	}
	if err := SvcAudit(st, actor, "svc.token.issue", p.ID, "ok", prefix, now); err != nil {
		log.Printf("svc audit: %v", err)
	}
	return tok, t, nil
}

// SvcRevoke stamps a token revoked, audits it and returns the revocation-list
// entry it means (#3560): the caller records it when the list is on.
func SvcRevoke(st *store.Store, prefix, actor, reason string, now time.Time) (store.SvcToken, store.Revocation, error) {
	t, err := st.RevokeSvcToken(strings.TrimSpace(prefix), now)
	if err != nil {
		return t, store.Revocation{}, err
	}
	if err := SvcAudit(st, actor, "svc.token.revoke", t.Principal, "ok", joinDetail(t.Prefix, reason), now); err != nil {
		log.Printf("svc audit: %v", err)
	}
	exp := now.Add(svcDefaultDays * 24 * time.Hour)
	if t.Expires != nil {
		exp = *t.Expires
	}
	return t, store.Revocation{JTI: "fcs:" + t.Prefix, Principal: t.Principal, Exp: exp.Unix(),
		Src: "svc:" + t.Prefix, Reason: joinDetail(reason, "by "+actor)}, nil
}

// SvcSetEnabled switches a principal on or off and audits it; the entry is
// the scope revocation an off writes (Exp 0 for an on, which lifts it).
func SvcSetEnabled(st *store.Store, principal string, on bool, actor string, now time.Time) (store.SvcPrincipal, store.Revocation, error) {
	p, err := st.SetSvcPrincipalEnabled(principal, on)
	if err != nil {
		return p, store.Revocation{}, err
	}
	action := "svc.disable"
	if on {
		action = "svc.enable"
	}
	if err := SvcAudit(st, actor, action, p.ID, "ok", "", now); err != nil {
		log.Printf("svc audit: %v", err)
	}
	if on {
		return p, store.Revocation{Src: "svcp:" + p.ID}, nil
	}
	return p, store.Revocation{Principal: p.ID, Before: now.Unix(), Exp: now.Add(revScopeKeep).Unix(),
		Src: "svcp:" + p.ID, Reason: "disabled by " + actor}, nil
}

// SvcCreate adds a principal and audits it.
func SvcCreate(st *store.Store, name, scopes, actor string, now time.Time) (store.SvcPrincipal, error) {
	sc, err := store.SvcScopesParse(scopes)
	if err != nil {
		return store.SvcPrincipal{}, err
	}
	p, err := st.CreateSvcPrincipal(name, sc, now)
	if err != nil {
		return p, err
	}
	if err := SvcAudit(st, actor, "svc.create", p.ID, "ok", strings.Join(sc, " "), now); err != nil {
		log.Printf("svc audit: %v", err)
	}
	return p, nil
}

// SvcAdminRequest is POST /v1/fleet/svc: one op on a principal or a token.
type SvcAdminRequest struct {
	Op        string `json:"op"` // create | issue | revoke | disable | enable | callback
	Principal string `json:"principal,omitempty"`
	Scopes    string `json:"scopes,omitempty"`
	Days      *int   `json:"days,omitempty"`
	Prefix    string `json:"prefix,omitempty"`
	Reason    string `json:"reason,omitempty"`
	// op callback (claude-fleet#4004): the prefix every run's callback_url
	// must sit under; a secret is minted the first time or with rotate.
	CallbackPrefix string `json:"callback_prefix,omitempty"`
	Rotate         bool   `json:"rotate,omitempty"`
}

// SvcPrincipalView is one principal with its tokens, as GET lists it.
type SvcPrincipalView struct {
	store.SvcPrincipal
	Tokens []store.SvcToken `json:"tokens"`
}

// handleSvcAdmin is the admin's: GET every principal and token (never a
// secret), POST one op. Mounted behind viewerOnly + adminOnly.
func (s *Server) handleSvcAdmin(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	switch r.Method {
	case http.MethodGet:
		ps, err := s.Store.SvcPrincipals()
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := []SvcPrincipalView{}
		for _, p := range ps {
			toks, err := s.Store.SvcTokens(p.ID)
			if err != nil {
				httpError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if toks == nil {
				toks = []store.SvcToken{}
			}
			out = append(out, SvcPrincipalView{SvcPrincipal: p, Tokens: toks})
		}
		writeJSON(w, http.StatusOK, map[string]any{"principals": out, "scopes": store.SvcScopes})
	case http.MethodPost:
		var req SvcAdminRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "malformed request: "+err.Error())
			return
		}
		actor := actorOf(r)
		switch req.Op {
		case "create":
			p, err := SvcCreate(s.Store, req.Principal, req.Scopes, actor, now)
			if err != nil {
				svcAdminError(w, err)
				return
			}
			writeJSON(w, http.StatusCreated, p)
		case "issue":
			days := svcDefaultDays
			if req.Days != nil {
				days = *req.Days
			}
			tok, t, err := SvcIssue(s.Store, req.Principal, days, actor, now)
			if err != nil {
				svcAdminError(w, err)
				return
			}
			writeJSON(w, http.StatusCreated, map[string]any{"token": tok, "prefix": t.Prefix,
				"principal": t.Principal, "expires": t.Expires})
		case "revoke":
			t, e, err := SvcRevoke(s.Store, req.Prefix, actor, req.Reason, now)
			if err != nil {
				svcAdminError(w, err)
				return
			}
			s.revRecord([]store.Revocation{e}, now)
			writeJSON(w, http.StatusOK, t)
		case "disable", "enable":
			p, e, err := SvcSetEnabled(s.Store, req.Principal, req.Op == "enable", actor, now)
			if err != nil {
				svcAdminError(w, err)
				return
			}
			if req.Op == "enable" {
				s.revLift(e.Src)
			} else {
				s.revRecord([]store.Revocation{e}, now)
			}
			writeJSON(w, http.StatusOK, p)
		case "callback":
			secret, c, err := SvcSetCallback(s.Store, req.Principal, req.CallbackPrefix, req.Rotate, actor, now)
			if err != nil {
				svcAdminError(w, err)
				return
			}
			out := map[string]any{"principal": c.Principal, "callback_prefix": c.URLPrefix}
			if secret != "" {
				out["secret"] = secret // shown once
			}
			writeJSON(w, http.StatusOK, out)
		default:
			httpError(w, http.StatusBadRequest, "op is one of create, issue, revoke, disable, enable, callback")
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

func svcAdminError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNoSvcPrincipal), errors.Is(err, store.ErrNoSvcToken):
		httpError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, store.ErrSvcExists), errors.Is(err, store.ErrSvcTokenLimit):
		httpError(w, http.StatusConflict, err.Error())
	default:
		httpError(w, http.StatusBadRequest, err.Error())
	}
}
