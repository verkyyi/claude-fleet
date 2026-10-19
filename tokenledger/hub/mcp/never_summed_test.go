// internal/mcp/never_summed_test.go
//
// Issue #135: "never summed" is stated on more than one face of this hub, and
// until now nothing compared the copies.
//
// Three faces said it. The dashboard's own sentence is gone (C5 #125 deleted it
// as a same-screen duplicate of the server's). The two that remain do not share
// a source: internal/api writes it as acrossNote (query.go), scopeNoteAll
// (i18n.go) and the shareDisclaimer that travels beside every figure, while
// internal/mcp defines its OWN scopeNote rather than importing api's --
// deliberately, and with different wording, because its reader is a model and
// has to be told what a human infers from five separate gauges standing side by
// side. Each package's tests only ever read its own copy, so the copies could
// drift apart with nothing going red.
//
// This guard does not compare wording, then. It compares CLAIMS:
//
//	(1) rate-limit utilization is never summed across subscriptions
//	(2) tokens -- and each source's own cost -- are additive
//	(3) cost is never added ACROSS sources
//
// Deleting one from a copy turns this red; rewording it does not, as long as
// the new wording still says it -- each claim below is a set of alternatives,
// not a fixed string. MCP's wording especially is a contract with a machine
// reader and must not be bent to make a test easier to write: the test bends.
//
// Two layers, because a copy and an answer can fail differently. Each COPY owes
// the claims it carries today (a clause deleted out of one is red even when the
// sentence beside it still says the same thing), and each all-accounts ANSWER
// owes all three between its notes (a whole note deleted is red even when the
// remaining ones are intact).
//
// It lives in internal/mcp because that is the only package that can see both
// sides: it imports internal/api, and api cannot import it back.
package mcp

import (
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

// claim is one statement, expressed as the shapes it is allowed to arrive in.
// Every matcher must find something; each matcher is itself an alternation, so
// the prose can be rewritten around it.
type claim struct {
	name     string
	matchers []*regexp.Regexp
}

// The three claims in English -- the language MCP ships, and the language the
// dashboard's own constants are written in before translation.
var (
	utilizationNotSummedEN = claim{
		name: "utilization is never summed across subscriptions",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`(?i)utilization[^.;:\n]*(is never summed|is not\b|not additive)`),
		},
	}
	tokensAdditiveEN = claim{
		name: "tokens, and each source's own cost, are additive",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`(?i)tokens?[^.;\n]*\b(are|is) additive`),
			regexp.MustCompile(`(?i)(notional costs? are additive|each source'?s cost)`),
		},
	}
	costNotAcrossSourcesEN = claim{
		name: "cost is never added across sources",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`(?i)(cost is reported per source|never summed across|never added across sources|neither is cost across sources)`),
		},
	}
	allThreeEN = []claim{utilizationNotSummedEN, tokensAdditiveEN, costNotAcrossSourcesEN}
)

// The same three in Chinese. Only the dashboard's server-side prose is
// translated -- MCP answers a model and ships English alone.
var (
	utilizationNotSummedZh = claim{
		name: "利用率不跨订阅相加",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`利用率[^。；\n]*(永远不相加|永不相加|不相加|不能)`),
		},
	}
	tokensAdditiveZh = claim{
		name: "token 与各来源自身的费用可加",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`(?i)(token|假想成本)[^。；\n]*(可加|可以相加)`),
		},
	}
	costNotAcrossSourcesZh = claim{
		name: "费用不跨来源相加",
		matchers: []*regexp.Regexp{
			regexp.MustCompile(`(不跨来源相加|按来源分别报告)`),
		},
	}
	allThreeZh = []claim{utilizationNotSummedZh, tokensAdditiveZh, costNotAcrossSourcesZh}
)

// face is one piece of prose a caller can actually receive, and what it owes
// them. Taken from the running servers rather than from the constants behind
// them: a note nobody serves is not a claim this hub makes -- and api's copies
// are unexported anyway, reachable from here only as output.
type face struct {
	name   string
	prose  string
	claims []claim
}

// TestNeverSummed_EveryCopyKeepsItsClaims is the cross-package guard: one face
// per copy of the claim, each holding the clauses it carries today. A copy that
// loses one while its neighbours keep theirs is exactly the drift that went
// unnoticed before this test, so the copies are read one at a time.
func TestNeverSummed_EveryCopyKeepsItsClaims(t *testing.T) {
	for _, f := range neverSummedCopies(t, newNeverSummedHub(t)) {
		t.Run(f.name, func(t *testing.T) {
			for _, c := range f.claims {
				for _, m := range c.matchers {
					if !m.MatchString(f.prose) {
						t.Errorf("%s no longer states %q\nmatcher: %s\nprose:   %s",
							f.name, c.name, m, f.prose)
					}
				}
			}
		})
	}
}

// TestNeverSummed_EveryAnswerStatesAllThree is the other half: whichever door
// an all-accounts answer came through, and whichever language it was asked in,
// the notes it carries state all three between them. This is what survives a
// note being dropped from a payload rather than reworded inside it.
func TestNeverSummed_EveryAnswerStatesAllThree(t *testing.T) {
	for _, f := range neverSummedAnswers(t, newNeverSummedHub(t)) {
		t.Run(f.name, func(t *testing.T) {
			for _, c := range f.claims {
				if !claimHolds(f.prose, c) {
					t.Errorf("an all-accounts answer from %s does not state %q anywhere:\n%s",
						f.name, c.name, f.prose)
				}
			}
		})
	}
}

// TestNeverSummed_AClaimGoingMissingIsRed keeps both guards honest. A matcher
// loose enough to hit anything would pass forever and catch nothing; cutting
// the clauses that carry a claim must make that claim fail.
func TestNeverSummed_AClaimGoingMissingIsRed(t *testing.T) {
	hub := newNeverSummedHub(t)
	faces := append(neverSummedCopies(t, hub), neverSummedAnswers(t, hub)...)
	for _, f := range faces {
		for _, c := range f.claims {
			if cut := withoutClaim(f.prose, c); claimHolds(cut, c) {
				t.Errorf("%s: %q still reads as present after the clauses making it were cut -- "+
					"the matcher is too loose to notice a deletion\nleft: %s", f.name, c.name, cut)
			}
		}
	}
}

// hub is both doors onto one store, with two subscriptions behind them so every
// answer below is an all-accounts answer.
type hub struct {
	mcp  *httptest.Server
	http *httptest.Server
}

func newNeverSummedHub(t *testing.T) hub {
	t.Helper()
	ts, st := newMCP(t)
	h := hub{mcp: ts, http: httpBeside(t, st)}
	seed(t, st, "acct-a", "ep-1", "/a", "a1")
	seed(t, st, "acct-b", "ep-2", "/b", "b1")
	return h
}

// neverSummedCopies is one face per copy of the claim, named by where it is
// written. What each owes is what it says today: api splits the three across
// the note beside the figures and the disclaimer travelling with them, while
// MCP states all three in one breath because a model reads one field.
func neverSummedCopies(t *testing.T, h hub) []face {
	t.Helper()
	limitsEN, limitsZh, usageEN, usageZh := h.answers(t)

	return []face{
		{"api acrossNote", fieldProse(t, "/v1/limits note", limitsEN, "note"),
			[]claim{utilizationNotSummedEN, tokensAdditiveEN}},
		{"api acrossNote zh-CN", fieldProse(t, "/v1/limits note zh-CN", limitsZh, "note"),
			[]claim{utilizationNotSummedZh, tokensAdditiveZh}},

		{"api scopeNoteAll", fieldProse(t, "/v1/usage scope_note", usageEN, "scope_note"),
			[]claim{utilizationNotSummedEN, tokensAdditiveEN}},
		{"api scopeNoteAll zh-CN", fieldProse(t, "/v1/usage scope_note zh-CN", usageZh, "scope_note"),
			[]claim{utilizationNotSummedZh, tokensAdditiveZh}},

		{"api shareDisclaimer", fieldProse(t, "/v1/usage disclaimer", usageEN, "disclaimer"),
			[]claim{costNotAcrossSourcesEN}},
		{"api shareDisclaimer zh-CN", fieldProse(t, "/v1/usage disclaimer zh-CN", usageZh, "disclaimer"),
			[]claim{costNotAcrossSourcesZh}},

		{"mcp scopeNote", fieldProse(t, "usage_by_endpoint scope_note", h.byEndpoint(t), "scope_note"), allThreeEN},
		{"mcp account argument", h.accountArg(t), allThreeEN},
	}
}

// neverSummedAnswers is the same prose grouped the way a caller meets it: every
// note one answer carries, joined.
func neverSummedAnswers(t *testing.T, h hub) []face {
	t.Helper()
	limitsEN, limitsZh, usageEN, usageZh := h.answers(t)

	return []face{
		{"api GET /v1/limits", allProse(t, "/v1/limits", limitsEN), allThreeEN},
		{"api GET /v1/limits zh-CN", allProse(t, "/v1/limits zh-CN", limitsZh), allThreeZh},
		{"api GET /v1/usage", allProse(t, "/v1/usage", usageEN), allThreeEN},
		{"api GET /v1/usage zh-CN", allProse(t, "/v1/usage zh-CN", usageZh), allThreeZh},
		{"mcp usage_by_endpoint", allProse(t, "usage_by_endpoint", h.byEndpoint(t)), allThreeEN},
	}
}

func (h hub) answers(t *testing.T) (limitsEN, limitsZh, usageEN, usageZh map[string]any) {
	t.Helper()
	getJSON(t, h.http, "/v1/limits?account=all", &limitsEN)
	getJSON(t, h.http, "/v1/limits?account=all&locale=zh-CN", &limitsZh)
	getJSON(t, h.http, "/v1/usage?by=model&account=all", &usageEN)
	getJSON(t, h.http, "/v1/usage?by=model&account=all&locale=zh-CN", &usageZh)
	return
}

func (h hub) byEndpoint(t *testing.T) map[string]any {
	t.Helper()
	return toolPayload(t, call(t, h.mcp, "usage_by_endpoint", map[string]any{"account": "all"}), "usage_by_endpoint")
}

// accountArg is what a model reads BEFORE it asks anything: the description of
// the "account" argument, where MCP states the rule for the scope it is about
// to be handed. Every tool taking the argument shares one description, so the
// distinct texts are what matter, not how many tools repeat them.
func (h hub) accountArg(t *testing.T) string {
	t.Helper()
	tools, ok := rpc(t, h.mcp, "tools/list", nil)["result"].(map[string]any)["tools"].([]any)
	if !ok {
		t.Fatal("tools/list returned no tools")
	}
	seen := map[string]bool{}
	var texts []string
	for _, raw := range tools {
		tool, _ := raw.(map[string]any)
		schema, _ := tool["inputSchema"].(map[string]any)
		props, _ := schema["properties"].(map[string]any)
		account, _ := props["account"].(map[string]any)
		desc, _ := account["description"].(string)
		if desc != "" && !seen[desc] {
			seen[desc] = true
			texts = append(texts, desc)
		}
	}
	if len(texts) == 0 {
		t.Fatal("no tool describes its account argument")
	}
	return strings.Join(texts, "\n")
}

// claimHolds reports whether every matcher of a claim finds its statement.
func claimHolds(prose string, c claim) bool {
	for _, m := range c.matchers {
		if !m.MatchString(prose) {
			return false
		}
	}
	return true
}

// withoutClaim drops the clauses stating a claim, standing in for the edit that
// would delete it for real. Clause-wise rather than sentence-wise: these notes
// pack two statements into one sentence, separated by a semicolon.
func withoutClaim(prose string, c claim) string {
	var kept []string
	for _, clause := range strings.FieldsFunc(prose, func(r rune) bool {
		return strings.ContainsRune(".;:\n。；：", r)
	}) {
		if !claimTouches(clause, c) {
			kept = append(kept, clause)
		}
	}
	return strings.Join(kept, ". ")
}

func claimTouches(clause string, c claim) bool {
	for _, m := range c.matchers {
		if m.MatchString(clause) {
			return true
		}
	}
	return false
}

// noteKeys are the fields an answer explains itself in. An all-accounts
// /v1/limits keeps the per-subscription disclaimer one level down, inside each
// entry, which is why the walk below is recursive rather than a top-level read.
var noteKeys = map[string]bool{"note": true, "scope_note": true, "disclaimer": true}

// allProse joins every explanatory string in a decoded answer.
func allProse(t *testing.T, what string, v any) string {
	t.Helper()
	notes := notesUnder(v, nil)
	if len(notes) == 0 {
		t.Fatalf("%s carries no note, scope_note or disclaimer at all", what)
	}
	return strings.Join(notes, "\n")
}

// fieldProse joins one field's text wherever it appears, so a copy is read on
// its own rather than rescued by the sentence next to it.
func fieldProse(t *testing.T, what string, v any, key string) string {
	t.Helper()
	notes := notesUnder(v, map[string]bool{key: true})
	if len(notes) == 0 {
		t.Fatalf("%s is gone: the answer carries no %q", what, key)
	}
	return strings.Join(dedupe(notes), "\n")
}

// notesUnder collects the explanatory strings of an answer. A nil want means
// every note key.
func notesUnder(v any, want map[string]bool) []string {
	if want == nil {
		want = noteKeys
	}
	var out []string
	var walk func(any)
	walk = func(node any) {
		switch n := node.(type) {
		case map[string]any:
			for k, child := range n {
				if s, ok := child.(string); ok && want[k] && s != "" {
					out = append(out, s)
				}
				walk(child)
			}
		case []any:
			for _, child := range n {
				walk(child)
			}
		}
	}
	walk(v)
	return out
}

// dedupe keeps one of each: /v1/limits repeats the same disclaimer once per
// subscription, and three identical copies prove nothing a single one does not.
func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
