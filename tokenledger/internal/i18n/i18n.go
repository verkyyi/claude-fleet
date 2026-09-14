// Package i18n carries the hub's own prose in more than one language.
//
// Only the DASHBOARD is translated. Three things deliberately are not:
//
//   - `price_basis` and everything else written into an event's details at
//     ingest time. Those record which rate actually priced the event; they are
//     an audit trail, and a historical record must not change wording because
//     of who is reading it.
//   - the MCP surface (internal/mcp). Its consumer is an agent, and its notes
//     are contract text that a model reads and quotes; a note that changes
//     language per caller is a note no prompt can rely on.
//   - identifiers: source keys, model ids, account uuids.
//
// The English text stays the source: every Text below has an EN entry, it is
// what the existing exported constants hold, and it is what any locale falls
// back to. A missing translation shows English, never an empty string.
package i18n

import (
	"net/http"
	"strings"
)

// The locales this build ships. EN is the fallback for every other.
const (
	EN   = "en"
	ZhCN = "zh-CN"
)

// Locales is every locale this build has a dictionary for, in display order.
var Locales = []string{EN, ZhCN}

// Normalize maps an arbitrary tag onto one of Locales.
//
// An exact match first, then the primary subtag: zh-TW and zh-HK resolve to
// zh-CN on purpose. This build ships no Traditional text, and Simplified is far
// closer to what that reader wants than English is. Anything else is English.
func Normalize(tag string) string {
	tag = strings.TrimSpace(tag)
	if tag == "" {
		return EN
	}
	for _, l := range Locales {
		if strings.EqualFold(l, tag) {
			return l
		}
	}
	primary, _, _ := strings.Cut(strings.ToLower(tag), "-")
	for _, l := range Locales {
		lp, _, _ := strings.Cut(strings.ToLower(l), "-")
		if lp == primary {
			return l
		}
	}
	return EN
}

// FromRequest resolves the locale one request should be answered in.
//
// The `locale` query parameter wins: the dashboard sends the language the
// viewer actually chose, which may differ from what their browser advertises.
// Accept-Language is the fallback, so a bare curl or an older dashboard build
// still gets something sensible rather than always English.
func FromRequest(r *http.Request) string {
	if r == nil {
		return EN
	}
	if v := r.URL.Query().Get("locale"); v != "" {
		return Normalize(v)
	}
	return FromAcceptLanguage(r.Header.Get("Accept-Language"))
}

// FromAcceptLanguage reads the first tag of an Accept-Language header this
// build has a dictionary for. Quality values are ignored: browsers send their
// list in preference order anyway, and honouring q= would add a parser for a
// distinction two locales cannot express.
func FromAcceptLanguage(header string) string {
	for _, part := range strings.Split(header, ",") {
		tag, _, _ := strings.Cut(strings.TrimSpace(part), ";")
		tag = strings.TrimSpace(tag)
		if tag == "" || tag == "*" {
			continue
		}
		if got := Normalize(tag); got != EN {
			return got
		}
		// An explicit English tag is an answer, not a miss.
		if primary, _, _ := strings.Cut(strings.ToLower(tag), "-"); primary == "en" {
			return EN
		}
	}
	return EN
}

// Text is one piece of prose in every language this build has it in.
//
// A map rather than a struct with one field per locale: adding a third language
// should be a new key beside the text it translates, not an edit to every
// declaration in the tree.
type Text map[string]string

// In returns the text in `locale`, falling back to English.
//
// An empty translation counts as missing. A half-filled dictionary should show
// the English sentence — a blank where a caveat about money belongs is the one
// outcome worse than the wrong language.
func (t Text) In(locale string) string {
	if s, ok := t[Normalize(locale)]; ok && s != "" {
		return s
	}
	return t[EN]
}
