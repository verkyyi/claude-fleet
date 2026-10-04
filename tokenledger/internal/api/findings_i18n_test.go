package api

import (
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/findings"
	"github.com/verkyyi/ccquota/internal/i18n"
)

// everyFinding produces at least one finding per template this build can emit,
// by driving the real rules rather than hand-building Finding values: a rule
// that changes its wording, its args, or its template id must move this test,
// not slip past it.
func everyFinding(t *testing.T) []findings.Finding {
	t.Helper()
	seen := time.Now().UTC().Add(-3 * time.Hour)
	review := findings.Review(findings.Inputs{
		SessionTokenMedian: 1_000,
		Sessions: []findings.SessionStat{
			{SessionID: "abcdef123456", CWD: "/srv/work/api", Model: "claude-opus-5",
				Tokens: 400_000_000, Turns: 42, Duration: 95 * time.Minute},
		},
		Models: []findings.ModelStat{{Model: "qwen-plus", Tokens: 900, Unpriced: 19}},
		// Both sides of the allowance line: one model past it, one approaching.
		FreeAllowances: []findings.FreeAllowanceStat{
			{Model: "doubao-seed-2-0-mini", Tokens: 1_400_000, Allowance: 1_000_000},
			{Model: "doubao-lite", Tokens: 900_000, Allowance: 1_000_000},
		},
		Critical:         []findings.AccountCritical{{Label: "team@example.com", Seconds: 3600, PrevSeconds: 600, Episodes: 3}},
		SelectionSeconds: 7200,
		Projects:         []findings.ProjectStat{{CWD: "/srv/work/api", Turns: 250, CacheHit: 0.30, Tokens: 4_000_000_000, PrevTokens: 1_000_000_000}},
		PrevProjects:     []findings.ProjectStat{{CWD: "/srv/work/api", Turns: 250, CacheHit: 0.90, Tokens: 1_000_000_000}},
		Tokens:           4_000_000_000,
		PrevTokens:       1_000_000_000,
	})
	now := findings.Now(findings.NowInputs{
		Now: time.Now().UTC(),
		Windows: []findings.WindowStat{
			{Label: "team@example.com", FiveHourPct: 95},
			{Label: "other@example.com", FiveHourPct: 80, Window: "weekly window"},
		},
		Endpoints: []findings.EndpointSeen{
			{Label: "mac-studio"},
			{Label: "linux-box", LastSeen: &seen},
		},
		Live: []findings.LiveStat{{SessionID: "feedfacecafe", CWD: "/srv/work/api", Tokens: 300_000_000}},
	})
	all := append(append([]findings.Finding{}, review...), now...)
	if len(all) == 0 {
		t.Fatal("no findings produced; the fixtures no longer trip any rule")
	}
	// Every template must actually be produced here. A template these fixtures
	// do not trip is one whose English wording is never checked against the rule
	// that emits it -- the drift guard below would pass while saying nothing
	// about it. Thresholds move (runawayFloor is 100M, cacheMinTurns is 200);
	// when one does, this fails loudly instead of quietly reducing coverage.
	got := map[string]bool{}
	for _, f := range all {
		got[f.Template] = true
	}
	for _, tmpl := range findings.Templates {
		if !got[tmpl] {
			t.Errorf("no fixture trips %q, so its wording is unguarded", tmpl)
		}
	}
	return all
}

// THE guard. Every finding, rendered through the English template, must
// reproduce what internal/findings actually wrote — byte for byte.
//
// Without this the English table is a COPY of the rules' wording, and a copy
// drifts: someone rewords a finding, every existing test still passes (they
// assert on what the rule emits), and English viewers silently start reading
// the stale duplicate in this package instead.
func TestFindings_EnglishTemplatesReproduceTheRules(t *testing.T) {
	for _, f := range everyFinding(t) {
		if f.Template == "" {
			t.Errorf("%s: finding carries no template, so it can never be translated: %q", f.Kind, f.Title)
			continue
		}
		got := localizeFinding(f, i18n.EN)
		if got.Title != f.Title {
			t.Errorf("%s/%s title drifted:\n rule: %q\n tmpl: %q", f.Kind, f.Template, f.Title, got.Title)
		}
		if got.Detail != f.Detail {
			t.Errorf("%s/%s detail drifted:\n rule: %q\n tmpl: %q", f.Kind, f.Template, f.Detail, got.Detail)
		}
	}
}

// Every template the package declares must have a title. A new rule whose
// wording nobody added here would render in English on a Chinese page — the
// silent half-translation this whole effort exists to prevent.
func TestFindings_EveryTemplateIsTranslated(t *testing.T) {
	for _, tmpl := range findings.Templates {
		txt, ok := findingTitles[tmpl]
		if !ok {
			t.Errorf("%s: no title entry", tmpl)
			continue
		}
		if strings.TrimSpace(txt[i18n.EN]) == "" || strings.TrimSpace(txt[i18n.ZhCN]) == "" {
			t.Errorf("%s: title missing a language: %+v", tmpl, txt)
		}
		if d, ok := findingDetails[tmpl]; ok {
			if strings.TrimSpace(d[i18n.EN]) == "" || strings.TrimSpace(d[i18n.ZhCN]) == "" {
				t.Errorf("%s: detail missing a language", tmpl)
			}
		}
	}
	// And the reverse: an entry here for a template no rule emits is dead
	// weight that will be translated forever and never read.
	declared := map[string]bool{}
	for _, tmpl := range findings.Templates {
		declared[tmpl] = true
	}
	for tmpl := range findingTitles {
		if !declared[tmpl] {
			t.Errorf("%s: a title for a template no rule emits", tmpl)
		}
	}
}

func TestFindings_TranslatedAndIdentifiersUntouched(t *testing.T) {
	for _, f := range everyFinding(t) {
		zh := localizeFinding(f, i18n.ZhCN)
		if zh.Severity != f.Severity || zh.Kind != f.Kind || zh.Link != f.Link {
			t.Errorf("%s: an identifier changed with the locale: %+v", f.Kind, zh)
		}
		if len(zh.Scope) != len(f.Scope) {
			t.Errorf("%s: scope chips changed with the locale", f.Kind)
		}
		for k, v := range f.Scope {
			if zh.Scope[k] != v {
				t.Errorf("%s: scope %q was rewritten: %q", f.Kind, k, zh.Scope[k])
			}
		}
		if zh.Title == f.Title {
			t.Errorf("%s/%s: title was not translated: %q", f.Kind, f.Template, zh.Title)
		}
	}
}

// The data inside a finding is the point of it. A translation that dropped the
// token count or the session id would read fine and say nothing.
func TestFindings_DataSurvivesTranslation(t *testing.T) {
	for _, f := range everyFinding(t) {
		zh := localizeFinding(f, i18n.ZhCN)
		for name, val := range f.Args {
			if name == "windowDefaulted" || val == "" {
				continue
			}
			// The window label is deliberately replaced when it was OUR default.
			if name == "window" && f.Args["windowDefaulted"] == "true" {
				continue
			}
			if !strings.Contains(zh.Title+" "+zh.Detail, val) {
				t.Errorf("%s/%s: %q=%q vanished in translation\n  title: %q\n  detail: %q",
					f.Kind, f.Template, name, val, zh.Title, zh.Detail)
			}
		}
		// No unfilled placeholder may reach a reader.
		if strings.Contains(zh.Title, "{") || strings.Contains(zh.Detail, "{") {
			t.Errorf("%s/%s: an unfilled placeholder survived: %q / %q", f.Kind, f.Template, zh.Title, zh.Detail)
		}
	}
}

// A provider that states its own window wording keeps it; only OUR default is
// translated. Restating a provider's label would be putting words in its mouth.
func TestFindings_ProviderWindowLabelIsNotRestated(t *testing.T) {
	var defaulted, stated *findings.Finding
	for _, f := range everyFinding(t) {
		f := f
		if f.Template != findings.TmplWindowHigh {
			continue
		}
		if f.Args["windowDefaulted"] == "true" {
			defaulted = &f
		} else {
			stated = &f
		}
	}
	if defaulted == nil || stated == nil {
		t.Fatal("fixtures no longer cover both window cases")
	}
	if zh := localizeFinding(*defaulted, i18n.ZhCN); !strings.Contains(zh.Title, "5 小时窗口") {
		t.Errorf("our own default window wording was not translated: %q", zh.Title)
	}
	if zh := localizeFinding(*stated, i18n.ZhCN); !strings.Contains(zh.Title, "weekly window") {
		t.Errorf("a provider's own window label was rewritten: %q", zh.Title)
	}
}

// A finding built without a template (an older caller, or one outside the
// package) must come back intact rather than blanked.
func TestFindings_UntemplatedIsLeftAlone(t *testing.T) {
	f := findings.Finding{Severity: "info", Kind: "custom", Title: "something happened", Detail: "detail"}
	got := localizeFinding(f, i18n.ZhCN)
	if got.Title != f.Title || got.Detail != f.Detail {
		t.Errorf("an untemplated finding was altered: %+v", got)
	}
}
