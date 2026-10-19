// Package badge renders a usage figure as an SVG and as shields.io endpoint
// JSON.
//
// The renderer is deliberately self-contained -- stdlib only, no store, no
// http -- because the same bytes are produced in three places: the local
// `ccquota badge` command, the hub's badge routes, and (later) the public
// badges service. A renderer that reached into a database could not be the one
// used by a command that must work with no network at all.
//
// THE CONSTRAINT THAT SHAPES THIS FILE: an SVG loaded through <img> -- which is
// what a README, a profile and a Pages site all do -- is a sandboxed context.
// No scripts, no external fonts, no external CSS, no network. Everything is
// inline, and a test asserts it stays that way, because an external reference
// does not error: it silently renders the wrong thing.
package badge

import (
	"fmt"
	"strconv"
	"strings"
)

// Data is everything a badge can say.
//
// Note what is absent: no project path, no machine name, no OS login, no
// account email, no utilization. The badge is the one artifact that ends up
// somewhere permanent and public, so the type simply cannot carry them.
type Data struct {
	Tokens int64
	Turns  int64
	// Period labels the window: "all", or "30d"/"7d". Never a timestamp --
	// camo caches the badge, so any absolute time it showed would be wrong.
	Period string
	// Theme is "dark" or "light", chosen explicitly by the caller.
	Theme string
	// Style is StyleTokenman (the default: animated, exact odometer) or
	// StyleFlat (static, shields-shaped).
	Style string
	// Size is "full" (48px, the presentation size) or "compact" (20px, sits
	// in a row of shields badges). Tokenman only.
	Size string

	// From is the value the odometer rolls FROM. Zero rolls up from nothing;
	// a previous reading rolls exactly the difference, wheel by wheel, with
	// as many turns as each position actually carried. This is what lets a
	// page that re-fetches the badge show real movement rather than a
	// from-zero replay. Tokenman only.
	From int64
	// Transparent omits the ground so the host's own background shows
	// through. Tokenman only.
	Transparent bool
	// Colors overrides individual palette entries. Tokenman only.
	Colors Colors
}

// Colors are optional hex overrides (six or three hex digits, no #). An
// invalid value is ignored rather than rendering an error: a badge with a typo
// in its URL should still be a badge.
type Colors struct {
	Pac, Dot, FG, BG string
}

// LabelText is the left half of the badge.
func (d Data) LabelText() string {
	if d.Period == "" || d.Period == "all" {
		return "ccquota"
	}
	return "ccquota " + d.Period
}

// MessageText is the right half: the figure itself.
func (d Data) MessageText() string { return HumanTokens(d.Tokens) + " tokens" }

// palette is one theme's colors. Both are defined here rather than one being
// derived from the other, so neither can drift into unreadable contrast.
type palette struct {
	labelBG, msgBG, labelFG, msgFG string
}

func paletteFor(theme string) palette {
	if theme == "light" {
		return palette{labelBG: "#4a4f5a", msgBG: "#a65a0a", labelFG: "#ffffff", msgFG: "#ffffff"}
	}
	// Dark is the default: an unset theme must still render, and a README
	// author who never passes ?theme= gets the one that reads on both grounds.
	return palette{labelBG: "#2b3038", msgBG: "#e29a4b", labelFG: "#e6e8ec", msgFG: "#1a1206"}
}

const (
	svgHeight = 20
	fontSize  = 11
	padX      = 6
	// charW is an advance estimate, not a measurement. There is no font metric
	// available in a sandboxed SVG and no webfont may be loaded, so the width
	// is computed from a conservative per-character advance for the system
	// stack below. Slightly wide is harmless; too narrow clips the text.
	charW = 7
	// fontStack is a system stack on purpose. A webfont will not load here at
	// all, so these are faces that already exist on the reader's machine.
	fontStack = "Verdana,DejaVu Sans,Geneva,sans-serif"
)

func textWidth(s string) int { return len([]rune(s))*charW + 2*padX }

// Render returns the badge as SVG bytes.
func Render(d Data) []byte {
	if d.Style == StyleFlat {
		return RenderMessage(d.LabelText(), d.MessageText(), d.Theme)
	}
	return renderTokenman(d)
}

// RenderMessage draws an arbitrary two-part badge.
//
// It exists for the cases that are not a figure at all -- an unknown handle,
// above all. Rendering those through Data would give them a Tokens of 0 and
// print "0 tokens", which reads as "this person spent nothing": a different
// claim from "there is no such person here", and a false one.
func RenderMessage(label, msg, theme string) []byte {
	p := paletteFor(theme)
	lw, mw := textWidth(label), textWidth(msg)
	total := lw + mw

	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" `+
		`viewBox="0 0 %d %d" role="img" aria-label="%s: %s">`,
		total, svgHeight, total, svgHeight, esc(label), esc(msg))
	fmt.Fprintf(&b, `<title>%s: %s</title>`, esc(label), esc(msg))
	fmt.Fprintf(&b, `<rect width="%d" height="%d" rx="3" fill="%s"/>`, total, svgHeight, p.labelBG)
	// The message half, rounded on its right and squared where it meets the
	// label half.
	fmt.Fprintf(&b, `<rect x="%d" width="%d" height="%d" rx="3" fill="%s"/>`,
		lw, mw, svgHeight, p.msgBG)
	fmt.Fprintf(&b, `<rect x="%d" width="6" height="%d" fill="%s"/>`, lw, svgHeight, p.msgBG)
	fmt.Fprintf(&b, `<g font-family="%s" font-size="%d">`, fontStack, fontSize)
	fmt.Fprintf(&b, `<text x="%d" y="14" fill="%s">%s</text>`, padX, p.labelFG, esc(label))
	fmt.Fprintf(&b, `<text x="%d" y="14" fill="%s">%s</text>`, lw+padX, p.msgFG, esc(msg))
	b.WriteString(`</g></svg>`)
	return []byte(b.String())
}

// esc XML-escapes badge text. The period is caller-supplied, so an unescaped
// interpolation is how a badge becomes invalid XML and renders as nothing.
func esc(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&apos;")
	return r.Replace(s)
}

// Shields is shields.io's documented endpoint schema.
type Shields struct {
	SchemaVersion int    `json:"schemaVersion"`
	Label         string `json:"label"`
	Message       string `json:"message"`
	Color         string `json:"color"`
}

// ToShields converts to the endpoint schema shields.io fetches from a URL you
// supply -- the serverless publishing path that needs no service of ours.
func ToShields(d Data) Shields {
	return Shields{
		SchemaVersion: 1,
		Label:         d.LabelText(),
		Message:       d.MessageText(),
		Color:         strings.TrimPrefix(paletteFor(d.Theme).msgBG, "#"),
	}
}

// HumanTokens renders a token count at badge width.
//
// Exact counts are for the dashboard. A badge has room for three significant
// figures, and "69.8B" is the number a reader actually takes away.
func HumanTokens(n int64) string {
	if n < 0 {
		n = 0
	}
	units := []struct {
		limit int64
		suf   string
	}{
		{1_000_000_000_000, "T"},
		{1_000_000_000, "B"},
		{1_000_000, "M"},
		{1_000, "K"},
	}
	for _, u := range units {
		// Selected on the ROUNDED value, not the raw one. 999,999 is below a
		// million, but at one decimal place it renders as "1.0" -- so it
		// belongs in M as "1M", not in K as "1000K". Comparing raw would put
		// it one unit too low and print a four-digit mantissa.
		if float64(n)/float64(u.limit) < 0.9995 {
			continue
		}
		s := strconv.FormatFloat(float64(n)/float64(u.limit), 'f', 1, 64)
		return strings.TrimSuffix(s, ".0") + u.suf
	}
	return strconv.FormatInt(n, 10)
}
