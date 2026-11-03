package mcp

// The console's session tools (task T4DN): what a person's own agent uses to
// manage their sessions — listed only when the hub runs the fleet module, served
// by api.CallSessionTool through the same roads the console takes.

// sessionCaveat rides every session tool: whose, and what it never does.
const sessionCaveat = " Only ever the caller's own sessions (a person's — the operator's shared " +
	"door has no conversation to talk to). Built from what the person's machines last reported to " +
	"the hub, so a state can be a few seconds old; a machine that went quiet is said (machine_lost), " +
	"never shown as idle."

// sessionWriteCaveat rides the tools that change something.
const sessionWriteCaveat = " A WRITE through the same road as the console's page; checked against " +
	"the scope this agent was granted. Never types into a terminal: the session's own gate takes, " +
	"queues or refuses the line, and the answer says which."

var sessionIDProp = map[string]any{"type": "string",
	"description": "A session's id from sessions_list (its worker id; the list's own id, fid:<id> or its task's T<n> also work)."}

func sessionToolSpecs() []toolSpec {
	return []toolSpec{
		{
			Name:  "sessions_list",
			Title: "My sessions",
			Description: "The caller's own Claude Code / Codex sessions on their machines — the console's 会话 list. " +
				"view: needs_you (default: asking a question or a permission, failed, stopped on an error, parked " +
				"waiting on you), live (everything not ended), ended (ended in the last 7 days), all. Each row: " +
				"id, title, task (T<n>), repo, agent, machine, status (needs_you · working · idle · ended), state " +
				"(the list's word), asking {kind, text} when it asks, can_talk, updated, url (its console page). " +
				"Plus counts and a one-line summary. There is no read/unread mark: a session whose turn ended is " +
				"idle (state turn_done)." + sessionCaveat,
			InputSchema: obj(map[string]any{
				"view": map[string]any{"type": "string", "enum": []string{"needs_you", "live", "ended", "all"}},
				"repo": map[string]any{"type": "string", "description": "Only sessions in this repo (owner/name or name)."},
			}),
		},
		{
			Name:  "session_get",
			Title: "One session",
			Description: "One of the caller's sessions: its row (as sessions_list), tokens_today, and — when it asks " +
				"something — pending: {pending_id (the fingerprint session_answer takes), kind (question · permission), " +
				"questions with their options, tool, summary}, read from the session's own gate (a few seconds at most). " +
				"pending_error says why it could not be read." + sessionCaveat,
			InputSchema: obj(map[string]any{"id": sessionIDProp}, "id"),
		},
		{
			Name:  "session_read",
			Title: "A session's last turns",
			Description: "The last turns of one session's conversation, oldest first: [{role (user · assistant · system), " +
				"kind (message · tool · note · error · stopped · image · page), text}]. A reply's pieces are one turn; a " +
				"tool step is its one-line summary, never its output; each text is clipped to 2000 characters. Read live " +
				"from the session's machine (source=live), else the copy the hub keeps beside the entry " +
				"(source=copy, copy_at). An ended session reads its history." + sessionCaveat,
			InputSchema: obj(map[string]any{"id": sessionIDProp,
				"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 50, "description": "Turns to return (default 20)."}}, "id"),
		},
		{
			Name:  "session_say",
			Title: "Say something to a session",
			Description: "Give a live session a line as its next turn — the console's composer (POST /v1/chat/say). " +
				"Answers state: sent (it took the line; a parked session is woken), queued (a turn is running or " +
				"someone is typing in its terminal — it goes in after), refused (nothing sent; reason). The same " +
				"idempotency_key never sends twice (for a day), and the session's door dedups the line too. " +
				"Needs worker:message." + sessionWriteCaveat + sessionCaveat,
			InputSchema: obj(map[string]any{"id": sessionIDProp,
				"text":            map[string]any{"type": "string", "description": "The line, up to 20000 characters."},
				"idempotency_key": idemProp}, "id", "text", "idempotency_key"),
		},
		{
			Name:  "session_answer",
			Title: "Answer what a session asks",
			Description: "Answer the question or permission a session is asking — the console's answer buttons. " +
				"Give pending_id from session_get (omitted: the one it asks now), and one of: decision allow|deny (a " +
				"permission), option (an option's label, or its number in the first question), answers " +
				"{<question>: <label>} (several questions), or text (your own words). A pending_id that is no longer " +
				"the one it asks is refused, never applied to the new one. Needs worker:answer." + sessionWriteCaveat + sessionCaveat,
			InputSchema: obj(map[string]any{"id": sessionIDProp,
				"pending_id": map[string]any{"type": "string", "description": "The 16-hex fingerprint from session_get's pending."},
				"decision":   map[string]any{"type": "string", "enum": []string{"allow", "deny"}},
				"option":     map[string]any{"description": "An option's label (string) or its 1-based number (integer)."},
				"answers":    map[string]any{"type": "object", "description": "{<question text>: <option label>} for an ask of several questions."},
				"text":       map[string]any{"type": "string"}}, "id"),
		},
		{
			Name:  "session_stop",
			Title: "Stop a session's turn",
			Description: "Stop the session's current turn (Esc) — the console's stop button. The session stays open " +
				"and can be talked to again; nothing is closed or deleted. Needs worker:stop." + sessionWriteCaveat + sessionCaveat,
			InputSchema: obj(map[string]any{"id": sessionIDProp}, "id"),
		},
		{
			Name:  "session_new",
			Title: "Start new sessions",
			Description: "Start 1–8 new sessions, each with its first line as its first turn — the console's 新会话 " +
				"(POST /v1/chat/open): on the caller's home machine, with no repo. A repo or machine given is not " +
				"used and the item's note says so (worker_start opens an issue in a repo). Returns per item {id, " +
				"url, state opened | failed, error}; one item failing never fails the others. The same " +
				"idempotency_key opens each item at most once. Needs worker:start." + sessionWriteCaveat,
			InputSchema: obj(map[string]any{
				"items": map[string]any{"type": "array", "minItems": 1, "maxItems": 8, "items": map[string]any{
					"type": "object", "required": []string{"text"}, "properties": map[string]any{
						"text":    map[string]any{"type": "string", "description": "The first line."},
						"agent":   map[string]any{"type": "string", "enum": []string{"claude", "codex"}, "description": "Default claude."},
						"repo":    map[string]any{"type": "string", "description": "Not used yet (see above)."},
						"machine": map[string]any{"type": "string", "description": "auto (default); another is not used yet."},
					}}},
				"idempotency_key": idemProp}, "items", "idempotency_key"),
		},
		{
			Name:  "task_list",
			Title: "My task records",
			Description: "The caller's task records (T<n>), newest first, each with its session's live word off the " +
				"inventory — the console's 任务 list." + sessionCaveat,
			InputSchema: obj(map[string]any{"limit": map[string]any{"type": "integer", "minimum": 1, "maximum": 500, "description": "Default 50."}}),
		},
		{
			Name:        "task_get",
			Title:       "One task record",
			Description: "One of the caller's task records by T<n>, its code or its ID." + sessionCaveat,
			InputSchema: obj(map[string]any{"ref": map[string]any{"type": "string"}}, "ref"),
		},
		{
			Name:  "wait",
			Title: "Wait for sessions to change",
			Description: "Hold until one of the caller's sessions changes: until needs_you (default: a session starts " +
				"asking / fails / parks waiting on you — with no cursor, those already waiting are returned at once), " +
				"done (a working session stops working) or any (any change of state). ids narrows it to some sessions. " +
				"Returns {events: [{id, title, from, to, state, asking?, at, url}], cursor, timed_out}; pass cursor back " +
				"to wait from where this answer left off, nothing missed or repeated. timeout_s ≤300 (default 60). Reads " +
				"the hub's cached list (never a machine); at most 3 waits per person at once." + sessionCaveat,
			InputSchema: obj(map[string]any{
				"ids":       map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"until":     map[string]any{"type": "string", "enum": []string{"needs_you", "done", "any"}},
				"cursor":    map[string]any{"type": "string"},
				"timeout_s": map[string]any{"type": "integer", "minimum": 1, "maximum": 300},
			}),
		},
	}
}
