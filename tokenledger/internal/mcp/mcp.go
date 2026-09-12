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
	"github.com/verkyyi/ccquota/internal/findings"
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
	"description": `Subscription to report on: an account uuid, or "all" to span every ` +
		`subscription on this hub. Omitted means "all" when the hub holds several, ` +
		`and the single subscription when it holds one. Token and cost figures are ` +
		`additive across subscriptions; rate-limit utilization is not.`,
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

// chipProps are the drill-down dimensions store.Filter accepts, at most one
// value per dimension, ANDed together.
var chipProps = map[string]any{
	"source":   map[string]any{"type": "string", "description": "Limit token usage to a source, such as claude or codex."},
	"endpoint": map[string]any{"type": "string", "description": "Limit to one machine, by endpoint id."},
	"user":     map[string]any{"type": "string", "description": "Limit to one OS login."},
	"project":  map[string]any{"type": "string", "description": "Limit to one working directory (cwd)."},
	"model":    map[string]any{"type": "string", "description": "Limit to one model id."},
	"branch":   map[string]any{"type": "string", "description": "Limit to one git branch."},
	"team":     map[string]any{"type": "string", "description": "Limit to one operator-assigned team."},
	"session":  map[string]any{"type": "string", "description": "Limit to one Claude Code session id."},
}

// withChips merges the drill-down chips into a tool's own properties.
func withChips(base map[string]any) map[string]any {
	out := make(map[string]any, len(base)+len(chipProps))
	for k, v := range base {
		out[k] = v
	}
	for k, v := range chipProps {
		out[k] = v
	}
	return out
}

func toolSpecs() []toolSpec {
	return []toolSpec{
		{Name: "get_collectors", Title: "Collection status by source", Description: "Source profile health, latest scan/event, client version, quota query failures and queue backlog." + caveat, InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"]})},
		{Name: "get_account_usage", Title: "Service account activity", Description: "Independent service totals and locally attributed details. Overlap exists; they must never be added or treated as directly comparable." + caveat, InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"]})},
		{Name: "get_live", Title: "Live and recent sessions", Description: "Claude heartbeats and Codex recent log activity, filtered by source/account, with scoped aggregates. Never add these overlapping counters to stored totals." + caveat, InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"]})},
		{Name: "quota_history", Title: "Provider quota window history", Description: "Codex provider-defined quota windows and critical time within the selected interval. Windows and accounts are separate series; percentages are not added." + caveat, InputSchema: obj(withChips(map[string]any{"account": accountProp, "since": sinceProp, "until": untilProp}))},
		{
			Name:  "list_accounts",
			Title: "List subscriptions",
			Description: "List the subscriptions and local usage pools this hub tracks, with source, plan tier and how " +
				"many endpoints report on each. Call this first when you do not know the account uuid.",
			InputSchema: obj(map[string]any{"source": chipProps["source"]}),
		},
		{
			Name:  "get_limits",
			Title: "Current rate-limit state",
			Description: "How much of each provider-defined quota window a subscription has used right now, " +
				"when each resets, the current burn rate, and a projection of when the window would be " +
				"exhausted. Also breaks the 5-hour window down by endpoint. If the reading is " +
				"unavailable the response says so with a reason — treat that as unknown and do NOT " +
				"report zero." + caveat,
			InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"]}),
		},
		{
			Name:  "list_endpoints",
			Title: "List collecting machines",
			Description: "The machines reporting into this hub: hostname, OS, agent version and when " +
				"each was last heard from. Useful for spotting an agent that has stopped reporting.",
			InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"]}),
		},
		{
			Name:  "usage_by_account",
			Title: "Spend by subscription",
			Description: "Token and cost totals grouped by subscription — which of several " +
				"Claude plans a period's spend landed on. Subscription is an ordinary axis here, " +
				"the same shape of question as by-machine or by-project." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "list_account_switches",
			Title: "Machines that changed subscription",
			Description: "Occasions when a machine logged OUT of one subscription and INTO " +
				"another. Turns recorded before a switch keep their old attribution and cannot " +
				"be corrected, so these are the seams where historical figures become " +
				"unreliable. Use it to explain a total that looks wrong for a period. " +
				"This is rare: running several subscriptions side by side is NOT a switch — " +
				"for that, call list_endpoint_accounts.",
			InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"], "limit": limitProp}),
		},
		{
			Name:  "list_endpoint_accounts",
			Title: "Which subscriptions each machine runs",
			Description: "The subscriptions seen running on each machine, with the window each " +
				"was active over and whether it is that machine's own login or merely a " +
				"subscription observed in a session on it. A machine can run several AT THE " +
				"SAME TIME — Claude Code takes its account from the process environment — so " +
				"this is a list per machine, not one value.",
			InputSchema: obj(map[string]any{"account": accountProp, "source": chipProps["source"], "limit": limitProp}),
		},
		{
			Name:        "usage_by_source",
			Title:       "Token usage by source",
			Description: "Token and notional cost totals grouped by collector source, such as Claude Code or Codex." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "usage_by_user",
			Title: "Spend by operating-system login",
			Description: "Token and cost totals grouped by the OS account the work ran under — " +
				"who on a shared machine is consuming the subscription. Every OS login has its " +
				"own Claude Code install, transcripts and credentials, so this is a different " +
				"axis from by-machine, and on a multi-user box it is usually the one you " +
				"want." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "usage_by_endpoint",
			Title: "Spend by machine",
			Description: "Token and cost totals grouped by machine over a time range — which server or " +
				"laptop is consuming the subscription." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "usage_by_project",
			Title: "Spend by project",
			Description: "Token and cost totals grouped by working directory over a time range — which " +
				"codebase the spend went to." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "usage_by_session",
			Title: "Spend by session",
			Description: "Token and cost totals grouped by Claude Code session, including how much went " +
				"to subagents. Use this to find a single runaway session." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp, "limit": limitProp,
			})),
		},
		{
			Name:  "usage_history",
			Title: "Usage over time",
			Description: "A time series of a subscription's usage plus a per-model split, for trend and " +
				"capacity questions." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account":     accountProp,
				"since":       sinceProp,
				"until":       untilProp,
				"granularity": map[string]any{"type": "string", "enum": []string{"hour", "day"}, "description": `Bucket size; defaults to "day".`},
			})),
		},
		{
			Name:  "usage_summary",
			Title: "Totals for a period",
			Description: "Totals for a period under optional drill-down filters: tokens, notional cost, " +
				"turns, sessions, token composition (cache read / create, input, output, thinking), " +
				"subagent share, and the same figures for the previous period of equal length." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp,
			})),
		},
		{
			Name:  "list_sessions",
			Title: "List sessions",
			Description: "Sessions in a period, heaviest first by default, each with its token composition, " +
				"cache hit rate and subagent share. Narrow with the drill-down filters (project, model, " +
				"user, ...) to list what ran under one of them, or use usage_by_session to rank by a " +
				"different total." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp,
				"sort": map[string]any{
					"type": "string", "enum": []string{"tokens", "cost", "started", "duration", "turns"},
					"description": `Sort order; defaults to "tokens" (heaviest first).`,
				},
				"limit": limitProp,
			})),
		},
		{
			Name:  "get_session",
			Title: "One session's detail",
			Description: "One session's header (tokens, cost, models, cache hit) and every turn inside it. " +
				"Turns are omitted (pruned: true) once the raw events behind them have aged out of " +
				"retention; the header itself survives from the hourly rollup." + caveat,
			InputSchema: obj(map[string]any{
				"account": accountProp,
				"session_id": map[string]any{
					"type": "string", "description": "The session id, from list_sessions or usage_by_session.",
				},
			}, "session_id"),
		},
		{
			Name:  "get_findings",
			Title: "Machine-generated findings",
			Description: "Machine-generated findings for a period: runaway sessions, unpriced models, time " +
				"spent in the critical rate-limit band, cache-hit drops and spend spikes. Pass " +
				`view: "now" for live, minute-scale alerts instead (high rate-limit windows, an ` +
				"agent that has stopped reporting, a runaway session in flight) — that mode ignores " +
				"since/until and the drill-down filters. Findings are ranked, capped at a handful, and " +
				"each carries a scope map naming the chip an equivalent usage_by_* or list_sessions " +
				"call can drill into." + caveat,
			InputSchema: obj(withChips(map[string]any{
				"account": accountProp, "since": sinceProp, "until": untilProp,
				"view": map[string]any{
					"type": "string", "enum": []string{"review", "now"},
					"description": `"review" (default) evaluates the period rules; "now" evaluates live alerts.`,
				},
			})),
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
	if source := str(args, "source"); source != "" && source != "claude" && source != "codex" {
		return nil, fmt.Errorf("source must be claude or codex")
	}
	switch name {
	case "get_collectors":
		rows, err := s.api.Store.Collectors(str(args, "account"), str(args, "source"))
		return map[string]any{"collectors": rows}, err
	case "get_account_usage":
		return s.api.AccountUsageView(str(args, "account"), str(args, "source"))
	case "get_live":
		l := s.api.LiveStore
		if l == nil {
			l = api.NewLive()
		}
		return s.api.FilterLive(l.Snapshot(), str(args, "account"), str(args, "source")), nil
	case "quota_history":
		f, err := s.filter(args)
		if err != nil {
			return nil, err
		}
		rows, err := s.api.QuotaHistorySeries(f, 400)
		return map[string]any{"account_uuid": f.Account, "since": f.Start, "until": f.End, "series": rows}, err
	case "list_accounts":
		accts, err := s.api.Store.ListAccounts()
		if err != nil {
			return nil, err
		}
		if source := str(args, "source"); source != "" {
			filtered := accts[:0]
			for _, account := range accts {
				if account.Source == source {
					filtered = append(filtered, account)
				}
			}
			accts = filtered
		}
		if len(accts) == 0 {
			return map[string]any{
				"accounts": []any{},
				"note":     "no endpoint has reported to this hub yet; check that an agent is running and enrolled",
			}, nil
		}
		return map[string]any{"accounts": accts}, nil

	case "get_limits":
		// Spanning subscriptions returns a LIST, never a total: separate quota
		// pools with separate resets cannot be added.
		if a := str(args, "account"); a == "all" || a == store.AllAccounts {
			return s.api.LimitsForAllSource(str(args, "source"))
		}
		account, err := s.account(args)
		if err != nil {
			return nil, err
		}
		if account == store.AllAccounts {
			return s.api.LimitsForAllSource(str(args, "source"))
		}
		return s.api.LimitsForSource(account, str(args, "source"))

	case "list_endpoints":
		account := str(args, "account")
		if account == "all" || account == store.AllAccounts {
			account = ""
		}
		eps, err := s.api.Store.ListEndpoints(account, str(args, "source"))
		if err != nil {
			return nil, err
		}
		return map[string]any{"endpoints": eps, "now": time.Now().UTC()}, nil

	case "list_account_switches":
		sw, err := s.api.Store.SourceSwitches(str(args, "account"), str(args, "source"), intArg(args, "limit"))
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"switches": sw,
			"note": "Turns recorded before a switch keep the earlier subscription's " +
				"attribution and cannot be corrected retroactively.",
		}, nil

	case "usage_by_account":
		all := make(map[string]any, len(args)+1)
		for k, v := range args {
			all[k] = v
		}
		all["account"] = store.AllAccounts
		return s.usage(all, store.ByAccount)

	case "list_endpoint_accounts":
		eas, err := s.api.Store.EndpointAccounts(str(args, "account"), intArg(args, "limit"), str(args, "source"))
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"endpoint_accounts": eas,
			"note": "Several rows for one endpoint mean it ran those subscriptions " +
				"concurrently, not that it switched between them.",
		}, nil

	case "usage_by_endpoint":
		return s.usage(args, store.ByEndpoint)
	case "usage_by_source":
		return s.usage(args, store.BySource)
	case "usage_by_user":
		return s.usage(args, store.ByUser)
	case "usage_by_project":
		return s.usage(args, store.ByProject)
	case "usage_by_session":
		return s.usage(args, store.BySession)

	case "usage_history":
		f, err := s.filter(args)
		if err != nil {
			return nil, err
		}
		g := store.Granularity(str(args, "granularity"))
		if g == "" {
			g = store.Daily
		}
		if g != store.Hourly && g != store.Daily {
			return nil, fmt.Errorf("unknown granularity %q (want hour or day)", g)
		}
		rows, err := s.api.Store.HourlyByModel(f)
		if err != nil {
			return nil, err
		}
		folded, err := api.FoldHours(rows, string(g), false, nil)
		if err != nil {
			return nil, err
		}
		series := seriesToBuckets(folded)
		models, err := s.api.Store.UsageByFiltered(f, store.ByModel, 50)
		if err != nil {
			return nil, err
		}
		hist := map[string]any{
			"account_uuid": f.Account, "granularity": string(g),
			"since": f.Start, "until": f.End,
			"series": series, "by_model": models,
			"disclaimer": strings.TrimSpace(caveat),
		}
		if note := scopeNote(f.Account); note != "" {
			hist["all_accounts"] = true
			hist["scope_note"] = note
		}
		return hist, nil

	case "usage_summary":
		f, err := s.filter(args)
		if err != nil {
			return nil, err
		}
		sum, err := s.api.Store.Summary(f)
		if err != nil {
			return nil, err
		}
		psum, err := s.api.Store.Summary(f.Prev())
		if err != nil {
			return nil, err
		}
		out := map[string]any{
			"account_uuid": f.Account, "since": f.Start, "until": f.End,
			"summary": sum, "prev": psum,
			"disclaimer": strings.TrimSpace(caveat),
		}
		if note := scopeNote(f.Account); note != "" {
			out["all_accounts"] = true
			out["scope_note"] = note
		}
		return out, nil

	case "list_sessions":
		f, err := s.filter(args)
		if err != nil {
			return nil, err
		}
		rows, err := s.api.Store.Sessions(f, str(args, "sort"), intArg(args, "limit"), 0)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"account_uuid": f.Account, "since": f.Start, "until": f.End, "sessions": rows,
		}, nil

	case "get_session":
		account, err := s.account(args)
		if err != nil {
			return nil, err
		}
		id := str(args, "session_id")
		if id == "" {
			return nil, fmt.Errorf("session_id is required")
		}
		head, err := s.api.Store.Session(account, id, str(args, "source"))
		if err != nil {
			return nil, err
		}
		if head == nil {
			return nil, fmt.Errorf("unknown session %q", id)
		}
		turns, err := s.api.Store.SessionTurns(account, id, str(args, "source"))
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"session": head, "turns": turns, "pruned": len(turns) == 0 && head.Turns > 0,
		}, nil

	case "get_findings":
		// Same envelope shape as usage_summary -- account_uuid plus (for the
		// review view) the ALIGNED window actually queried, since/until
		// omitted entirely for "now" rather than echoing a fake window -- for
		// consistency with the other three new tools and with GET
		// /v1/findings, which reads the same two gatherers.
		if str(args, "view") == "now" {
			account, err := s.account(args)
			if err != nil {
				return nil, err
			}
			in, err := s.api.GatherNowSource(account, str(args, "source"))
			if err != nil {
				return nil, err
			}
			out := map[string]any{
				"account_uuid": account, "view": "now",
				"findings": findings.Now(in),
			}
			if note := scopeNote(account); note != "" {
				out["all_accounts"] = true
				out["scope_note"] = note
			}
			return out, nil
		}
		f, err := s.filter(args)
		if err != nil {
			return nil, err
		}
		in, err := s.api.GatherReview(f)
		if err != nil {
			return nil, err
		}
		out := map[string]any{
			"account_uuid": f.Account, "since": f.Start, "until": f.End, "view": "review",
			"findings": findings.Review(in),
		}
		if note := scopeNote(f.Account); note != "" {
			out["all_accounts"] = true
			out["scope_note"] = note
		}
		return out, nil

	default:
		return nil, fmt.Errorf("unknown tool %q", name)
	}
}

// filter builds a store.Filter from tool arguments, mirroring api.scope:
// account, then the time range, then at most one value per drill-down chip.
func (s *mcpServer) filter(args map[string]any) (store.Filter, error) {
	account, err := s.account(args)
	if err != nil {
		return store.Filter{}, err
	}
	start, end := timeRange(args)
	f := store.Filter{
		Account: account, Start: start, End: end,
		Endpoint: str(args, "endpoint"), OSUser: str(args, "user"), CWD: str(args, "project"),
		Model: str(args, "model"), Branch: str(args, "branch"), Team: str(args, "team"), Session: str(args, "session"),
		Source: str(args, "source"),
	}
	return f.AlignHours(), nil
}

func (s *mcpServer) usage(args map[string]any, d store.Dimension) (any, error) {
	f, err := s.filter(args)
	if err != nil {
		return nil, err
	}
	account := f.Account
	buckets, err := s.api.Store.UsageByFiltered(f, d, intArg(args, "limit"))
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"account_uuid": account, "by": string(d),
		"since": f.Start, "until": f.End, "buckets": buckets,
		"disclaimer": strings.TrimSpace(caveat),
	}
	// An agent relaying a blended total without saying it is blended is the
	// same failure as a dashboard doing it.
	if note := scopeNote(account); note != "" {
		out["all_accounts"] = true
		out["scope_note"] = note
	}
	return out, nil
}

// seriesToBuckets adapts api.FoldHours's []api.Series to the []store.Bucket
// shape usage_history has always returned over MCP. The two are identical
// field for field except Series carries no Label -- store.Bucket's Label is
// simply left at its zero value "", which is exactly what usage_history
// returned before this used api.FoldHours too (by_model, a separate field,
// already covers the per-model breakdown; usage_history has never populated
// a per-bucket label). Series' Stack is dropped: usage_history calls
// api.FoldHours with stack=false, so it is always empty anyway.
//
// This -- not a second hand-written fold of bucketKey's day/hour arithmetic
// -- is what usage_history now does; see the 2026-09-02 pre-deploy review of
// commit 1ff1bfc, which introduced (and this replaced) exactly that second
// implementation.
func seriesToBuckets(series []api.Series) []store.Bucket {
	out := make([]store.Bucket, len(series))
	for i, s := range series {
		out[i] = store.Bucket{
			Key: s.Key, Events: s.Events, Tokens: s.Tokens, CostUSD: s.CostUSD,
			Unpriced: s.Unpriced, Sidechain: s.Sidechain,
		}
	}
	return out
}

// scopeNote states what a figure spans, so a cross-subscription total is never
// mistaken for one subscription's.
func scopeNote(account string) string {
	if account != store.AllAccounts {
		return ""
	}
	return "Totals span every subscription on this hub. Tokens and notional costs are " +
		"additive; rate-limit utilization is not and is reported per subscription."
}

// account resolves the subscription, inferring it only when unambiguous.
//
// With several subscriptions on one hub, guessing would hand the model a
// number for the wrong account with no way to tell.
func (s *mcpServer) account(args map[string]any) (string, error) {
	if a := str(args, "account"); a != "" {
		if a == "all" {
			return store.AllAccounts, nil
		}
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
		// Everything, labelled — the same default the HTTP API takes. Refusing
		// made the subscription a mode rather than an axis.
		return store.AllAccounts, nil
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
