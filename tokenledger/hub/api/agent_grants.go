package api

import (
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// 已连接的 Agent (task T4DN): the console's half of the agent door — a person
// lists, connects and revokes their own agents.
//
//	GET  /v1/me/agents          {agents, permissions, mcp_url}
//	POST /v1/me/agents          {name, client, permissions, days} → {agent, key (once), mcp_url, snippets}
//	POST /v1/me/agents/revoke   {id} → {revoked}
//
// A person's own only — an admin included: no one lists or revokes another's.
// The key is shown once and stored as its SHA-256; a lost one is revoked and
// minted again. Only a signed-in person reaches it (the operator's shared door
// is no one, and an agent's own door is /mcp only).
const (
	MeAgentsPath       = "/v1/me/agents"
	MeAgentsRevokePath = "/v1/me/agents/revoke"
)

// agentClients are the agents the console knows how to set up.
var agentClients = map[string]string{
	"claude-code": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI",
	"claude-ai": "claude.ai", "other": "Other",
}

// agentGrantView is a grant as the console shows it.
type agentGrantView struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Client      string     `json:"client"`
	Kind        string     `json:"kind"`
	Permissions []string   `json:"permissions"`
	Scopes      []string   `json:"scopes"`
	CreatedAt   time.Time  `json:"created_at"`
	ExpiresAt   time.Time  `json:"expires_at"`
	LastCallAt  *time.Time `json:"last_call_at"`
	Calls       int64      `json:"calls"`
}

func viewAgentGrant(g store.AgentGrant) agentGrantView {
	v := agentGrantView{ID: g.ID, Name: g.Name, Client: g.Client, Kind: g.Kind,
		Permissions: agentPermissionWords(g.Scopes), Scopes: g.Scopes,
		CreatedAt: g.CreatedAt, ExpiresAt: g.ExpiresAt, Calls: g.Calls}
	if !g.LastCallAt.IsZero() {
		t := g.LastCallAt
		v.LastCallAt = &t
	}
	return v
}

// agentPerson is the signed-in person behind a console request, else a refusal.
func (s *Server) agentPerson(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !s.agentDoorOn() {
		httpError(w, http.StatusNotFound, "this hub runs no fleet module")
		return "", false
	}
	p := principalOf(r.Context())
	if p == "" || doorOf(r.Context()) == doorAgent {
		httpError(w, http.StatusForbidden, "sign in as yourself: an agent is connected by its person")
		return "", false
	}
	if roleOf(r.Context()) == roleTrial {
		httpError(w, http.StatusForbidden, "a trial cannot connect agents")
		return "", false
	}
	return p, true
}

// readJSONBody reads a small JSON object; a form post (what another site can
// send without a preflight) is refused by its content type.
func readJSONBody(w http.ResponseWriter, r *http.Request, v any) bool {
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		httpError(w, http.StatusUnsupportedMediaType, "application/json")
		return false
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<10))
	if err != nil {
		httpError(w, http.StatusRequestEntityTooLarge, "too large")
		return false
	}
	if err := json.Unmarshal(raw, v); err != nil {
		httpError(w, http.StatusBadRequest, "a JSON object")
		return false
	}
	return true
}

func (s *Server) mcpURL(r *http.Request) string { return s.nodeHubURL(r) + "/mcp" }

// agentSnippets are the paste-in setups, one per agent; the key is in the
// environment, never in a file (the snippets say so).
func agentSnippets(mcpURL, key string) map[string]string {
	return map[string]string{
		"claude-code": "claude mcp add --transport http tokenman " + mcpURL +
			" --header 'Authorization: Bearer ${TOKENMAN_TOKEN}'\n# and in your shell: export TOKENMAN_TOKEN=" + key +
			"\n# or, no key: claude mcp add --transport http tokenman " + mcpURL + "  (then sign in with the browser)",
		"codex": "# ~/.codex/config.toml\n[mcp_servers.tokenman]\nurl = \"" + mcpURL + "\"\nbearer_token_env_var = \"TOKENMAN_TOKEN\"\n" +
			"# and in your shell: export TOKENMAN_TOKEN=" + key,
		"gemini": "// ~/.gemini/settings.json\n{\"mcpServers\": {\"tokenman\": {\"httpUrl\": \"" + mcpURL +
			"\", \"headers\": {\"Authorization\": \"Bearer ${TOKENMAN_TOKEN}\"}}}}\n// and in your shell: export TOKENMAN_TOKEN=" + key,
		"generic": "MCP server (Streamable HTTP): " + mcpURL + "\nAuthorization: Bearer " + key,
	}
}

// handleMeAgents serves MeAgentsPath.
func (s *Server) handleMeAgents(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	person, ok := s.agentPerson(w, r)
	if !ok {
		return
	}
	switch r.Method {
	case http.MethodGet:
		gs, err := s.Store.AgentGrants(person, false)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		now := time.Now()
		out := []agentGrantView{}
		for _, g := range gs {
			if g.Live(now) {
				out = append(out, viewAgentGrant(g))
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"agents": out,
			"permissions": agentPermissionOrder, "mcp_url": s.mcpURL(r)})
	case http.MethodPost:
		var in struct {
			Name        string   `json:"name"`
			Client      string   `json:"client"`
			Permissions []string `json:"permissions"`
			Days        int      `json:"days"`
		}
		if !readJSONBody(w, r, &in) {
			return
		}
		if _, ok := agentClients[in.Client]; !ok {
			in.Client = "other"
		}
		in.Name = oneLine(strings.TrimSpace(in.Name))
		if in.Name == "" {
			in.Name = agentClients[in.Client]
		}
		if utf8.RuneCountInString(in.Name) > 64 {
			httpError(w, http.StatusBadRequest, "name: at most 64 characters")
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
		key, err := agentSecret(agentKeyPrefix)
		if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		now := time.Now().UTC()
		g := store.AgentGrant{ID: agentID(), Person: person, Name: in.Name, Client: in.Client,
			Kind: store.AgentGrantPAT, Scopes: scopes, CreatedAt: now, ExpiresAt: now.Add(ttl)}
		if err := s.Store.AddAgentGrant(g, HashToken(key)); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		_ = s.Store.HubAudit(person, "agent_connect", g.ID, "ok",
			g.Name+" · "+strings.Join(scopes, " ")+" · until "+g.ExpiresAt.Format(time.RFC3339), now)
		writeJSON(w, http.StatusCreated, map[string]any{"agent": viewAgentGrant(g), "key": key,
			"mcp_url": s.mcpURL(r), "snippets": agentSnippets(s.mcpURL(r), key)})
	default:
		w.Header().Set("Allow", "GET, POST")
		httpError(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

// agentGrantTTL is a requested life in days: 0 the default, at most a year.
func agentGrantTTL(days int) (time.Duration, error) {
	if days == 0 {
		return agentGrantDefaultTTL, nil
	}
	if days < 1 || time.Duration(days)*24*time.Hour > agentGrantMaxTTL {
		return 0, errBadDays
	}
	return time.Duration(days) * 24 * time.Hour, nil
}

var errBadDays = &agentErr{"days: 1 to 365"}

type agentErr struct{ msg string }

func (e *agentErr) Error() string { return e.msg }

// handleMeAgentsRevoke serves MeAgentsRevokePath.
func (s *Server) handleMeAgentsRevoke(w http.ResponseWriter, r *http.Request) {
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
		ID string `json:"id"`
	}
	if !readJSONBody(w, r, &in) {
		return
	}
	now := time.Now()
	done, err := s.Store.RevokeAgentGrant(person, strings.TrimSpace(in.ID), now)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !done {
		httpError(w, http.StatusNotFound, "no such connected agent of yours")
		return
	}
	_ = s.Store.HubAudit(person, "agent_revoke", in.ID, "ok", "", now)
	writeJSON(w, http.StatusOK, map[string]any{"revoked": true})
}
