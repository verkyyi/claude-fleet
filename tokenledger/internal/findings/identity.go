package findings

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"time"
)

// A finding's identity, and what it is for.
//
// Findings are recomputed on every read -- nothing here is stored. That was
// fine while the only thing anyone could do with a finding was read it, and it
// stopped being fine the moment the operator wanted to say "I know". Saying "I
// know" about a recomputed value needs a name for the value that survives the
// recomputation, so `ID` below is the ONE thing about a finding that is
// promised to be stable across requests.
//
// # What counts as "the same finding"
//
// Four components, and nothing else:
//
//	kind      what class of problem this is (runaway_session, stale_agent, ...)
//	template  WHICH SENTENCE about it -- "has never reported" and "last
//	          reported 3h ago" are different problems with the same kind
//	severity  critical | warning | info
//	subject   WHAT the sentence is about, as an identifier (below)
//
// Deliberately NOT part of the identity: every rendered number. A runaway
// session's token count moves on every refresh, `dur()` re-rounds, a
// percentage ticks -- an identity built from the prose would change under the
// operator between the click and the next poll, and a mute would never survive
// one. The ID is a name for the PROBLEM, not for this reading of it.
//
// Severity IS part of it, and that is the load-bearing choice: it is what lets
// an escalation break through a mute. A 5-hour window silenced at 78% must
// speak up again when it crosses 90%, because "I know it is warm" is not
// consent to be surprised by it running out. The same cut makes a mute on
// free_allowance's 80% warning not cover the "allowance is gone" critical --
// which is the same rule, and the same reason.
//
// The cost of that choice is the mirror case: a critical that improves to a
// warning is a new identity too, so its mute does not carry over and the
// quieter finding has to be silenced again. That is the right way round -- a
// state change the operator has never acknowledged is exactly what they asked
// to be told about.
//
// # subject
//
// Every rule sets `Finding.subject` EXPLICITLY, from the identifiers it
// already holds -- never from Args, which is display prose. Scope would have
// been the tempting shortcut and it is wrong: four rules (spend_spike's
// blended finding, window_high, stale_agent, time_in_critical) carry no scope
// at all, so keying on it would have collapsed every account's hot window into
// one identity and let muting one subscription silence another's.
//
// Which identifier each rule uses, and why:
//
//	runaway_session   the FULL session id (Title shows only the first 8)
//	live_runaway      the full session id, same reason
//	unpriced_model    the model name
//	free_allowance    the model name
//	cache_hit_drop    the full CWD (Title shows a shortened path)
//	spend_spike       the full CWD for the per-project sentence; EMPTY for the
//	                  blended one, whose subject genuinely is "the selection"
//	                  -- there is only ever one of it, so kind+template+severity
//	                  already names it uniquely
//	time_in_critical  the account uuid when the caller supplies one, else its
//	                  label
//	window_high       the account uuid (or label) plus the window id
//	stale_agent       the endpoint id when the caller supplies one, else its
//	                  label
//
// The uuid/id-over-label preference matters: a label is the operator's display
// name, editable through POST /v1/accounts/label, and two subscriptions may
// carry the same one. Keying identity on it would mean renaming an account
// silently drops its mutes, and two same-named accounts share them. The
// fallback to a label exists only for a caller that has no id to give -- every
// in-tree gatherer has one.
//
// # Stability across a schema change
//
// idVersion is mixed into the hash. If the rule for "the same finding" ever
// changes, bumping it invalidates every stored mute at once instead of
// silently re-pointing old mutes at differently-defined findings. A forgotten
// mute that silences the wrong alert is worse than a mute that expired early.
const idVersion = "f1"

// idLen is how much of the digest we keep. 12 hex characters is 48 bits: at
// the scale of one hub's findings (tens per request, a bounded mute table) the
// collision probability is negligible, and the value has to be short enough to
// read in a URL, a log line and an MCP response.
const idLen = 12

// findingID hashes the four identity components. The separator is NUL, which
// cannot occur in a model name, a path, a uuid or a session id, so no pair of
// distinct component tuples can produce the same preimage by shifting a
// boundary.
func findingID(kind, template, severity, subject string) string {
	sum := sha256.Sum256([]byte(strings.Join(
		[]string{idVersion, kind, template, severity, subject}, "\x00")))
	return hex.EncodeToString(sum[:])[:idLen]
}

// subjectKey joins the parts of a compound subject (window_high's account and
// window). Unit separator, for the same reason findingID uses NUL: it does not
// occur in any of these identifiers.
func subjectKey(parts ...string) string { return strings.Join(parts, "\x1f") }

// firstNonEmpty returns the first identifier a caller actually supplied. It is
// how the id-over-label preference above is expressed at each call site
// without every rule growing an if.
func firstNonEmpty(vs ...string) string {
	for _, v := range vs {
		if v != "" {
			return v
		}
	}
	return ""
}

// Mute is one finding the operator has silenced, and until when.
//
// Until is NOT optional and there is no "forever". A permanently muted alert
// is a deleted alert that nobody remembers deleting: the condition stays true,
// the page stays quiet, and six months later no one can say why that rule
// never fires. An expiry makes the silence self-correcting -- the worst case
// is being told again about something already handled, which costs one click.
//
// By is who silenced it, when the hub knows (a tailnet or SSO identity). It is
// empty for a request authenticated by the shared viewer token, which names
// nobody -- and empty is the honest answer there, not a guess at which person
// holds the token.
type Mute struct {
	Until time.Time `json:"until"`
	Note  string    `json:"note,omitempty"`
	By    string    `json:"by,omitempty"`
}

// Mutes is the active silences, keyed by Finding.ID.
//
// "Active" is the caller's job: this package has no clock of its own for the
// review rules and no database at all, so it treats every entry it is handed
// as in force. store.ActiveFindingMutes is what applies the expiry, in the one
// place that can also prune the rows.
type Mutes map[string]Mute
