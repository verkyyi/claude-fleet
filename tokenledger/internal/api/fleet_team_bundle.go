package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The team configuration (claude-fleet#1726, EPIC #1718 C8).
//
// One layer between the fleet's defaults (conf/agent-defaults/, shipped with
// the install) and what a login wrote itself: every computer composes
// default < team < local, and local always wins — the client's
// bin/fleet-agent-team.py does the composing, this file only keeps the layer.
//
//   GET  /v1/fleet/team-bundle[?version=N][&history=1]
//        any door: the operator's viewer token / tailnet, a person's session,
//        a node's enrollment token (Bearer). POST {cert, sig, ts} is the same
//        read for a client-only computer, by its connection certificate.
//        ETag "team-v<N>"; If-None-Match answers 304.
//   PUT  {bundle, base?, note?} | {restore: N, base?, note?}
//        the operator's only — a person's session, a node token or a
//        certificate is 403. Every PUT is a new version (prev = the one it
//        replaced); a rollback is a PUT of an earlier version's body, which
//        {restore: N} spells for you. base, when sent, must be the current
//        version (409 otherwise), so two edits never silently overwrite.
//
// The body is an allow-list (teamBundleKeys), and a credential never enters
// it: a credential-shaped key with a literal value, or a value shaped like a
// known token, is refused with 422 before anything is stored. The client
// re-checks the same rules before it applies a byte.

const teamBundleMax = 256 << 10

// teamBundleKeys is the whole allow-list: what a team may hand its computers.
var teamBundleKeys = map[string]bool{
	"mcp":             true, // {name: server} → ~/.claude.json mcpServers + every $CODEX_HOME [mcp_servers.<name>]
	"hooks":           true, // {Event: [{matcher?, command, timeout?}]} → ~/.claude/settings.json hooks
	"skills":          true, // {name: "SKILL.md text"} → ~/.claude/skills + $CODEX_HOME/skills
	"claude_settings": true, // {key: value} → ~/.claude/settings.json top-level keys
	"codex_config":    true, // {key: scalar | [scalar]} → $CODEX_HOME/config.toml top-level keys
}

var (
	teamNameRE   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	teamSkillRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
	teamKeyRE    = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_-]{0,63}$`)
	teamHookEvts = map[string]bool{"PreToolUse": true, "PostToolUse": true, "UserPromptSubmit": true,
		"Stop": true, "SubagentStop": true, "SessionStart": true, "SessionEnd": true,
		"Notification": true, "PreCompact": true}
	// keys a team never sets: the login's model, and the settings that hand
	// Claude Code a credential.
	teamClaudeDenied = map[string]bool{"model": true, "hooks": true, "apiKeyHelper": true,
		"awsAuthRefresh": true, "awsCredentialExport": true, "otelHeadersHelper": true}
	teamCodexDenied = map[string]bool{"model": true, "mcp_servers": true, "model_providers": true}

	// A key that names a credential: its value must be empty or a reference
	// (${VAR} / $VAR), never the thing itself.
	secretKeyRE = regexp.MustCompile(`(?i)(token|secret|passw(or)?d|api[_-]?key|credential|private[_-]?key|authorization|(^|[_-])auth($|[_-])|cookie|session[_-]?key)`)
	secretRefRE = regexp.MustCompile(`^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$`)
	// A value shaped like a known credential, wherever it sits.
	secretValREs = []*regexp.Regexp{
		regexp.MustCompile(`sk-ant-[A-Za-z0-9_-]{8,}`),
		regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{20,}`),
		regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}`),
		regexp.MustCompile(`\bgithub_pat_[A-Za-z0-9_]{20,}`),
		regexp.MustCompile(`\bglpat-[A-Za-z0-9_-]{20,}`),
		regexp.MustCompile(`\bxox[abprs]-[A-Za-z0-9-]{10,}`),
		regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`),
		regexp.MustCompile(`\bAIza[0-9A-Za-z_-]{30,}`),
		regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`),
		regexp.MustCompile(`(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}`),
		regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}`),
	}
)

// validateTeamBundle checks a body against the allow-list and the
// no-credential rule, and returns it re-encoded with sorted keys (the stored
// text). The error is the one line the operator reads.
func validateTeamBundle(raw json.RawMessage) (string, error) {
	return validateBundle(raw, false)
}

// personHookScriptMax is one hook_scripts program's cap; together they still
// sit under the bundle's 256 KiB (claude-fleet#1859).
const personHookScriptMax = 32 << 10

var personScriptRE = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

// validateBundle is validateTeamBundle for either layer: a person's layer
// (claude-fleet#1856) takes the same allow-list plus hook_scripts — the
// programs their own hooks run — and the same credential scan over all of it.
func validateBundle(raw json.RawMessage, personal bool) (string, error) {
	var b map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&b); err != nil || b == nil {
		return "", errors.New("bundle must be a JSON object")
	}
	for k := range b {
		if personal && k == "hook_scripts" {
			continue
		}
		if !teamBundleKeys[k] {
			if personal {
				return "", fmt.Errorf("bundle: %q is not part of a personal configuration (only mcp, hooks, skills, claude_settings, codex_config, hook_scripts)", k)
			}
			return "", fmt.Errorf("bundle: %q is not something a team hands out (only mcp, hooks, skills, claude_settings, codex_config)", k)
		}
	}
	var all map[string]any
	dec = json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&all)
	obj := func(k string) (map[string]any, error) {
		v, ok := all[k]
		if !ok {
			return nil, nil
		}
		m, ok := v.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("bundle.%s must be an object", k)
		}
		return m, nil
	}
	mcp, err := obj("mcp")
	if err != nil {
		return "", err
	}
	for n, v := range mcp {
		srv, ok := v.(map[string]any)
		if !teamNameRE.MatchString(n) || !ok {
			return "", fmt.Errorf("bundle.mcp.%s: a server is a name [A-Za-z0-9_-] and an object", n)
		}
		cmd, _ := srv["command"].(string)
		url, _ := srv["url"].(string)
		if cmd == "" && url == "" {
			return "", fmt.Errorf("bundle.mcp.%s needs a command or a url", n)
		}
	}
	hooks, err := obj("hooks")
	if err != nil {
		return "", err
	}
	for ev, v := range hooks {
		if !teamHookEvts[ev] {
			return "", fmt.Errorf("bundle.hooks.%s is not a Claude Code hook event", ev)
		}
		list, ok := v.([]any)
		if !ok {
			return "", fmt.Errorf("bundle.hooks.%s must be a list of {matcher?, command, timeout?}", ev)
		}
		for i, e := range list {
			h, ok := e.(map[string]any)
			cmd, _ := h["command"].(string)
			if !ok || strings.TrimSpace(cmd) == "" {
				return "", fmt.Errorf("bundle.hooks.%s[%d] needs a command", ev, i)
			}
			for k := range h {
				if k != "matcher" && k != "command" && k != "timeout" {
					return "", fmt.Errorf("bundle.hooks.%s[%d]: %q is not a hook field (matcher, command, timeout)", ev, i, k)
				}
			}
		}
	}
	skills, err := obj("skills")
	if err != nil {
		return "", err
	}
	for n, v := range skills {
		txt, ok := v.(string)
		if !teamSkillRE.MatchString(n) || !ok || strings.TrimSpace(txt) == "" {
			return "", fmt.Errorf("bundle.skills.%s: a skill is a name [a-z0-9-] and its SKILL.md text", n)
		}
	}
	cs, err := obj("claude_settings")
	if err != nil {
		return "", err
	}
	for k := range cs {
		if teamClaudeDenied[k] || !teamKeyRE.MatchString(k) {
			return "", fmt.Errorf("bundle.claude_settings.%s is never handed out (model and credential helpers stay the login's; hooks go in bundle.hooks)", k)
		}
	}
	cc, err := obj("codex_config")
	if err != nil {
		return "", err
	}
	for k, v := range cc {
		if teamCodexDenied[k] || !teamKeyRE.MatchString(k) {
			return "", fmt.Errorf("bundle.codex_config.%s is never handed out (model stays the login's; servers go in bundle.mcp)", k)
		}
		if !teamScalar(v) {
			if l, ok := v.([]any); !ok || !allScalar(l) {
				return "", fmt.Errorf("bundle.codex_config.%s must be a string, number, boolean or a list of them", k)
			}
		}
	}
	scripts, err := obj("hook_scripts")
	if err != nil {
		return "", err
	}
	for n, v := range scripts {
		txt, ok := v.(string)
		if !personScriptRE.MatchString(n) || !ok || strings.TrimSpace(txt) == "" {
			return "", fmt.Errorf("bundle.hook_scripts.%s: a program is a name [a-z0-9._-] and its full text", n)
		}
		if len(txt) > personHookScriptMax {
			return "", fmt.Errorf("bundle.hook_scripts.%s is over 32 KiB", n)
		}
	}
	if path := secretIn("bundle", all); path != "" {
		layer := "the team layer"
		if personal {
			layer = "a personal configuration"
		}
		return "", fmt.Errorf("%s looks like a credential — %s never carries one (write a ${VAR} reference; tokens are read on each computer at start)", path, layer)
	}
	out, err := json.Marshal(all) // map keys sort: one body, one text
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func teamScalar(v any) bool {
	switch v.(type) {
	case string, bool, json.Number:
		return true
	}
	return false
}

func allScalar(l []any) bool {
	for _, x := range l {
		if !teamScalar(x) {
			return false
		}
	}
	return true
}

// secretIn walks v and names the first credential-shaped spot, or "".
func secretIn(path string, v any) string {
	switch t := v.(type) {
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			p := path + "." + k
			if s, ok := t[k].(string); ok && secretKeyRE.MatchString(k) && s != "" && !secretRefRE.MatchString(s) {
				return p
			}
			if r := secretIn(p, t[k]); r != "" {
				return r
			}
		}
	case []any:
		for i, x := range t {
			if r := secretIn(fmt.Sprintf("%s[%d]", path, i), x); r != "" {
				return r
			}
		}
	case string:
		for _, re := range secretValREs {
			if re.MatchString(t) {
				return path
			}
		}
	}
	return ""
}

// TeamBundleResponse is what every read answers.
type TeamBundleResponse struct {
	Version int                     `json:"version"`
	Prev    int                     `json:"prev"`
	Actor   string                  `json:"actor,omitempty"`
	Note    string                  `json:"note,omitempty"`
	Created *time.Time              `json:"created,omitempty"`
	Bundle  json.RawMessage         `json:"bundle"`
	History []store.FleetTeamBundle `json:"history,omitempty"`
}

// TeamBundleRequest is a certificate read (POST) or the operator's write
// (PUT). A PUT carries Bundle or Restore; Base is optional.
type TeamBundleRequest struct {
	Cert    string          `json:"cert,omitempty"`
	Sig     string          `json:"sig,omitempty"`
	TS      int64           `json:"ts,omitempty"`
	Bundle  json.RawMessage `json:"bundle,omitempty"`
	Restore int             `json:"restore,omitempty"`
	Base    *int            `json:"base,omitempty"`
	Note    string          `json:"note,omitempty"`
}

func teamETag(v int) string { return fmt.Sprintf(`"team-v%d"`, v) }

// handleFleetTeamBundle serves control.TeamBundlePath. It authenticates
// itself (outside the viewer gate) because a node and a client-only computer
// read it too.
func (s *Server) handleFleetTeamBundle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	now := time.Now()
	id, ok := s.sshRelayHTTPIdentity(r)
	var req TeamBundleRequest
	if r.Method == http.MethodPost || r.Method == http.MethodPut {
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, teamBundleMax+4096)).Decode(&req); err != nil {
			httpError(w, http.StatusBadRequest, "body must be JSON")
			return
		}
	}
	if !ok {
		if tok := bearer(r); tok != "" {
			if ep, err := s.Store.EndpointByTokenHash(HashToken(tok)); err == nil {
				host, user := s.peerSelf(ep)
				id, ok = sshRelayIdentity{Actor: "node:" + host + "/" + user}, true
			}
		}
	}
	if !ok && r.Method == http.MethodPost && req.Cert != "" && req.Sig != "" {
		if d := now.Sub(time.Unix(req.TS, 0)); d > routesClockSkew || d < -routesClockSkew {
			httpError(w, http.StatusUnauthorized, "the signed timestamp is too far from the hub's clock — check this computer's time")
			return
		}
		cid, err := s.verifySSHRelayCert(req.Cert, req.Sig, control.TeamBundleSigMessage(req.TS), control.TeamBundleSigNamespace, now)
		if err != nil {
			var re *sshRelayError
			if errors.As(err, &re) {
				httpError(w, http.StatusUnauthorized, re.msg)
				return
			}
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		// a certificate reads; it never writes, whoever it names
		id, ok = sshRelayIdentity{Principal: cid.Principal, Actor: cid.Actor}, true
	}
	if !ok {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ccquota"`)
		httpError(w, http.StatusUnauthorized, "a session, a viewer token, a node token or a connection certificate is required")
		return
	}
	switch r.Method {
	case http.MethodGet, http.MethodPost:
		v, _ := strconv.Atoi(r.URL.Query().Get("version"))
		s.writeTeamBundle(w, r, v, id.Operator && r.URL.Query().Get("history") != "")
	case http.MethodPut:
		if !id.Operator {
			s.teamAudit(id.Actor, "FORBIDDEN", now)
			httpError(w, http.StatusForbidden, "only the operator changes the team configuration")
			return
		}
		s.putTeamBundle(w, id, req, now)
	default:
		w.Header().Set("Allow", "GET, POST, PUT")
		httpError(w, http.StatusMethodNotAllowed, "GET, POST (certificate read) or PUT")
	}
}

func (s *Server) teamAudit(actor, outcome string, now time.Time) {
	if err := s.Store.FleetAudit(actor, "team_bundle_put", "", outcome, "", now); err != nil {
		log.Printf("fleet audit: %v", err)
	}
}

func (s *Server) putTeamBundle(w http.ResponseWriter, id sshRelayIdentity, req TeamBundleRequest, now time.Time) {
	raw := req.Bundle
	note := strings.TrimSpace(req.Note)
	switch {
	case req.Restore > 0 && len(raw) > 0:
		httpError(w, http.StatusBadRequest, "send bundle or restore, not both")
		return
	case req.Restore > 0:
		old, err := s.Store.TeamBundle(req.Restore)
		if errors.Is(err, store.ErrNoTeamBundle) {
			httpError(w, http.StatusNotFound, fmt.Sprintf("no team bundle version %d", req.Restore))
			return
		} else if err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
		raw = json.RawMessage(old.Bundle)
		if note == "" {
			note = fmt.Sprintf("restore v%d", req.Restore)
		}
	case len(raw) == 0:
		httpError(w, http.StatusBadRequest, `body must be {"bundle": {…}} or {"restore": <version>}`)
		return
	}
	if len(raw) > teamBundleMax {
		httpError(w, http.StatusRequestEntityTooLarge, "the team bundle is at most 256 KiB")
		return
	}
	if len(note) > 200 {
		note = note[:200]
	}
	text, err := validateTeamBundle(raw)
	if err != nil {
		s.teamAudit(id.Actor, "REFUSED: "+err.Error(), now)
		httpError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	base := -1
	if req.Base != nil {
		base = *req.Base
	}
	b, err := s.Store.PutTeamBundle(text, id.Actor, note, base, now)
	if errors.Is(err, store.ErrTeamBundleBase) {
		httpError(w, http.StatusConflict, "the team bundle changed since that version — read it again")
		return
	} else if err != nil {
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.teamAudit(id.Actor, fmt.Sprintf("OK v%d", b.Version), now)
	created := b.Created
	w.Header().Set("ETag", teamETag(b.Version))
	writeJSON(w, http.StatusOK, TeamBundleResponse{Version: b.Version, Prev: b.Prev, Actor: b.Actor,
		Note: b.Note, Created: &created, Bundle: json.RawMessage(b.Bundle)})
}

func (s *Server) writeTeamBundle(w http.ResponseWriter, r *http.Request, v int, history bool) {
	b, err := s.Store.TeamBundle(v)
	out := TeamBundleResponse{Bundle: json.RawMessage(`{}`)}
	switch {
	case errors.Is(err, store.ErrNoTeamBundle) && v > 0:
		httpError(w, http.StatusNotFound, fmt.Sprintf("no team bundle version %d", v))
		return
	case errors.Is(err, store.ErrNoTeamBundle):
		// no team layer yet: version 0, nothing in it
	case err != nil:
		httpError(w, http.StatusInternalServerError, err.Error())
		return
	default:
		created := b.Created
		out = TeamBundleResponse{Version: b.Version, Prev: b.Prev, Actor: b.Actor, Note: b.Note,
			Created: &created, Bundle: json.RawMessage(b.Bundle)}
	}
	if history {
		if out.History, err = s.Store.TeamBundles(50); err != nil {
			httpError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	tag := teamETag(out.Version)
	w.Header().Set("ETag", tag)
	if v <= 0 && !history && r.Header.Get("If-None-Match") == tag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	writeJSON(w, http.StatusOK, out)
}
