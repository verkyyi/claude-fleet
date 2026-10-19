package badge

import (
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The scan every rendered badge must pass, whatever its style. The xmlns
// identifier is the one URI that legitimately appears: it is never fetched, and
// a standalone SVG does not render without it.
func assertSandboxSafe(t *testing.T, svg string) {
	t.Helper()
	const xmlns = `xmlns="http://www.w3.org/2000/svg"`
	if !strings.Contains(svg, xmlns) {
		t.Error("no xmlns declaration; a standalone SVG will not render")
	}
	svg = strings.ReplaceAll(svg, xmlns, "")
	for _, forbidden := range []string{
		"http://", "https://", "@import", "<image", "xlink:href", "url(http", "<script",
		"<foreignObject", "@font-face",
	} {
		if strings.Contains(svg, forbidden) {
			t.Errorf("badge contains %q; an <img>-loaded SVG cannot fetch or run anything", forbidden)
		}
	}
}

func TestTokenman_IsTheDefaultStyle(t *testing.T) {
	svg := string(Render(Data{Tokens: 1234, Period: "all"}))
	if !strings.Contains(svg, "@keyframes") {
		t.Error("the default style is not animated; tokenman should be the default")
	}
}

func TestTokenman_SandboxSafe(t *testing.T) {
	for _, size := range []string{"full", "compact"} {
		for _, theme := range []string{"dark", "light"} {
			svg := string(Render(Data{Tokens: 59_745_827_895, Period: "30d", Theme: theme, Size: size, Style: StyleTokenman}))
			assertSandboxSafe(t, svg)
		}
	}
}

func TestFlat_SandboxSafe(t *testing.T) {
	assertSandboxSafe(t, string(Render(Data{Tokens: 5, Style: StyleFlat})))
}

// Every digit of the exact count is an odometer wheel. A badge that rounds to
// "59.7B" defeats the point of an odometer.
func TestTokenman_OneWheelPerDigit(t *testing.T) {
	for _, c := range []struct {
		n      int64
		wheels int
	}{
		{0, 1}, {7, 1}, {42, 2}, {1_000, 4}, {59_745_827_895, 11},
	} {
		svg := string(Render(Data{Tokens: c.n, Style: StyleTokenman}))
		got := strings.Count(svg, `class="w"`)
		if got != c.wheels {
			t.Errorf("Tokens=%d rendered %d wheels, want %d", c.n, got, c.wheels)
		}
	}
}

// The exact figure is stated in text as well as drawn, for screen readers and
// for anyone who copies the badge's title.
func TestTokenman_TitleCarriesTheExactNumber(t *testing.T) {
	svg := string(Render(Data{Tokens: 59_745_827_895, Period: "30d", Style: StyleTokenman}))
	if !strings.Contains(svg, "59,745,827,895") {
		t.Error("the exact grouped number does not appear in the badge's title")
	}
	if !strings.Contains(svg, "30d") {
		t.Error("period label missing")
	}
}

// Every wheel's resting position IS the final digit. The animation runs FROM
// zero, so with animation disabled the badge is still correct -- a badge that
// showed all zeros to a reduced-motion reader would be a lie.
func TestTokenman_RestingStateIsTheFinalValue(t *testing.T) {
	svg := string(Render(Data{Tokens: 42, Style: StyleTokenman}))
	if !strings.Contains(svg, "prefers-reduced-motion") {
		t.Error("no reduced-motion block")
	}
	// The keyframe animates from translateY(0) to the element's own
	// transform, so the base transform must be non-zero for a non-zero digit.
	wheels := regexp.MustCompile(`class="w" style="transform:translateY\((-?\d+)px\)"`).FindAllStringSubmatch(svg, -1)
	if len(wheels) != 2 {
		t.Fatalf("expected 2 wheels with a base transform, found %d", len(wheels))
	}
	for _, w := range wheels {
		if w[1] == "0" {
			t.Errorf("a wheel for a non-zero digit rests at translateY(0); reduced-motion readers would see 0")
		}
	}
	if !strings.Contains(svg, "from{transform:translateY(0)}") {
		t.Error("the roll does not start from zero")
	}
}

func TestTokenman_CompactIsShieldsHeight(t *testing.T) {
	svg := string(Render(Data{Tokens: 12345, Size: "compact", Style: StyleTokenman}))
	if !strings.Contains(svg, `height="20"`) {
		t.Error("compact badge is not 20px tall; it will not sit in a row of shields badges")
	}
	full := string(Render(Data{Tokens: 12345, Style: StyleTokenman}))
	if strings.Contains(full, `height="20"`) {
		t.Error("full badge is 20px; it should be the large presentation size")
	}
}

func TestTokenman_ThemesDiffer(t *testing.T) {
	d := string(Render(Data{Tokens: 9, Theme: "dark", Style: StyleTokenman}))
	l := string(Render(Data{Tokens: 9, Theme: "light", Style: StyleTokenman}))
	if d == l {
		t.Error("dark and light tokenman render identically")
	}
}

func TestGroupDigits(t *testing.T) {
	for _, c := range []struct {
		n    int64
		want string
	}{
		{0, "0"}, {999, "999"}, {1000, "1,000"}, {59_745_827_895, "59,745,827,895"},
	} {
		if got := GroupDigits(c.n); got != c.want {
			t.Errorf("GroupDigits(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

// A wheel rolls from its old digit to its new one, turning as many times as
// that position actually carried -- capped so the strip stays small, but
// always ending on the right digit.
func TestWheelSteps(t *testing.T) {
	cases := []struct {
		from, to int64
		pos      int
		want     int
	}{
		{0, 7, 0, 7},
		{0, 59_745_827_895, 0, 45}, // 4 capped rotations + 5
		{0, 59_745_827_895, 1, 39}, // 3 + 9
		{0, 59_745_827_895, 4, 2},  // no rotation past the thousands; just 0 -> 2
		{999, 1_000, 0, 1},         // every wheel carries exactly once
		{999, 1_000, 1, 1},
		{999, 1_000, 2, 1},
		{999, 1_000, 3, 1},
		{1_000, 1_000, 0, 0}, // unchanged: nothing moves
		{123, 125, 0, 2},
		{123, 125, 1, 0},
		{5_000, 4_000, 0, 40}, // a decrease rolls up from zero: 4 capped turns + 0
		{5_000, 4_000, 3, 4},
	}
	for _, c := range cases {
		if got := wheelSteps(c.from, c.to, c.pos); got != c.want {
			t.Errorf("wheelSteps(%d, %d, pos %d) = %d, want %d", c.from, c.to, c.pos, got, c.want)
		}
	}
}

// The strip starts on the OLD digit and its resting transform is exactly the
// steps travelled, so the wheel lands on the new digit and a reduced-motion
// reader sees the new value.
func TestTokenman_FromRollsTheDifference(t *testing.T) {
	svg := string(Render(Data{Tokens: 1_000, From: 999, Style: StyleTokenman}))
	m := sizes["full"]
	wheels := regexp.MustCompile(`class="w" style="transform:translateY\(-(\d+)px\)"`).FindAllStringSubmatch(svg, -1)
	if len(wheels) != 4 {
		t.Fatalf("want 4 wheels, got %d", len(wheels))
	}
	for i, w := range wheels {
		if w[1] != strconv.Itoa(m.cellH) {
			t.Errorf("wheel %d rests at %spx, want one step (%dpx)", i, w[1], m.cellH)
		}
	}
	// The ones wheel's strip: 9 then 0.
	if !strings.Contains(svg, `>9</text><text`) {
		t.Error("the ones wheel does not start on its old digit 9")
	}
}

func TestTokenman_AutoThemeCarriesBothPalettes(t *testing.T) {
	svg := string(Render(Data{Tokens: 5, Theme: "auto", Style: StyleTokenman}))
	if !strings.Contains(svg, "prefers-color-scheme:dark") {
		t.Fatal("auto theme has no dark media block")
	}
	dark, light := tokenmanPaletteFor("dark"), tokenmanPaletteFor("light")
	if !strings.Contains(svg, dark.ground) || !strings.Contains(svg, light.ground) {
		t.Error("auto theme does not carry both grounds")
	}
	// An explicit theme carries only its own.
	d := string(Render(Data{Tokens: 5, Theme: "dark", Style: StyleTokenman}))
	if strings.Contains(d, light.ground) {
		t.Error("dark theme leaks the light ground")
	}
}

func TestTokenman_TransparentHasNoGround(t *testing.T) {
	svg := string(Render(Data{Tokens: 5, Theme: "dark", Transparent: true, Style: StyleTokenman}))
	if strings.Contains(svg, `fill="var(--g)"`) {
		t.Error("transparent badge still paints its ground")
	}
	opaque := string(Render(Data{Tokens: 5, Theme: "dark", Style: StyleTokenman}))
	if !strings.Contains(opaque, `fill="var(--g)"`) {
		t.Error("control: the opaque badge has no ground rect either, so the assertion above is empty")
	}
	assertSandboxSafe(t, svg)
}

func TestTokenman_ColorOverrides(t *testing.T) {
	svg := string(Render(Data{Tokens: 5, Style: StyleTokenman, Colors: Colors{Pac: "ff0000", Dot: "00ff00", FG: "0000ff", BG: "123456"}}))
	for _, want := range []string{"#ff0000", "#00ff00", "#0000ff", "#123456"} {
		if !strings.Contains(svg, want) {
			t.Errorf("override %s not applied", want)
		}
	}
	// Bad hex is ignored, never an error badge.
	bad := string(Render(Data{Tokens: 5, Style: StyleTokenman, Colors: Colors{Pac: "not-a-colour", BG: "<script>"}}))
	assertSandboxSafe(t, bad)
	if !strings.Contains(bad, tokenmanPaletteFor("dark").pac) {
		t.Error("a bad override did not fall back to the default")
	}
}
