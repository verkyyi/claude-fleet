// Package mcp exposes the hub's data to agents over the Model Context
// Protocol, read-only.
//
// Read-only is a design decision, not a limitation. A monitor that can also
// pause endpoints or change quotas needs a control channel back to every
// machine, which is a far larger security surface than "tell me what my fleet
// spent". If that is ever wanted it should be a separate, separately
// authorised service.
//
// Transport is Streamable HTTP: a single POST endpoint carrying JSON-RPC 2.0.
// It is implemented directly rather than through an SDK to keep the binary
// dependency-free.
package mcp

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/verkyyi/ccquota/internal/api"
	"github.com/verkyyi/ccquota/internal/store"
)

// protocolVersion is the MCP revision this server implements.
const protocolVersion = "2025-06-18"

// caveat is repeated in every tool description. An agent relaying these
// numbers to a person will otherwise present an estimate with the confidence
// of a measurement.
const caveat = " The account-wide utilization is exact and already covers every device on " +
	"the subscription; per-endpoint and per-project shares are proportional ESTIMATES. " +
	"Costs are notional API-equivalent figures, never a bill."

// Handler returns the /mcp handler.
func Handler(srv *api.Server) http.Handler {
	s := &mcpServer{api: srv}
	return http.HandlerFunc(s.serve)
}

type mcpServer struct{ api *api.Server }

// --- JSON-RPC plumbing ---------------------------------------------------

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

const (
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeInternal       = -32603
)

const maxRPCBody = 1 << 20

func (s *mcpServer) serve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		// GET on a Streamable HTTP endpoint opens a server-initiated stream.
		// This server never initiates anything, so declining is correct and
		// clearer than holding a connection open forever.
		w.Header().Set("Allow", "POST")
		http.Error(w, "this MCP server does not open server-initiated streams; use POST", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxRPCBody))
	if err != nil {
		writeRPC(w, &response{JSONRPC: "2.0", Error: &rpcError{codeInvalidRequest, "unreadable body"}})
		return
	}

	var req request
	if err := json.Unmarshal(body, &req); err != nil {
		writeRPC(w, &response{JSONRPC: "2.0", Error: &rpcError{codeInvalidRequest, "malformed JSON-RPC: " + err.Error()}})
		return
	}

	resp := s.dispatch(&req)
	if resp == nil {
		// A notification (no id) gets no body, per JSON-RPC.
		w.WriteHeader(http.StatusAccepted)
		return
	}
	writeRPC(w, resp)
}

func writeRPC(w http.ResponseWriter, resp *response) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (s *mcpServer) dispatch(req *request) *response {
	out := &response{JSONRPC: "2.0", ID: req.ID}

	switch req.Method {
	case "initialize":
		out.Result = map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "ccquota", "version": "1"},
			"instructions": "Reports Claude Code subscription usage collected from every enrolled " +
				"endpoint." + caveat,
		}
	case "notifications/initialized", "notifications/cancelled":
		return nil
	case "ping":
		out.Result = map[string]any{}
	case "tools/list":
		out.Result = map[string]any{"tools": toolSpecs()}
	case "tools/call":
		out.Result, out.Error = s.callTool(req.Params)
	default:
		out.Error = &rpcError{codeMethodNotFound, "unknown method " + req.Method}
	}

	if out.Error != nil {
		out.Result = nil
	}
	return out
}

// --- tools ---------------------------------------------------------------

type toolSpec struct {
	Name        string         `json:"name"`
	Title       string         `json:"title,omitempty"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

func obj(props map[string]any, required ...string) map[string]any {
	m := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		m["required"] = required
	} else {
		m["required"] = []string{}
	}
	return m
}

var accountProp = map[string]any{
	"type": "string",
	"description": "Subscription (account uuid) to report on. Optional when the hub " +
		"holds exactly one; required when it holds several — call list_accounts first.",
}

var sinceProp = map[string]any{
	"type":        "string",
	"description": `Start of the range: RFC3339, or relative like "7d" or "24h" meaning "ago". Defaults to 7 days ago.`,
}

var untilProp = map[string]any{
	"type":        "string",
	"description": "End of the range: RFC3339, or relative like \"1h\". Defaults to now.",
}

var limitProp = map[string]any{
	"type":        "integer",
	"description": "Maximum rows to return (default 50).",
}

func toolSpecs() []toolSpec {
	return []toolSpec{
		{
			Name:  "list_accounts",
			Title: "List subscriptions",
			Description: "List the Claude subscriptions this hub tracks, with plan tier and how " +
				"many endpoints report on each. Call this first when you do not know the account uuid.",
			InputSchema: obj(map[string]any{}),
		},
		{
			Name:  "get_limits",
			Title: "Current rate-limit state",
			Description: "How much of the 5-hour and 7-day windows a subscription has used right now, " +
				"when each resets, the current burn rate, and a projection of when the window would be " +
				"exhausted. Also breaks the 5-hour window down by endpoint. If the reading is " +
				"unavailable the response says so with a reason — treat that as unknown and do NOT " +
				"report zero." + caveat,
			InputSchema: obj(map[string]any{"account": accountProp}),
		},
		{
			Name:  "list_endpoints",
			Title: "List collecting machines",
			Description: "The machines reporting into this hub: hostname, OS, agent version and when " +
				"each was last heard from. Useful for spotting an agent that has stopped reporting.",
			InputSchema: obj(map[string]any{"account": accountProp}),
		},
		{
			Name:  "usage_by_endpoint",
			Title: "Spend by machine",
			Description: "Token and cost totals grouped by machine over a time range — which server or " +
				"laptop is consuming the subscription." + caveat,
			InputSchema: obj(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			}),
		},
		{
			Name:  "usage_by_project",
			Title: "Spend by project",
			Description: "Token and cost totals grouped by working directory over a time range — which " +
				"codebase the spend went to." + caveat,
			InputSchema: obj(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			}),
		},
		{
			Name:  "usage_by_session",
			Title: "Spend by session",
			Description: "Token and cost totals grouped by Claude Code session, including how much went " +
				"to subagents. Use this to find a single runaway session." + caveat,
			InputSchema: obj(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			}),
		},
		{
			Name:  "usage_history",
			Title: "Usage over time",
			Description: "A time series of a subscription's usage plus a per-model split, for trend and " +
				"capacity questions." + caveat,
			InputSchema: obj(map[string]any{
				"account":     accountProp,
				"since":       sinceProp,
				"until":       untilProp,
				"granularity": map[string]any{"type": "string", "enum": []string{"hour", "day"}, "description": `Bucket size; defaults to "day".`},
			}),
		},
	}
}

type callParams struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments"`
}

func (s *mcpServer) callTool(raw json.RawMessage) (any, *rpcError) {
	var p callParams
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, &rpcError{codeInvalidParams, "malformed tool call: " + err.Error()}
	}

	payload, err := s.run(p.Name, p.Arguments)
	if err != nil {
		// A tool-level failure is reported inside the result with isError, not
		// as a protocol error: the model should see the message and adapt
		// (usually by calling list_accounts first).
		return map[string]any{
			"isError": true,
			"content": []any{map[string]any{"type": "text", "text": err.Error()}},
		}, nil
	}

	pretty, _ := json.MarshalIndent(payload, "", "  ")
	return map[string]any{
		"content":           []any{map[string]any{"type": "text", "text": string(pretty)}},
		"structuredContent": payload,
	}, nil
}

func (s *mcpServer) run(name string, args map[string]any) (any, error) {
	switch name {
	case "list_accounts":
		accts, err := s.api.Store.ListAccounts()
		if err != nil {
			return nil, err
		}
		if len(accts) == 0 {
			return map[string]any{
				"accounts": []any{},
				"note":     "no endpoint has reported to this hub yet; check that an agent is running and enrolled",
			}, nil
		}
		return map[string]any{"accounts": accts}, nil

	case "get_limits":
		account, err := s.account(args)
		if err != nil {
			return nil, err
		}
		return s.api.LimitsFor(account)

	case "list_endpoints":
		eps, err := s.api.Store.ListEndpoints(str(args, "account"))
		if err != nil {
			return nil, err
		}
		return map[string]any{"endpoints": eps, "now": time.Now().UTC()}, nil

	case "usage_by_endpoint":
		return s.usage(args, store.ByEndpoint)
	case "usage_by_project":
		return s.usage(args, store.ByProject)
	case "usage_by_session":
		return s.usage(args, store.BySession)

	case "usage_history":
		account, err := s.account(args)
		if err != nil {
			return nil, err
		}
		g := store.Granularity(str(args, "granularity"))
		if g == "" {
			g = store.Daily
		}
		start, end := timeRange(args)
		series, err := s.api.Store.History(account, g, start, end)
		if err != nil {
			return nil, err
		}
		models, err := s.api.Store.ModelSplit(account, start, end)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"account_uuid": account, "granularity": string(g),
			"since": start, "until": end,
			"series": series, "by_model": models,
			"disclaimer": strings.TrimSpace(caveat),
		}, nil

	default:
		return nil, fmt.Errorf("unknown tool %q", name)
	}
}

func (s *mcpServer) usage(args map[string]any, d store.Dimension) (any, error) {
	account, err := s.account(args)
	if err != nil {
		return nil, err
	}
	start, end := timeRange(args)
	buckets, err := s.api.Store.UsageBy(account, d, start, end, intArg(args, "limit"))
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"account_uuid": account, "by": string(d),
		"since": start, "until": end, "buckets": buckets,
		"disclaimer": strings.TrimSpace(caveat),
	}, nil
}

// account resolves the subscription, inferring it only when unambiguous.
//
// With several subscriptions on one hub, guessing would hand the model a
// number for the wrong account with no way to tell.
func (s *mcpServer) account(args map[string]any) (string, error) {
	if a := str(args, "account"); a != "" {
		return a, nil
	}
	accts, err := s.api.Store.ListAccounts()
	if err != nil {
		return "", err
	}
	switch len(accts) {
	case 0:
		return "", fmt.Errorf("no subscriptions have reported to this hub yet")
	case 1:
		return accts[0].AccountUUID, nil
	default:
		names := make([]string, 0, len(accts))
		for _, a := range accts {
			label := a.Email
			if label == "" {
				label = a.DisplayName
			}
			names = append(names, fmt.Sprintf("%s (%s)", a.AccountUUID, label))
		}
		return "", fmt.Errorf("this hub holds %d subscriptions; pass `account` explicitly. Available: %s",
			len(accts), strings.Join(names, ", "))
	}
}

func str(args map[string]any, key string) string {
	if v, ok := args[key].(string); ok {
		return v
	}
	return ""
}

func intArg(args map[string]any, key string) int {
	switch v := args[key].(type) {
	case float64: // JSON numbers decode as float64
		return int(v)
	case string:
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

const defaultRange = 7 * 24 * time.Hour

func timeRange(args map[string]any) (time.Time, time.Time) {
	now := time.Now().UTC()
	end := now
	if t, ok := parseWhen(str(args, "until"), now); ok {
		end = t
	}
	start := end.Add(-defaultRange)
	if t, ok := parseWhen(str(args, "since"), now); ok {
		start = t
	}
	if !start.Before(end) {
		start = end.Add(-defaultRange)
	}
	return start, end
}

func parseWhen(s string, now time.Time) (time.Time, bool) {
	if s == "" {
		return time.Time{}, false
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), true
	}
	if n := len(s); n > 1 && s[n-1] == 'd' {
		if days, err := strconv.Atoi(s[:n-1]); err == nil {
			return now.Add(-time.Duration(days) * 24 * time.Hour), true
		}
	}
	if d, err := time.ParseDuration(s); err == nil {
		return now.Add(-d), true
	}
	return time.Time{}, false
}
