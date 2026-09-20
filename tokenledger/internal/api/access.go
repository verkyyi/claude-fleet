package api

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The door map: one page that says how a person, an agent or a shipper gets
// into THIS hub, what each way in costs them in credentials, and what it lets
// them do once they are through.
//
// # Why this exists
//
// The package comment one directory up says the closest thing this repository
// had to a statement about entrances: "All four live in one process on one port
// so a self-hoster deploys one thing." That is true, and it is a sentence about
// DEPLOYMENT. It was read as a sentence about ACCESS, and those are not the
// same claim: one process is not one entrance. A person wanting the dashboard
// needs a URL and a token; an operator needs a shell on the hub; an agent needs
// the MCP URL and the same token; a scheduler needs the binary on its own
// machine. Six ways in, four kinds of credential, and until this file nothing
// in the binary would tell you so — `grep` for "portal", "unified" or "单一入口"
// found nothing, and the `<details id="ops">` block on the dashboard is a fold,
// not a front door.
//
// # What this is NOT
//
// It is a description, not a control plane. Nothing here mints, revokes,
// widens or moves a credential, and no CLI operation has been put behind HTTP.
// That restraint is the point: `enroll`, `team` and `plan` are hub-local
// because a machine that could name its own team could move its spend onto
// another team's budget. A page that explains a boundary must not be the thing
// that erodes it.
//
// # Why it is behind the viewer gate
//
// It reports what is configured on this hub — SSO on or off, who the tailnet
// allowlist names, whether badges are public. That is exactly the shape of
// answer /enter refuses to give: /enter is mounted unconditionally and 404s
// when SSO is unconfigured, so the ROUTE's existence never leaks the feature to
// someone with no credential. This page does not change that, and must not: it
// sits behind viewerOnly, so only a reader who already came through one door
// learns about the others. An unauthenticated prober still gets the same 401
// it always got.

// Door is one way into this hub.
type Door struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Via is "http" or "hub-shell". The CLI is a door like any other and the
	// table says so, because leaving it out is how "one process" got read as
	// "one entrance" in the first place.
	Via string `json:"via"`
	// Where is the URL paths for an HTTP door, or the command names for the
	// CLI one.
	Where []string `json:"where"`
	// Credential is what a caller must hold. Never a credential itself.
	Credential string `json:"credential"`
	// Can is what the door lets you do once you are through.
	Can string `json:"can"`
	// State is "open" (reachable, needs the credential named), "public"
	// (reachable with none) or "off" (not wired up on this hub).
	State string `json:"state"`
	// Note is what is actually true HERE, as opposed to what is true of the
	// software. It is the half a README cannot write.
	Note string `json:"note"`
}

// SSOFacts is what this hub will say about its WeCom wiring. The two secrets
// on api.SSO — the ticket key and the session key — are absent by
// construction: one verifies a ticket and one signs a session, so either would
// let a holder conjure a signed-in person out of nothing.
type SSOFacts struct {
	Enabled      bool    `json:"enabled"`
	EnterURL     string  `json:"enter_url,omitempty"`
	Slug         string  `json:"slug,omitempty"`
	SessionHours float64 `json:"session_hours,omitempty"`
}

// ListenerFacts is where `ccquota hub` actually bound. Presentation only.
type ListenerFacts struct {
	HTTP     []string `json:"http,omitempty"`
	HTTPS    string   `json:"https,omitempty"`
	HTTPSURL string   `json:"https_url,omitempty"`
}

// ShareFacts counts the redacted public links, never lists their tokens.
type ShareFacts struct {
	Active int `json:"active"`
	Total  int `json:"total"`
}

// HubFacts is the configuration a reader cannot infer from the software.
type HubFacts struct {
	// ViewerAuth is "token" or "off (--no-auth)". The token itself never
	// appears, here or anywhere else this package writes.
	ViewerAuth     string         `json:"viewer_auth"`
	SSO            SSOFacts       `json:"sso"`
	TailnetViewers []string       `json:"tailnet_viewers"`
	PublicBadges   bool           `json:"public_badges"`
	MCP            bool           `json:"mcp"`
	Dashboard      bool           `json:"dashboard"`
	Listeners      ListenerFacts  `json:"listeners"`
	ShareLinks     ShareFacts     `json:"share_links"`
	Enrollments    map[string]int `json:"enrollments"`
}

// AccessMap is the whole answer to "how do I get in, and what does that let me
// do".
type AccessMap struct {
	GeneratedAt time.Time `json:"generated_at"`
	// OneProcess is the correction this page was written to make. It travels
	// in the payload rather than only in the HTML so an agent reading
	// /v1/access gets the caveat too.
	OneProcess string   `json:"one_process"`
	Doors      []Door   `json:"doors"`
	Hub        HubFacts `json:"hub"`
}

const oneProcessNote = "One process on one port is a deployment fact, not an access fact. " +
	"These doors share a binary; they do not share a credential."

// handleAccess reports the door map. Read-only, and it reads no secret: every
// field below is either a fixed description of a route or a yes/no about
// whether that route is wired up here.
func (s *Server) handleAccess(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		httpError(w, http.StatusMethodNotAllowed, "GET required")
		return
	}
	m := AccessMap{
		GeneratedAt: time.Now().UTC(),
		OneProcess:  oneProcessNote,
		Hub:         s.hubFacts(),
	}
	m.Doors = s.doors(m.Hub)
	writeJSON(w, http.StatusOK, m)
}

func (s *Server) hubFacts() HubFacts {
	// An empty allowlist is [], never null: "nobody gets in without a token"
	// is an answer, and a reader who has to tell it apart from "this hub did
	// not say" has been handed the ambiguity this page exists to remove.
	tailnet := s.Tailnet.Logins()
	if tailnet == nil {
		tailnet = []string{}
	}
	f := HubFacts{
		ViewerAuth:     "token",
		TailnetViewers: tailnet,
		PublicBadges:   s.PublicBadges,
		MCP:            s.MCP != nil,
		Dashboard:      s.UI != nil,
		Listeners:      s.Listeners,
		Enrollments:    map[string]int{},
	}
	if s.ViewerToken == "" {
		f.ViewerAuth = "off (--no-auth)"
	}
	if s.SSO.ready() {
		f.SSO = SSOFacts{
			Enabled:      true,
			EnterURL:     s.SSO.EnterURL,
			Slug:         s.SSO.Slug,
			SessionHours: s.SSO.ttl().Hours(),
		}
	}
	// Both of these are best-effort. A hub whose database hiccups should still
	// be able to tell a reader where the doors are; a zero count is reported
	// as what it is by the note beside it, never dressed up as "none".
	if s.Store != nil {
		if links, err := s.Store.ListShareLinks(); err == nil {
			now := time.Now()
			for _, l := range links {
				f.ShareLinks.Total++
				if l.Active(now) {
					f.ShareLinks.Active++
				}
			}
		}
		if counts, err := s.Store.EnrollmentCounts(); err == nil {
			f.Enrollments = counts
		}
	}
	return f
}

// enrolled sums the enrollment kinds that push or read through a given door.
func (f HubFacts) enrolled(kinds ...string) int {
	n := 0
	for _, k := range kinds {
		n += f.Enrollments[k]
	}
	return n
}

// doors is the table itself: one row per way in, in the order a reader should
// meet them — the two human doors, then the two agent doors, then the machine
// door, then the two that are open on purpose, then the one that is not on
// HTTP at all.
//
// It is built here, beside Handler(), rather than written into the page,
// because a door that is described in HTML is a door that drifts from the
// router the first time someone adds a route.
func (s *Server) doors(f HubFacts) []Door {
	ways := []string{}
	if f.ViewerAuth == "token" {
		ways = append(ways, "the viewer token (`?token=` once, then a 30-day cookie)")
	}
	if f.SSO.Enabled {
		ways = append(ways, "a WeCom session from /enter")
	}
	if n := len(f.TailnetViewers); n > 0 {
		ways = append(ways, plural(n, "named tailnet login", "named tailnet logins")+" with no token")
	}
	dashCred := "the viewer token, a WeCom session, or a named tailnet peer"
	dashNote := "Here: " + joinAnd(ways) + "."
	if f.ViewerAuth != "token" {
		dashCred = "nothing — this hub runs with --no-auth"
		dashNote = "Here: NO viewer token is set, so every viewer route below is open to " +
			"anything that can reach the socket. The hub refuses a non-loopback bind in this state."
	}

	return []Door{
		{
			ID: "dashboard", Name: "The dashboard", Via: "http",
			Where:      []string{"/", "/u/<os login>", "/growth"},
			Credential: dashCred,
			Can: "Read every figure this hub holds: spend, usage, live sessions, alerts, repo progress. " +
				"/u/<login> is one person's totals; /growth is the revenue ledger, the most sensitive " +
				"figures in this binary, behind the same gate as the rest.",
			State: pick(f.Dashboard, "open", "off"),
			Note:  dashNote + pick(f.Dashboard, "", " This binary was built without the dashboard, so / answers JSON instead."),
		},
		{
			ID: "enter", Name: "The SSO way in", Via: "http",
			Where:      []string{"/enter"},
			Credential: "a 90-second ticket the company's authorization service signed",
			Can: "Exchange that ticket for this hub's own session cookie, and nothing else. " +
				"It grants no read by itself. OAuth completes on ai.24haowan.com — the corp allows one " +
				"callback domain and it is not this host — so only the ticket crosses.",
			// NOT "public", even though it is the one route outside the viewer
			// gate. "Public" on this page means "no credential", and /enter
			// demands a signed ticket — labelling it public would contradict
			// the credential named one line above it. When SSO is unconfigured
			// the honest word is "off": the route answers, and it is still not
			// a way in.
			State: pick(f.SSO.Enabled, "open", "off"),
			Note: pick(f.SSO.Enabled,
				"Here: wired up, sending signed-out browsers to "+f.SSO.EnterURL+
					". Sessions last "+hours(f.SSO.SessionHours)+".",
				"Here: NOT configured, so /enter answers 404. The route is mounted anyway, on purpose: "+
					"whether it exists must not tell an unauthenticated prober whether SSO is on."),
		},
		{
			ID: "api", Name: "The query API", Via: "http",
			Where:      []string{"/v1/summary", "/v1/usage", "/v1/history", "/v1/live/stream", "/v1/repo/…", "and ~20 more"},
			Credential: "the same viewer token, as an `Authorization: Bearer` header",
			Can: "Read the same figures as JSON, on the same gate as the dashboard — it IS the dashboard's " +
				"back end. One route writes: POST /v1/accounts/label renames a subscription.",
			State: "open",
			Note:  "Here: " + pick(f.ViewerAuth == "token", "a bearer token is required.", "ungated, because --no-auth is set."),
		},
		{
			ID: "mcp", Name: "MCP, for an agent", Via: "http",
			Where:      []string{"POST /mcp"},
			Credential: "the same viewer token again — there is no separate agent credential",
			Can: "Call the hub's read tools over JSON-RPC. Read-only by design, not by omission: a monitor " +
				"that could also pause endpoints or change quotas would need a control channel back to every " +
				"machine, which is a far larger surface than \"tell me what my fleet spent\".",
			State: pick(f.MCP, "open", "off"),
			Note:  pick(f.MCP, "Here: mounted.", "Here: not wired up on this hub, so /mcp 404s."),
		},
		{
			ID: "ingest", Name: "Shipper ingest", Via: "http",
			Where: []string{"/v1/ingest", "/v1/live/report", "/v1/collectors/quota-lease",
				"/v1/ingest/repo", "/v1/ingest/growth", "/v1/growth/latest"},
			Credential: "each shipper's OWN enrollment token from `ccquota enroll` — never the viewer token, " +
				"and revocable on its own with `ccquota endpoint retire`",
			Can: "Write: push usage batches, live session reports, repo progress or the business ledger. " +
				"The endpoint's identity comes from the token lookup, never from the body. /v1/growth/latest " +
				"reads the revenue ledger back and is gated a SECOND time on the enrollment's kind, because " +
				"every shipper here holds a token and only the growth ones may read revenue. Retiring an " +
				"endpoint closes every one of these doors to its token at once — they all resolve it through " +
				"the same lookup — so the count beside this row is live tokens, not rows in the table.",
			State: "open",
			Note: "Here: " + plural(f.enrolled("agent"), "agent", "agents") +
				", " + plural(f.enrolled("repo_shipper"), "repo shipper", "repo shippers") +
				", " + plural(f.enrolled("growth_shipper", "growth_reader"), "growth token", "growth tokens") + " enrolled.",
		},
		{
			ID: "share", Name: "A share link", Via: "http",
			Where:      []string{"/share?token=…", "/v1/share"},
			Credential: "a share token minted by `ccquota share --name …`, revocable and optionally dated",
			Can: "Read ONE redacted page: totals, scale, plan utilization, model mix. No logins, no projects, " +
				"no session detail, and costs only if the link was minted to show them. Mounted before \"/\" " +
				"so a share token can never reach a viewer route.",
			State: "open",
			Note: pick(f.ShareLinks.Total == 0,
				"Here: no share links have been minted.",
				"Here: "+plural(f.ShareLinks.Active, "active link", "active links")+
					" of "+strconv.Itoa(f.ShareLinks.Total)+" minted"+
					// Only account for a difference when there is one. "1 of 1
					// minted, the rest revoked" invents a rest.
					pick(f.ShareLinks.Active < f.ShareLinks.Total,
						"; the rest are revoked or expired.", ".")),
		},
		{
			ID: "badges", Name: "Badges and embeds", Via: "http",
			Where:      []string{"/badge/u/<login>.svg", "/badge/team/<team>.json", "/embed/u/…", "/embed/team/…"},
			Credential: pick(f.PublicBadges, "nothing — --public-badges is on", "the viewer token, like everything else"),
			Can: "Render one number as an SVG or a small live embed, for a README. This is the only surface " +
				"that may be unauthenticated, and only deliberately: a README image sends no credential and " +
				"the proxy in front of it strips cookies.",
			State: pick(f.PublicBadges, "public", "open"),
			Note: pick(f.PublicBadges,
				"Here: PUBLIC. Anything that can reach this hub can read these numbers with no credential.",
				"Here: behind the viewer token — the default. An operator who upgrades never starts serving without auth by surprise."),
		},
		{
			ID: "healthz", Name: "Liveness", Via: "http",
			Where:      []string{"/healthz"},
			Credential: "nothing",
			Can:        `Learn that the process is up. It answers a fixed {"status":"ok"} and reads nothing — not the database, not the configuration.`,
			State:      "public",
			Note:       "Here: always on, and deliberately incapable of saying anything else.",
		},
		{
			ID: "cli", Name: "The CLI, on the hub machine", Via: "hub-shell",
			Where: []string{"ccquota enroll", "ccquota share", "ccquota team", "ccquota plan", "ccquota name"},
			Credential: "a shell on the machine running the hub, and read/write on its SQLite file — " +
				"no token, and no HTTP route exists for any of it",
			Can: "Mint and revoke credentials, name a subscription, record what a plan actually costs, " +
				"allocate an endpoint's spend to a team. This is the only door that can CHANGE who gets in.",
			State: "open",
			Note: "Here, and everywhere: not reachable over the network, on purpose. A machine that could " +
				"name its own team could move its spend onto another team's budget. `ccquota report`, " +
				"`ccquota agent`, `ccquota budget` and `ccquota stamp` run anywhere — they hold their own " +
				"credential or need none.",
		},
	}
}

// serveAccessPage serves the door map's page.
//
// Its own file, like the share and user pages, rather than a route inside the
// dashboard: the dashboard is a module set that boots ~20 requests once you
// are through the gate, and a page whose whole job is to explain how to get in
// should not be the heaviest thing to load after you have.
//
// (serveSharePage and serveUserPage stream their own files the same way. They
// are deliberately NOT folded together here: the share page sets no-store and
// this one sets no-cache, and unifying them would mean changing the share
// page's caching as a side effect of a documentation change.)
func (s *Server) serveAccessPage(w http.ResponseWriter, r *http.Request) {
	if s.UI == nil {
		httpError(w, http.StatusNotFound, "this binary was built without the UI")
		return
	}
	f, err := s.UI.Open("access.html")
	if err != nil {
		httpError(w, http.StatusNotFound, "no access page in this build")
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	rs, ok := f.(interface {
		Read([]byte) (int, error)
		Seek(int64, int) (int64, error)
	})
	if !ok {
		httpError(w, http.StatusInternalServerError, "unreadable page")
		return
	}
	w.Header().Set("Cache-Control", "no-cache")
	http.ServeContent(w, r, "access.html", st.ModTime(), rs)
}

// pick is the ternary this file would otherwise spell out eight times. Every
// row below has a "here" half that differs by one configuration bit, and eight
// four-line if/else blocks between the prose obscures the prose.
func pick(cond bool, yes, no string) string {
	if cond {
		return yes
	}
	return no
}

// plural writes a count with its own noun, so a note reads as a sentence
// rather than as a label with a number stuck to it.
func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// hours formats a session lifetime. --sso-session-hours is an int flag, so a
// fraction only arrives from a hand-built SSO struct; %g keeps that honest
// rather than truncating it to a wrong whole number.
func hours(h float64) string {
	if h == 1 {
		return "1 hour"
	}
	return strconv.FormatFloat(h, 'g', -1, 64) + " hours"
}

// joinAnd renders a list the way a person would say it out loud.
func joinAnd(parts []string) string {
	switch len(parts) {
	case 0:
		return "nothing"
	case 1:
		return parts[0]
	case 2:
		return parts[0] + " and " + parts[1]
	}
	return strings.Join(parts[:len(parts)-1], ", ") + ", and " + parts[len(parts)-1]
}
