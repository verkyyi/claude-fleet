package api

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The door map: one page that says how a person, an agent or a machine gets
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
// It reports what is configured on this hub — GitHub sign-in on or off, how
// many admins the deploy names, whether badges are public. That is exactly the
// shape of answer /signin refuses to give: it is mounted unconditionally and
// 404s when GitHub sign-in is unconfigured, so the ROUTE's existence never
// leaks the feature to someone with no credential. This page does not change
// that, and must not: it sits behind viewerOnly, so only a reader who already
// came through one door learns about the others. An unauthenticated prober
// still gets the same 401 it always got.

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

// ListenerFacts is where `ccquota hub` actually bound. Presentation only.
type ListenerFacts struct {
	HTTP     []string `json:"http,omitempty"`
	HTTPS    string   `json:"https,omitempty"`
	HTTPSURL string   `json:"https_url,omitempty"`
}

// HubFacts is the configuration a reader cannot infer from the software.
type HubFacts struct {
	// GitHub is whether GitHub sign-in is wired up (claude-fleet#1984), and
	// how many admin names the deploy gives it. Never the client values.
	GitHub       bool `json:"github"`
	GitHubAdmins int  `json:"github_admins"`
	// ViewerAuth is "token" or "off (--no-auth)". The token itself never
	// appears, here or anywhere else this package writes.
	ViewerAuth   string         `json:"viewer_auth"`
	PublicBadges bool           `json:"public_badges"`
	PublicMeter  bool           `json:"public_meter"`
	MCP          bool           `json:"mcp"`
	Dashboard    bool           `json:"dashboard"`
	Listeners    ListenerFacts  `json:"listeners"`
	Enrollments  map[string]int `json:"enrollments"`
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
	f := HubFacts{
		ViewerAuth:   "token",
		PublicBadges: s.publicBadges(),
		PublicMeter:  s.publicMeter(),
		MCP:          s.MCP != nil,
		Dashboard:    s.UI != nil,
		Listeners:    s.Listeners,
		Enrollments:  map[string]int{},
	}
	if s.ViewerToken == "" {
		f.ViewerAuth = "off (--no-auth)"
	}
	if s.GitHub.ready() {
		f.GitHub, f.GitHubAdmins = true, len(s.GitHub.Admins)
	}
	// Best-effort. A hub whose database hiccups should still be able to tell a
	// reader where the doors are; a zero count is reported as what it is by
	// the note beside it, never dressed up as "none".
	if s.Store != nil {
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
// meet them — the human doors, then the agent doors, then the machine door,
// then the ones that are open on purpose, then the one that is not on HTTP at
// all.
//
// It is built here, beside Handler(), rather than written into the page,
// because a door that is described in HTML is a door that drifts from the
// router the first time someone adds a route.
func (s *Server) doors(f HubFacts) []Door {
	ways := []string{}
	if f.GitHub {
		ways = append(ways, "a GitHub sign-in on this hub's list (/signin)")
	}
	if f.ViewerAuth == "token" {
		ways = append(ways, "the viewer token (`?token=` once, then a 30-day cookie)")
	}
	dashCred := "a GitHub sign-in on the list, or the viewer token"
	dashNote := "Here: " + joinAnd(ways) + "."
	if f.ViewerAuth != "token" {
		dashCred = "nothing — this hub runs with --no-auth"
		dashNote = "Here: NO viewer token is set, so every viewer route below is open to " +
			"anything that can reach the socket. The hub refuses a non-loopback bind in this state."
	}

	return []Door{
		{
			ID: "dashboard", Name: "The dashboard", Via: "http",
			Where:      []string{"/", "/sessions", "/connect", "/quota", "/config"},
			Credential: dashCred,
			Can: "Read what the viewer's role lets them see (claude-fleet#1985, #1989): an admin every " +
				"figure this hub holds, a user their own usage, sessions, devices and settings.",
			State: pick(f.Dashboard, "open", "off"),
			Note:  dashNote + pick(f.Dashboard, "", " This binary was built without the dashboard, so / answers JSON instead."),
		},
		{
			ID: "github", Name: "Sign in with GitHub", Via: "http",
			Where:      []string{"/signin", "/auth/github/start", "/auth/github/callback", "/logout"},
			Credential: "a GitHub account whose numeric ID is on this hub's list",
			Can: "Exchange a GitHub sign-in for this hub's own session cookie. GitHub is asked only who " +
				"you are (no scope); its token is used once and dropped. Admins come from the deploy " +
				"(CCQUOTA_GITHUB_ADMINS), users from the list; a username is pinned to the first ID seen " +
				"holding it, and the list is re-read on every request, so removal takes effect at once.",
			State: pick(f.GitHub, "open", "off"),
			Note: pick(f.GitHub,
				"Here: wired up, "+plural(f.GitHubAdmins, "admin name", "admin names")+" from the deploy. Signed-out browsers are sent to /signin.",
				"Here: NOT configured, so /signin answers 404."),
		},
		{
			ID: "api", Name: "The query API", Via: "http",
			Where:      []string{"/v1/summary", "/v1/usage", "/v1/history", "/v1/live/stream", "and ~20 more"},
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
			Where: []string{"/v1/ingest", "/v1/live/report", "/v1/collectors/quota-lease"},
			Credential: "each shipper's OWN enrollment token from `ccquota enroll` — never the viewer token, " +
				"and revocable on its own with `ccquota endpoint retire`",
			Can: "Write: push Claude and Codex usage batches and live session reports. " +
				"The endpoint's identity comes from the token lookup, never from the body. Retiring an " +
				"endpoint closes every one of these doors to its token at once — they all resolve it through " +
				"the same lookup — so the count beside this row is live tokens, not rows in the table.",
			State: "open",
			Note:  "Here: " + plural(f.enrolled("agent"), "agent", "agents") + " enrolled.",
		},
		{
			ID: "badges", Name: "Badges and embeds", Via: "http",
			Where:      []string{"/badge/u/<login>.svg", "/badge/team/<team>.json", "/embed/u/…", "/embed/team/…"},
			Credential: pick(f.PublicBadges, "nothing — "+PublicBadgesKey+" is on", "the viewer token, like everything else"),
			Can: "Render one number as an SVG or a small live embed, for a README. This is the only surface " +
				"that may be unauthenticated, and only deliberately: a README image sends no credential and " +
				"the proxy in front of it strips cookies.",
			State: pick(f.PublicBadges, "public", "open"),
			Note: pick(f.PublicBadges,
				"Here: PUBLIC. Anything that can reach this hub can read these numbers with no credential.",
				"Here: behind the viewer token — the default. An operator who upgrades never starts serving without auth by surprise."),
		},
		{
			ID: "meter", Name: "Front page and public counter", Via: "http",
			Where:      []string{"/ (signed out)", "/meter.json", "/odometer.svg"},
			Credential: "nothing",
			Can: "Read what claudefleet is, and the hub's one lifetime token total with its last replay window. " +
				"No person, machine, account or repository is named; a signed-out \"/\" is the front page, every other path still asks.",
			State: pick(f.PublicMeter, "public", "off"),
			Note: pick(f.PublicMeter,
				"Here: PUBLIC — "+MeterKey+" is on (the default). 24haowan.com reads /meter.json from the browser.",
				"Here: "+MeterKey+" is off, so /meter.json and /odometer.svg answer 404; the front page shows no figure."),
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
			ID: "version", Name: "Build version", Via: "http",
			Where:      []string{"/version", "/v1/fleet/client-settings"},
			Credential: "nothing",
			Can:        `Learn which build this is: the version stamp and the git commit it names (claude-fleet#1696), so fleet-doctor can compare the hub with the stable tag without cluster access, and which client it hands out (client_version, client_compat, min_client_compat — claude-fleet#1722; with stable known, client_version is refs/tags/stable's commit and client_url where its files are — claude-fleet#1805). With the fleet module on, /v1/fleet/client-settings answers the team's client defaults: whitelisted keys only, never a credential (refused at write). Reads nothing else.`,
			State:      "public",
			Note:       "Here: always on. The commit is of a public repository; it says which client this hub hands out, nothing about who uses it.",
		},
		{
			ID: "cli", Name: "The CLI, on the hub machine", Via: "hub-shell",
			Where: []string{"ccquota enroll", "ccquota team", "ccquota plan", "ccquota name"},
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

// serveStandalonePage serves one self-contained page from the built UI.
func (s *Server) serveStandalonePage(w http.ResponseWriter, r *http.Request, name string) {
	if s.UI == nil {
		httpError(w, http.StatusNotFound, "this binary was built without the UI")
		return
	}
	f, err := s.UI.Open(name)
	if err != nil {
		httpError(w, http.StatusNotFound, "no "+name+" in this build")
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
	http.ServeContent(w, r, name, st.ModTime(), rs)
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
