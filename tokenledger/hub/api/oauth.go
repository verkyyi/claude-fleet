package api

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// The hub as its own OAuth authorization server for /mcp (task T4DN), per the
// MCP authorization spec (revision 2026-07-28): a person's agent finds where to
// sign in from /mcp's 401 (resource_metadata), signs the person in with the
// hub's own sign-in (GitHub / WeChat / mail), shows them what it asks on a
// consent page, and gets tokens that resolve to ONE agent grant — the same row a
// personal key is, so the console lists, and revokes, both alike.
//
//	GET  /.well-known/oauth-protected-resource[/mcp]   RFC 9728
//	GET  /.well-known/oauth-authorization-server       RFC 8414
//	POST /oauth/register                               RFC 7591 (DCR, public clients)
//	GET  /oauth/authorize                              checks the client, then the console's consent page
//	GET  /v1/me/oauth/request?<authorize query>        what the consent page shows
//	POST /v1/me/oauth/approve                          the person's answer → the redirect
//	POST /oauth/token                                  authorization_code (PKCE S256) · refresh_token (rotated)
//
// Clients: a Client ID Metadata Document (an https URL as client_id — what
// claude.ai prefers) fetched with no redirect, no private address, ≤64 KB, kept
// a day; or a registered client (DCR, what Codex and Gemini CLI use). Every
// client is public (no secret): PKCE S256 is required, the redirect must match
// exactly — a loopback one with its port ignored (a CLI picks a free port) — and
// the authorization response carries iss (RFC 9207). A refresh token works once;
// presenting a spent one revokes the whole grant (a replay means it leaked).
const (
	protectedResourcePath = "/.well-known/oauth-protected-resource"
	authServerMetaPath    = "/.well-known/oauth-authorization-server"
	OAuthRegisterPath     = "/oauth/register"
	OAuthAuthorizePath    = "/oauth/authorize"
	OAuthTokenPath        = "/oauth/token"
	MeOAuthRequestPath    = "/v1/me/oauth/request"
	MeOAuthApprovePath    = "/v1/me/oauth/approve"
	// oauthConsentPage is the console page the authorize step hands the browser to.
	oauthConsentPage = "/oauth/authorize"
	oauthCodeTTL     = 10 * time.Minute
	cimdTTL          = 24 * time.Hour
	cimdMaxBytes     = 64 << 10
)

// oauthDefaultPermissions are what a client that asks for nothing recognisable gets offered.
var oauthDefaultPermissions = []string{"read", "talk"}

func (s *Server) oauthIssuer(r *http.Request) string { return s.nodeHubURL(r) }

func oauthCORS(w http.ResponseWriter, r *http.Request) bool {
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", "*")
	h.Set("Access-Control-Allow-Headers", "Content-Type, Authorization, Mcp-Protocol-Version")
	h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return true
	}
	return false
}

func oauthScopesSupported() []string {
	out := append([]string{}, agentPermissionOrder...)
	seen := map[string]bool{}
	for _, w := range agentPermissionOrder {
		for _, x := range agentPermissions[w] {
			if !seen[x] {
				seen[x] = true
				out = append(out, x)
			}
		}
	}
	return out
}

// handleProtectedResource serves the RFC 9728 metadata for /mcp.
func (s *Server) handleProtectedResource(w http.ResponseWriter, r *http.Request) {
	if oauthCORS(w, r) {
		return
	}
	if !s.agentDoorOn() {
		http.NotFound(w, r)
		return
	}
	base := s.oauthIssuer(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"resource":                 base + "/mcp",
		"authorization_servers":    []string{base},
		"scopes_supported":         oauthScopesSupported(),
		"bearer_methods_supported": []string{"header"},
		"resource_name":            "Tokenman",
	})
}

// handleAuthServerMeta serves the RFC 8414 metadata.
func (s *Server) handleAuthServerMeta(w http.ResponseWriter, r *http.Request) {
	if oauthCORS(w, r) {
		return
	}
	if !s.agentDoorOn() {
		http.NotFound(w, r)
		return
	}
	base := s.oauthIssuer(r)
	writeJSON(w, http.StatusOK, map[string]any{
		"issuer":                                           base,
		"authorization_endpoint":                           base + OAuthAuthorizePath,
		"token_endpoint":                                   base + OAuthTokenPath,
		"registration_endpoint":                            base + OAuthRegisterPath,
		"response_types_supported":                         []string{"code"},
		"grant_types_supported":                            []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":                 []string{"S256"},
		"token_endpoint_auth_methods_supported":            []string{"none", privateKeyJWT},
		"token_endpoint_auth_signing_alg_values_supported": []string{"RS256"},
		"scopes_supported":                                 oauthScopesSupported(),
		"client_id_metadata_document_supported":            true,
		"authorization_response_iss_parameter_supported":   true,
	})
}

func oauthError(w http.ResponseWriter, status int, code, desc string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]string{"error": code, "error_description": desc})
}

// --- clients -----------------------------------------------------------------

func isLoopbackHost(h string) bool {
	return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
}

// redirectAllowed says whether a client may register uri: https anywhere, or
// http to a loopback address (a CLI's local callback). Nothing else — no
// custom scheme, no fragment, no userinfo.
func redirectAllowed(uri string) bool {
	u, err := url.Parse(uri)
	if err != nil || u.Fragment != "" || u.User != nil || u.Host == "" || len(uri) > 512 {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		return isLoopbackHost(u.Hostname())
	}
	return false
}

// redirectMatches compares the redirect an authorize request names with one
// the client registered: exactly, except a loopback one's port (RFC 8252 §7.3).
func redirectMatches(registered, asked string) bool {
	if registered == asked {
		return true
	}
	a, err1 := url.Parse(registered)
	b, err2 := url.Parse(asked)
	if err1 != nil || err2 != nil || a.Scheme != "http" || b.Scheme != "http" {
		return false
	}
	if !isLoopbackHost(a.Hostname()) || a.Hostname() != b.Hostname() {
		return false
	}
	return a.Path == b.Path && a.RawQuery == b.RawQuery && b.Fragment == "" && b.User == nil
}

// handleOAuthRegister serves dynamic client registration for public clients.
func (s *Server) handleOAuthRegister(w http.ResponseWriter, r *http.Request) {
	if oauthCORS(w, r) {
		return
	}
	if !s.agentDoorOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		oauthError(w, http.StatusMethodNotAllowed, "invalid_request", "POST")
		return
	}
	var in struct {
		RedirectURIs []string `json:"redirect_uris"`
		ClientName   string   `json:"client_name"`
		AuthMethod   string   `json:"token_endpoint_auth_method"`
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil || json.Unmarshal(raw, &in) != nil {
		oauthError(w, http.StatusBadRequest, "invalid_client_metadata", "a JSON client metadata object")
		return
	}
	if len(in.RedirectURIs) == 0 || len(in.RedirectURIs) > 10 {
		oauthError(w, http.StatusBadRequest, "invalid_redirect_uri", "1 to 10 redirect_uris")
		return
	}
	for _, u := range in.RedirectURIs {
		if !redirectAllowed(u) {
			oauthError(w, http.StatusBadRequest, "invalid_redirect_uri", "https, or http to a loopback address: "+u)
			return
		}
	}
	name := oneLine(in.ClientName)
	if utf8.RuneCountInString(name) > 100 {
		name = string([]rune(name)[:100])
	}
	c := store.OAuthClient{ClientID: "tmc_" + agentID(), Kind: "dcr", Name: name,
		RedirectURIs: in.RedirectURIs, CreatedAt: time.Now().UTC()}
	if err := s.Store.PutOAuthClient(c); err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"client_id": c.ClientID, "client_id_issued_at": c.CreatedAt.Unix(),
		"client_name": c.Name, "redirect_uris": c.RedirectURIs,
		"token_endpoint_auth_method": "none",
		"grant_types":                []string{"authorization_code", "refresh_token"},
		"response_types":             []string{"code"},
	})
}

// isCIMD says whether a client_id is a metadata document's URL.
func isCIMD(id string) bool {
	u, err := url.Parse(id)
	return err == nil && u.Scheme == "https" && u.Host != "" && u.Path != "" && u.Path != "/" &&
		u.Fragment == "" && u.User == nil && len(id) <= 512
}

// cimdFetch is how a metadata document is fetched; a test swaps it.
var cimdFetch = fetchCIMD

// publicDialer refuses every address that is not on the public internet, so a
// client_id can never make the hub reach into its own network.
var publicDialer = &net.Dialer{Timeout: 5 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast() ||
		(ip.To4() != nil && ip.To4()[0] == 100 && ip.To4()[1]&0xc0 == 64) { // 100.64/10 (CGNAT, tailnets)
		return fmt.Errorf("not a public address: %s", host)
	}
	return nil
}}

var cimdClient = &http.Client{
	Timeout:       8 * time.Second,
	Transport:     &http.Transport{DialContext: publicDialer.DialContext, TLSHandshakeTimeout: 5 * time.Second},
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func fetchCIMD(ctx context.Context, id string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, id, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := cimdClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("metadata document answered %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, cimdMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(b) > cimdMaxBytes {
		return nil, errors.New("metadata document over 64 KB")
	}
	return b, nil
}

// cimdLocks keeps two authorize requests from fetching one document at once.
var cimdLocks sync.Map

// oauthClient finds a client: a registered one, or a metadata document
// (fetched, checked and kept a day).
func (s *Server) oauthClient(ctx context.Context, id string) (store.OAuthClient, error) {
	if id == "" {
		return store.OAuthClient{}, errors.New("client_id is required")
	}
	c, err := s.Store.OAuthClient(id)
	if err == nil && (c.Kind != "cimd" || time.Since(c.CreatedAt) < cimdTTL) {
		return c, nil
	}
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return c, err
	}
	if !isCIMD(id) {
		return c, errors.New("unknown client_id: register it first (" + OAuthRegisterPath + ")")
	}
	mu, _ := cimdLocks.LoadOrStore(id, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	defer mu.(*sync.Mutex).Unlock()
	doc, err := cimdDocument(ctx, id, true)
	if err != nil {
		return c, err
	}
	if !cimdPublicOK(doc.AuthMethod, doc.AuthMethods) {
		return c, errors.New("the client metadata document must use token_endpoint_auth_method none or private_key_jwt")
	}
	if len(doc.RedirectURIs) == 0 || len(doc.RedirectURIs) > 10 {
		return c, errors.New("client metadata document needs 1 to 10 redirect_uris")
	}
	for _, u := range doc.RedirectURIs {
		if !redirectAllowed(u) {
			return c, errors.New("redirect_uri not allowed: " + u)
		}
	}
	c = store.OAuthClient{ClientID: id, Kind: "cimd", Name: oneLine(doc.ClientName),
		RedirectURIs: doc.RedirectURIs, CreatedAt: time.Now().UTC()}
	if utf8.RuneCountInString(c.Name) > 100 {
		c.Name = string([]rune(c.Name)[:100])
	}
	return c, s.Store.PutOAuthClient(c)
}

// cimdDoc is the part of a Client ID Metadata Document the hub reads.
type cimdDoc struct {
	ClientID     string          `json:"client_id"`
	ClientName   string          `json:"client_name"`
	RedirectURIs []string        `json:"redirect_uris"`
	AuthMethod   string          `json:"token_endpoint_auth_method"`
	AuthMethods  []string        `json:"token_endpoint_auth_methods_supported"`
	JWKSURI      string          `json:"jwks_uri"`
	JWKS         json.RawMessage `json:"jwks"`
}

// cimdDocTTL is how long a fetched document answers the token endpoint from
// memory: a sign-in reads it at the authorize step and again at the token one.
const cimdDocTTL = 10 * time.Minute

type cimdDocEntry struct {
	doc cimdDoc
	at  time.Time
}

var cimdDocs sync.Map // client_id → cimdDocEntry

// cimdDocument fetches (or, unless fresh, recalls) and checks a client's
// metadata document: JSON naming its own URL as client_id.
func cimdDocument(ctx context.Context, id string, fresh bool) (cimdDoc, error) {
	if e, ok := cimdDocs.Load(id); ok && !fresh && time.Since(e.(cimdDocEntry).at) < cimdDocTTL {
		return e.(cimdDocEntry).doc, nil
	}
	raw, err := cimdFetch(ctx, id)
	if err != nil {
		return cimdDoc{}, fmt.Errorf("client metadata document: %v", err)
	}
	var doc cimdDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		return doc, errors.New("client metadata document is not JSON")
	}
	if doc.ClientID != id {
		return doc, errors.New("client metadata document names another client_id")
	}
	cimdDocs.Store(id, cimdDocEntry{doc, time.Now()})
	return doc, nil
}

// cimdPublicOK says whether a metadata document's client may sign in here at
// all: it uses no client authentication, or private_key_jwt (verified against
// its own published keys — clientAuth), or lists none among what it supports.
// ChatGPT's document prefers private_key_jwt and lists ["none",
// "private_key_jwt"] (task T4DN). A client_secret method is refused: a
// metadata document has no secret.
func cimdPublicOK(method string, supported []string) bool {
	if method == "" || method == "none" || method == privateKeyJWT {
		return true
	}
	for _, m := range supported {
		if m == "none" {
			return true
		}
	}
	return false
}

// clientHost is what the consent page names a client by besides its own name.
func clientHost(c store.OAuthClient) string {
	if u, err := url.Parse(c.ClientID); err == nil && c.Kind == "cimd" {
		return u.Host
	}
	for _, r := range c.RedirectURIs {
		if u, err := url.Parse(r); err == nil {
			return u.Host
		}
	}
	return ""
}

// clientKind guesses the console's agent label from a client's name and host.
func clientKind(c store.OAuthClient) string {
	n := strings.ToLower(c.Name + " " + clientHost(c))
	switch {
	case strings.Contains(n, "claude.ai") || strings.Contains(n, "claude.com"):
		return "claude-ai"
	case strings.Contains(n, "claude"):
		return "claude-code"
	case strings.Contains(n, "codex"):
		return "codex"
	case strings.Contains(n, "gemini"):
		return "gemini"
	}
	return "other"
}

// --- authorize -----------------------------------------------------------------

// authzRequest is one checked authorization request.
type authzRequest struct {
	client      store.OAuthClient
	redirectURI string
	state       string
	challenge   string
	resource    string
	permissions []string
}

// checkAuthorize checks an authorize query. redirectOK says the redirect is
// the client's own, so an error may be sent back to it; otherwise the error
// is shown to the person and the browser goes nowhere.
func (s *Server) checkAuthorize(r *http.Request, q url.Values) (a authzRequest, redirectOK bool, code, desc string) {
	c, err := s.oauthClient(r.Context(), q.Get("client_id"))
	if err != nil {
		return a, false, "invalid_client", err.Error()
	}
	a.client = c
	ru := q.Get("redirect_uri")
	if ru == "" && len(c.RedirectURIs) == 1 {
		ru = c.RedirectURIs[0]
	}
	ok := false
	for _, reg := range c.RedirectURIs {
		if redirectMatches(reg, ru) {
			ok = true
			break
		}
	}
	if !ok {
		return a, false, "invalid_request", "redirect_uri is not one this client registered"
	}
	a.redirectURI, a.state = ru, q.Get("state")
	if q.Get("response_type") != "code" {
		return a, true, "unsupported_response_type", "response_type must be code"
	}
	a.challenge = q.Get("code_challenge")
	if q.Get("code_challenge_method") != "S256" || len(a.challenge) < 43 || len(a.challenge) > 128 {
		return a, true, "invalid_request", "PKCE is required: code_challenge with code_challenge_method S256"
	}
	if res := q.Get("resource"); res != "" {
		base := s.oauthIssuer(r)
		if strings.TrimRight(res, "/") != base+"/mcp" && strings.TrimRight(res, "/") != base {
			return a, true, "invalid_target", "this server only issues tokens for " + base + "/mcp"
		}
		a.resource = res
	}
	for _, w := range strings.Fields(q.Get("scope")) {
		if _, ok := agentPermissions[w]; ok && !hasString(a.permissions, w) {
			a.permissions = append(a.permissions, w)
			continue
		}
		for _, pw := range agentPermissionOrder {
			if hasString(agentPermissions[pw], w) && !hasString(a.permissions, pw) {
				a.permissions = append(a.permissions, pw)
			}
		}
	}
	if len(a.permissions) == 0 {
		a.permissions = append([]string{}, oauthDefaultPermissions...)
	}
	if !hasString(a.permissions, "read") {
		a.permissions = append([]string{"read"}, a.permissions...)
	}
	return a, true, "", ""
}

// authzRedirect is the client's redirect with the given parameters, iss always.
func (s *Server) authzRedirect(r *http.Request, a authzRequest, params url.Values) string {
	u, _ := url.Parse(a.redirectURI)
	q := u.Query()
	for k, v := range params {
		q[k] = v
	}
	if a.state != "" {
		q.Set("state", a.state)
	}
	q.Set("iss", s.oauthIssuer(r))
	u.RawQuery = q.Encode()
	return u.String()
}

// handleOAuthAuthorize checks the client and hands the browser to the
// console's consent page (which signs the person in first when needed).
func (s *Server) handleOAuthAuthorize(w http.ResponseWriter, r *http.Request) {
	if !s.agentDoorOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		httpError(w, http.StatusMethodNotAllowed, "GET")
		return
	}
	a, redirectOK, code, desc := s.checkAuthorize(r, r.URL.Query())
	if code != "" {
		if redirectOK {
			http.Redirect(w, r, s.authzRedirect(r, a, url.Values{"error": {code}, "error_description": {desc}}), http.StatusFound)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprintf(w, "Tokenman could not start this sign-in: %s (%s)\n", desc, code)
		return
	}
	// re-encoded: a client may send its URLs raw, and the sign-in only carries
	// a clean address back (appReturnOK)
	http.Redirect(w, r, appURL(oauthConsentPage)+"?"+r.URL.Query().Encode(), http.StatusFound)
}

// handleMeOAuthRequest is what the consent page shows.
func (s *Server) handleMeOAuthRequest(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if _, ok := s.agentPerson(w, r); !ok {
		return
	}
	a, _, code, desc := s.checkAuthorize(r, r.URL.Query())
	if code != "" {
		oauthError(w, http.StatusBadRequest, code, desc)
		return
	}
	name := a.client.Name
	if name == "" {
		name = clientHost(a.client)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"client":          map[string]string{"id": a.client.ClientID, "name": name, "kind": a.client.Kind, "host": clientHost(a.client)},
		"redirect_uri":    a.redirectURI,
		"permissions":     a.permissions,
		"all_permissions": agentPermissionOrder,
		"days":            int(agentGrantDefaultTTL / (24 * time.Hour)),
	})
}

// handleMeOAuthApprove takes the person's answer and mints the code.
func (s *Server) handleMeOAuthApprove(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpError(w, http.StatusMethodNotAllowed, "POST")
		return
	}
	person, ok := s.agentPerson(w, r)
	if !ok {
		return
	}
	var in struct {
		Query       string   `json:"query"`
		Permissions []string `json:"permissions"`
		Days        int      `json:"days"`
		Approve     bool     `json:"approve"`
	}
	if !readJSONBody(w, r, &in) {
		return
	}
	q, err := url.ParseQuery(strings.TrimPrefix(in.Query, "?"))
	if err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "query")
		return
	}
	a, redirectOK, code, desc := s.checkAuthorize(r, q)
	if code != "" {
		if !redirectOK {
			oauthError(w, http.StatusBadRequest, code, desc)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"redirect": s.authzRedirect(r, a, url.Values{"error": {code}, "error_description": {desc}})})
		return
	}
	now := time.Now().UTC()
	if !in.Approve {
		_ = s.Store.HubAudit(person, "agent_oauth_deny", a.client.ClientID, "ok", "", now)
		writeJSON(w, http.StatusOK, map[string]string{"redirect": s.authzRedirect(r, a, url.Values{"error": {"access_denied"}})})
		return
	}
	scopes, err := agentScopes(in.Permissions)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	ttl, err := agentGrantTTL(in.Days)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	codeTok, err := randomToken(32)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.Store.PutOAuthCode(HashToken(codeTok), store.OAuthCode{ClientID: a.client.ClientID, Person: person,
		Scopes: scopes, RedirectURI: a.redirectURI, Challenge: a.challenge, Resource: a.resource,
		TTLHours: int(ttl / time.Hour), ExpiresAt: now.Add(oauthCodeTTL)}); err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	_ = s.Store.PruneOAuth(now)
	writeJSON(w, http.StatusOK, map[string]string{"redirect": s.authzRedirect(r, a, url.Values{"code": {codeTok}})})
}

// --- token -------------------------------------------------------------------

func pkceS256(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// issueAgentTokens mints an access + refresh pair for a grant.
func (s *Server) issueAgentTokens(w http.ResponseWriter, g store.AgentGrant, now time.Time) {
	access, err1 := agentSecret(agentAccessPrefix)
	refresh, err2 := agentSecret(agentRefreshPrefix)
	if err1 != nil || err2 != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", "could not mint a token")
		return
	}
	accessExp := now.Add(agentAccessTTL)
	if g.ExpiresAt.Before(accessExp) {
		accessExp = g.ExpiresAt
	}
	if err := s.Store.PutOAuthToken(HashToken(access), g.ID, "access", accessExp); err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", err.Error())
		return
	}
	if err := s.Store.PutOAuthToken(HashToken(refresh), g.ID, "refresh", g.ExpiresAt); err != nil {
		oauthError(w, http.StatusInternalServerError, "server_error", err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token": access, "token_type": "Bearer",
		"expires_in":    int(accessExp.Sub(now).Seconds()),
		"refresh_token": refresh, "scope": strings.Join(g.Scopes, " "),
	})
}

// handleOAuthToken serves the token endpoint.
func (s *Server) handleOAuthToken(w http.ResponseWriter, r *http.Request) {
	if oauthCORS(w, r) {
		return
	}
	if !s.agentDoorOn() {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		oauthError(w, http.StatusMethodNotAllowed, "invalid_request", "POST")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := r.ParseForm(); err != nil {
		oauthError(w, http.StatusBadRequest, "invalid_request", "a form-encoded body")
		return
	}
	now := time.Now().UTC()
	clientID, err := s.clientAuth(r, now)
	if err != nil {
		oauthError(w, http.StatusUnauthorized, "invalid_client", err.Error())
		return
	}
	switch r.PostForm.Get("grant_type") {
	case "authorization_code":
		c, err := s.Store.TakeOAuthCode(HashToken(r.PostForm.Get("code")), now)
		if err != nil {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "authorization code unknown, expired or already used")
			return
		}
		if c.ClientID != clientID {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "the code was issued to another client")
			return
		}
		if ru := r.PostForm.Get("redirect_uri"); ru != "" && ru != c.RedirectURI {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "redirect_uri differs from the authorization request")
			return
		}
		v := r.PostForm.Get("code_verifier")
		if len(v) < 43 || len(v) > 128 || !constantTimeEqual(pkceS256(v), c.Challenge) {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "code_verifier does not match")
			return
		}
		role, err := s.personRole(c.Person)
		if err != nil || role == "" || role == roleTrial {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "the person who approved is no longer on the list")
			return
		}
		cl, _ := s.Store.OAuthClient(c.ClientID)
		name := cl.Name
		if name == "" {
			name = clientHost(cl)
		}
		if name == "" {
			name = "OAuth client"
		}
		ttl := time.Duration(c.TTLHours) * time.Hour
		if ttl <= 0 || ttl > agentGrantMaxTTL {
			ttl = agentGrantDefaultTTL
		}
		g := store.AgentGrant{ID: agentID(), Person: c.Person, Name: name, Client: clientKind(cl),
			Kind: store.AgentGrantOAuth, ClientID: c.ClientID, Scopes: c.Scopes, CreatedAt: now, ExpiresAt: now.Add(ttl)}
		if err := s.Store.AddAgentGrant(g, ""); err != nil {
			oauthError(w, http.StatusInternalServerError, "server_error", err.Error())
			return
		}
		_ = s.Store.HubAudit(c.Person, "agent_connect", g.ID, "ok",
			"oauth "+c.ClientID+" · "+strings.Join(g.Scopes, " ")+" · until "+g.ExpiresAt.Format(time.RFC3339), now)
		s.issueAgentTokens(w, g, now)
	case "refresh_token":
		tok := r.PostForm.Get("refresh_token")
		h := HashToken(tok)
		gid, kind, exp, used, err := s.Store.OAuthToken(h)
		if err != nil || kind != "refresh" || !strings.HasPrefix(tok, agentRefreshPrefix) {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "unknown refresh token")
			return
		}
		g, err := s.Store.AgentGrant(gid)
		if err != nil || g.ClientID != clientID {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "the refresh token belongs to another client")
			return
		}
		if !used.IsZero() {
			// A spent refresh token presented again: someone else holds a copy.
			// The whole connection goes; its person reconnects.
			_, _ = s.Store.RevokeAgentGrant(g.Person, g.ID, now)
			_ = s.Store.HubAudit(g.Person, "agent_revoke", g.ID, "refused", "refresh token replayed", now)
			oauthError(w, http.StatusBadRequest, "invalid_grant", "refresh token already used; the connection was revoked")
			return
		}
		if !g.Live(now) || !now.Before(exp) {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "the connection expired or was revoked")
			return
		}
		if ok, err := s.Store.SpendOAuthRefresh(h, now); err != nil || !ok {
			oauthError(w, http.StatusBadRequest, "invalid_grant", "refresh token already used")
			return
		}
		s.issueAgentTokens(w, g, now)
	default:
		oauthError(w, http.StatusBadRequest, "unsupported_grant_type", "authorization_code or refresh_token")
	}
}
