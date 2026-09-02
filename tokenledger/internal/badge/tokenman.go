package badge

import (
	"fmt"
	"strconv"
	"strings"
)

// The tokenman badge: a character eats a stream of dots, and an odometer shows
// the exact count so far.
//
// The animation carries the meaning rather than decorating it -- the dots ARE
// tokens, and the wheels roll up to the real number. Everything is CSS
// keyframes inside the SVG's own <style>: no script, which an <img> would not
// run, and no SMIL, so that ONE reduced-motion media query can stop all of it.
//
// The resting state is the final value. Every wheel's base transform is its end
// position and the keyframe animates FROM zero, so a reader with animation
// disabled sees the correct figure rather than a row of zeros. That is what
// makes the reduced-motion block safe to honour.

// Styles.
const (
	StyleTokenman = "tokenman"
	StyleFlat     = "flat"
)

// metrics is one size's geometry. Compact is not a scaled full: 14px digits
// scaled to a 20px badge would be 6px, so each size has its own readable set.
type metrics struct {
	h, pad      int
	pacR        int
	dotR, dotP  float64 // radius, pitch
	nDots       int
	cellW       int
	cellH       int
	pitch       int // cell-to-cell advance
	commaW      int
	digitFont   int
	labelFont   int
	twoLine     bool // "tokens" over the period, or a single line
	rx          int
	digitStroke float64
}

var sizes = map[string]metrics{
	"full": {
		h: 48, pad: 10, pacR: 12, dotR: 2.6, dotP: 12, nDots: 7,
		cellW: 13, cellH: 22, pitch: 15, commaW: 6, digitFont: 14, labelFont: 11,
		twoLine: true, rx: 7,
	},
	"compact": {
		h: 20, pad: 5, pacR: 6, dotR: 1.5, dotP: 7, nDots: 5,
		cellW: 8, cellH: 14, pitch: 9, commaW: 4, digitFont: 10, labelFont: 8,
		twoLine: false, rx: 3,
	},
}

type tokenmanPalette struct {
	ground, groundEdge, pac, pacEdge, eye, dot     string
	cell, cellTop, digit, comma, label, labelMuted string
}

func tokenmanPaletteFor(theme string) tokenmanPalette {
	if theme == "light" {
		return tokenmanPalette{
			ground: "#f4f2ec", groundEdge: "#e2ded4",
			pac: "#f0b90b", eye: "#1a1a1f", dot: "#8a7a55",
			cell: "#e6e2d8", cellTop: "#ffffff", digit: "#1a1a1f", comma: "#8a8577",
			label: "#3a3d45", labelMuted: "#7a7f8b",
		}
	}
	return tokenmanPalette{
		ground: "#0d0f14", groundEdge: "#1d2029",
		pac: "#ffd43b", eye: "#0d0f14", dot: "#f2d9a6",
		cell: "#1a1d26", cellTop: "#2b2f3b", digit: "#f3efe6", comma: "#6b7080",
		label: "#d6d9e0", labelMuted: "#7a8090",
	}
}

const (
	monoStack = "ui-monospace,SF Mono,Menlo,Consolas,DejaVu Sans Mono,monospace"
	sansStack = "Verdana,DejaVu Sans,Geneva,sans-serif"
	// chompS is one bite. The dot stream advances one pitch per bite, so the
	// character eats exactly one dot per chomp.
	chompS = "0.5s"
	rollS  = "2.4s"
)

// GroupDigits renders n with thousands separators: 59,745,827,895.
func GroupDigits(n int64) string {
	if n < 0 {
		n = 0
	}
	s := strconv.FormatInt(n, 10)
	if len(s) <= 3 {
		return s
	}
	var b strings.Builder
	head := len(s) % 3
	if head > 0 {
		b.WriteString(s[:head])
	}
	for i := head; i < len(s); i += 3 {
		if b.Len() > 0 {
			b.WriteByte(',')
		}
		b.WriteString(s[i : i+3])
	}
	return b.String()
}

// spinsFor is how many extra full rotations a wheel makes before settling.
// The ones wheel spins most; anything past the thousands just rolls up to its
// digit. Distance is what makes the low wheels look fast under one shared
// duration -- a real odometer's wheels all move together.
func spinsFor(fromRight int) int {
	switch fromRight {
	case 0:
		return 4
	case 1:
		return 3
	case 2:
		return 2
	case 3:
		return 1
	}
	return 0
}

func renderTokenman(d Data) []byte {
	m, ok := sizes[d.Size]
	if !ok {
		m = sizes["full"]
	}
	p := tokenmanPaletteFor(d.Theme)
	digits := strconv.FormatInt(max64(d.Tokens, 0), 10)
	grouped := GroupDigits(d.Tokens)
	period := periodLabel(d.Period)
	title := fmt.Sprintf("%s tokens (%s)", grouped, period)

	// ---- layout, left to right ----
	pacCX := m.pad + m.pacR
	pacCY := m.h / 2
	mouthX := float64(pacCX) + float64(m.pacR)*0.45 // where a dot is "eaten"
	dotsX0 := float64(pacCX+m.pacR) + m.dotP*0.9    // first dot's resting centre
	// The clip's right edge sits where the last dot rests, minus its radius,
	// so a new dot slides in from behind the edge instead of popping.
	dotsClipL := mouthX + float64(m.pacR)*0.2
	lastDot := dotsX0 + m.dotP*float64(m.nDots-1)
	dotsClipR := lastDot - m.dotR - 1

	odoX := int(dotsClipR) + m.pad
	cellY := (m.h - m.cellH) / 2
	baseline := cellY + m.cellH/2 + m.digitFont*36/100

	// Walk the grouped string to place cells and commas.
	x := odoX
	var cells strings.Builder
	var clips strings.Builder
	digitIdx := 0
	nDigits := len(digits)
	for _, ch := range grouped {
		if ch == ',' {
			// A separator mark at the baseline, between wheels.
			fmt.Fprintf(&cells, `<text class="cm" x="%d" y="%d" style="fill:%s">,</text>`,
				x+m.commaW/2, baseline, p.comma)
			x += m.commaW
			continue
		}
		final := int(ch - '0')
		fromRight := nDigits - 1 - digitIdx
		steps := spinsFor(fromRight)*10 + final
		rest := steps * m.cellH
		clipID := fmt.Sprintf("c%d", digitIdx)

		fmt.Fprintf(&clips, `<clipPath id="%s"><rect x="%d" y="%d" width="%d" height="%d" rx="2"/></clipPath>`,
			clipID, x, cellY, m.cellW, m.cellH)
		// The cell: an inset wheel with a hairline highlight along its top.
		fmt.Fprintf(&cells, `<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s"/>`,
			x, cellY, m.cellW, m.cellH, p.cell)
		fmt.Fprintf(&cells, `<rect x="%d" y="%d" width="%d" height="1" fill="%s"/>`,
			x+1, cellY, m.cellW-2, p.cellTop)
		// The strip of digits inside it. Index k shows k mod 10; the strip
		// ends on the final digit, and the base transform parks it there.
		fmt.Fprintf(&cells, `<g clip-path="url(#%s)"><g class="w" style="transform:translateY(-%dpx)">`, clipID, rest)
		cx := x + m.cellW/2
		for k := 0; k <= steps; k++ {
			fmt.Fprintf(&cells, `<text x="%d" y="%d">%d</text>`, cx, baseline+k*m.cellH, k%10)
		}
		cells.WriteString(`</g></g>`)
		x += m.pitch
		digitIdx++
	}
	odoEnd := x - (m.pitch - m.cellW)

	// ---- label ----
	labelX := odoEnd + m.pad*8/10
	var label strings.Builder
	labelW := 0
	if m.twoLine {
		fmt.Fprintf(&label, `<text x="%d" y="%d" font-family="%s" font-size="%d" font-weight="600" fill="%s">tokens</text>`,
			labelX, pacCY-2, sansStack, m.labelFont, p.label)
		fmt.Fprintf(&label, `<text x="%d" y="%d" font-family="%s" font-size="%d" fill="%s">%s</text>`,
			labelX, pacCY+m.labelFont+1, sansStack, m.labelFont-1, p.labelMuted, esc(period))
		labelW = textAdvance(maxLen("tokens", period), m.labelFont)
	} else {
		fmt.Fprintf(&label, `<text x="%d" y="%d" font-family="%s" font-size="%d" font-weight="600" fill="%s">tokens</text>`,
			labelX, pacCY+m.labelFont*36/100, sansStack, m.labelFont, p.label)
		labelW = textAdvance(len("tokens"), m.labelFont)
	}
	width := labelX + labelW + m.pad

	// ---- the character ----
	// Two jaws, each a half-disc, rotating in opposite directions about the
	// centre. The eye rides on the upper jaw, as it should.
	jaw := func(sweep int) string {
		return fmt.Sprintf("M%d,%d L%d,%d A%d,%d 0 0 %d %d,%d Z",
			pacCX, pacCY, pacCX+m.pacR, pacCY, m.pacR, m.pacR, sweep, pacCX-m.pacR, pacCY)
	}
	eyeR := float64(m.pacR) * 0.14
	eyeCX := float64(pacCX) + float64(m.pacR)*0.22
	eyeCY := float64(pacCY) - float64(m.pacR)*0.48

	var dots strings.Builder
	for i := 0; i <= m.nDots; i++ { // one extra so the loop is seamless
		fmt.Fprintf(&dots, `<circle cx="%.1f" cy="%d" r="%.1f" fill="%s"/>`,
			dotsX0+m.dotP*float64(i), pacCY, m.dotR, p.dot)
	}

	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" role="img" aria-label="%s">`,
		width, m.h, width, m.h, esc(title))
	fmt.Fprintf(&b, `<title>%s</title>`, esc(title))
	// Origins are absolute pixels in the badge's own coordinate space.
	fmt.Fprintf(&b, `<style>`+
		`.w{animation:roll %s cubic-bezier(.22,.8,.2,1) both}`+
		`@keyframes roll{from{transform:translateY(0)}}`+
		`.ju,.jl{transform-box:view-box;transform-origin:%dpx %dpx}`+
		`.ju{transform:rotate(-22deg);animation:ju %s ease-in-out infinite}`+
		`.jl{transform:rotate(22deg);animation:jl %s ease-in-out infinite}`+
		`@keyframes ju{0%%,100%%{transform:rotate(-6deg)}50%%{transform:rotate(-36deg)}}`+
		`@keyframes jl{0%%,100%%{transform:rotate(6deg)}50%%{transform:rotate(36deg)}}`+
		`.dots{animation:eat %s linear infinite}`+
		`@keyframes eat{to{transform:translateX(-%.1fpx)}}`+
		`.w text,.cm{font-family:%s;font-size:%dpx;font-weight:700;fill:%s;text-anchor:middle}`+
		`@media (prefers-reduced-motion:reduce){.w,.ju,.jl,.dots{animation:none}}`+
		`</style>`,
		rollS, pacCX, pacCY, chompS, chompS, chompS, m.dotP, monoStack, m.digitFont, p.digit)
	fmt.Fprintf(&b, `<defs>%s<clipPath id="dc"><rect x="%.1f" y="0" width="%.1f" height="%d"/></clipPath></defs>`,
		clips.String(), dotsClipL, dotsClipR-dotsClipL, m.h)
	fmt.Fprintf(&b, `<rect width="%d" height="%d" rx="%d" fill="%s" stroke="%s"/>`,
		width, m.h, m.rx, p.ground, p.groundEdge)
	// dots
	fmt.Fprintf(&b, `<g clip-path="url(#dc)"><g class="dots">%s</g></g>`, dots.String())
	// character
	fmt.Fprintf(&b, `<g class="ju"><path d="%s" fill="%s"/>`+
		`<circle cx="%.1f" cy="%.1f" r="%.1f" fill="%s"/></g>`,
		jaw(0), p.pac, eyeCX, eyeCY, eyeR, p.eye)
	fmt.Fprintf(&b, `<g class="jl"><path d="%s" fill="%s"/></g>`, jaw(1), p.pac)
	// odometer + label
	b.WriteString(cells.String())
	b.WriteString(label.String())
	b.WriteString(`</svg>`)
	return []byte(b.String())
}

func periodLabel(period string) string {
	switch period {
	case "", "all":
		return "all time"
	default:
		return "last " + period
	}
}

// textAdvance estimates a sans-serif run's width. No metrics exist in a
// sandboxed SVG, so this errs wide; wide is padding, narrow is clipping.
func textAdvance(chars, font int) int { return chars*font*62/100 + 2 }

func maxLen(a, b string) int {
	if len(a) > len(b) {
		return len(a)
	}
	return len(b)
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
