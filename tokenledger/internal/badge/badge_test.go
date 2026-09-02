package badge

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

func TestHumanTokens(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{999, "999"},
		{1000, "1K"},
		{1500, "1.5K"},
		{999_999, "1M"},
		{54_000_000_000, "54B"},
		{69_845_943_231, "69.8B"},
		{1_500_000_000_000, "1.5T"},
	}
	for _, c := range cases {
		if got := HumanTokens(c.in); got != c.want {
			t.Errorf("HumanTokens(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

// The badge is loaded through <img>, which is a sandboxed context: no scripts,
// no external fonts, no external CSS, no network. A single external reference
// does not error -- it silently renders a badge with the wrong type in it.
func TestRender_HasNoExternalReference(t *testing.T) {
	svg := string(Render(Data{Tokens: 69_845_943_231, Turns: 267_607, Period: "all", Theme: "dark"}))
	// The SVG namespace declaration is the one URI that legitimately appears:
	// it is an identifier, never fetched, and a standalone SVG does not render
	// without it. Strip it so the scan below is about real references.
	const xmlns = `xmlns="http://www.w3.org/2000/svg"`
	if !strings.Contains(svg, xmlns) {
		t.Error("no xmlns declaration; a standalone SVG will not render")
	}
	svg = strings.ReplaceAll(svg, xmlns, "")
	for _, forbidden := range []string{
		"http://", "https://", "@import", "<image", "xlink:href", "url(", "<script", "<foreignObject",
	} {
		if strings.Contains(svg, forbidden) {
			t.Errorf("rendered badge contains %q; an <img>-loaded SVG cannot fetch anything", forbidden)
		}
	}
}

// A timestamp on a badge is wrong within the hour and stays on a profile for a
// week. The period is a label instead.
func TestRender_CarriesPeriodNotTimestamp(t *testing.T) {
	svg := string(Render(Data{Tokens: 100, Period: "30d", Theme: "light"}))
	if !strings.Contains(svg, "30d") {
		t.Error("badge does not carry its period label")
	}
	if regexp.MustCompile(`\d{4}-\d{2}-\d{2}`).MatchString(svg) {
		t.Error("badge carries a date; camo caches it and it will be wrong within the hour")
	}
}

func TestRender_ThemesDiffer(t *testing.T) {
	dark := string(Render(Data{Tokens: 1, Theme: "dark"}))
	light := string(Render(Data{Tokens: 1, Theme: "light"}))
	if dark == light {
		t.Error("dark and light render identically; ?theme= does nothing")
	}
}

func TestRender_IsStableForTheSameInput(t *testing.T) {
	d := Data{Tokens: 42_000, Turns: 7, Period: "all", Theme: "dark"}
	if string(Render(d)) != string(Render(d)) {
		t.Error("render is not deterministic; camo would cache one of two badges at random")
	}
}

func TestRender_EscapesText(t *testing.T) {
	svg := string(Render(Data{Tokens: 1, Period: `a<b&"c`, Theme: "dark"}))
	if strings.Contains(svg, `a<b&"c`) {
		t.Error("period is interpolated raw; that produces invalid XML")
	}
	if !strings.Contains(svg, "a&lt;b&amp;&quot;c") {
		t.Error("period is not XML-escaped")
	}
}

func TestToShields_MatchesEndpointSchema(t *testing.T) {
	b, err := json.Marshal(ToShields(Data{Tokens: 69_845_943_231, Period: "all", Theme: "dark"}))
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	// shields.io's documented endpoint schema: schemaVersion MUST be 1, and
	// label/message/color are the fields it reads.
	if got["schemaVersion"] != float64(1) {
		t.Errorf("schemaVersion = %v, want 1; shields rejects anything else", got["schemaVersion"])
	}
	for _, k := range []string{"label", "message", "color"} {
		if s, ok := got[k].(string); !ok || s == "" {
			t.Errorf("shields JSON field %q is missing or empty", k)
		}
	}
}
