package findings

import (
	"strings"
	"testing"
	"time"
)

func sessions(tokens ...int64) []SessionStat {
	var out []SessionStat
	for i, t := range tokens {
		out = append(out, SessionStat{SessionID: "s" + string(rune('a'+i)), CWD: "/p/x", Model: "claude-opus-5",
			Tokens: t, Turns: 3, Duration: 90 * time.Minute})
	}
	return out
}

func kinds(fs []Finding) string {
	var k []string
	for _, f := range fs {
		k = append(k, f.Kind)
	}
	return strings.Join(k, ",")
}

func TestRunawaySession(t *testing.T) {
	// median of 10,10,10,10 = 10 -> threshold max(200, 100M) = 100M
	in := Inputs{Sessions: append(sessions(10, 10, 10, 10), SessionStat{SessionID: "big", CWD: "/p/y", Model: "m",
		Tokens: 150_000_000, Turns: 400, Duration: 6 * time.Hour})}
	fs := Review(in)
	if kinds(fs) != "runaway_session" || fs[0].Severity != "critical" || fs[0].Scope["session"] != "big" {
		t.Fatalf("%+v", fs)
	}
	if !strings.Contains(fs[0].Title, "150.0M") || !strings.Contains(fs[0].Detail, "6h 0m") {
		t.Fatalf("wording: %+v", fs[0])
	}
	// mutation: the big session shrunk below the absolute floor -> nothing fires
	in.Sessions[4].Tokens = 99_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	// relative rule: 25x median but under the floor still does not fire
	in.Sessions = append(sessions(1_000_000, 1_000_000, 1_000_000), SessionStat{SessionID: "x", Tokens: 25_000_000})
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

func TestUnpricedModel(t *testing.T) {
	in := Inputs{Models: []ModelStat{{Model: "claude-fable-5-1", Tokens: 3_300_000_000, Unpriced: 9104}, {Model: "claude-opus-5", Tokens: 1}}}
	fs := Review(in)
	if kinds(fs) != "unpriced_model" || fs[0].Severity != "warning" || fs[0].Scope["model"] != "claude-fable-5-1" {
		t.Fatalf("%+v", fs)
	}
	in.Models[0].Unpriced = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestTimeInCritical(t *testing.T) {
	in := Inputs{SelectionSeconds: 7 * 86400, Critical: []AccountCritical{{Label: "a@x", Seconds: 3600, PrevSeconds: 0, Episodes: 2}}}
	fs := Review(in)
	if kinds(fs) != "time_in_critical" || fs[0].Severity != "warning" || !strings.Contains(fs[0].Title, "1h 0m") {
		t.Fatalf("%+v", fs)
	}
	in.Critical[0].Seconds = 7 * 86400 / 5 // 20% of the selection
	if fs := Review(in); fs[0].Severity != "critical" {
		t.Fatalf("20%% of the period must be critical: %+v", fs)
	}
	in.Critical[0].Seconds = 0
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestCacheHitDrop(t *testing.T) {
	in := Inputs{
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 500, CacheHit: 0.88}, {CWD: "/p/b", Turns: 50, CacheHit: 0.10}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 400, CacheHit: 0.97}, {CWD: "/p/b", Turns: 500, CacheHit: 0.95}},
	}
	fs := Review(in)
	// /p/b has too few turns in the current period; only /p/a fires
	if kinds(fs) != "cache_hit_drop" || fs[0].Scope["project"] != "/p/a" || fs[0].Severity != "info" {
		t.Fatalf("%+v", fs)
	}
	in.Projects[0].CacheHit = 0.93 // 4-point drop: under the 5-point threshold
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}

func TestSpendSpike(t *testing.T) {
	in := Inputs{Tokens: 3_000_000_000, PrevTokens: 1_000_000_000,
		Projects:     []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 2_500_000_000, PrevTokens: 500_000_000}},
		PrevProjects: []ProjectStat{{CWD: "/p/a", Turns: 10, Tokens: 500_000_000}}}
	fs := Review(in)
	if kinds(fs) != "spend_spike,spend_spike" || fs[1].Scope["project"] != "/p/a" {
		t.Fatalf("%+v", fs)
	}
	in.Tokens = 1_400_000_000 // 1.4x: under 1.5x
	in.Projects[0].Tokens = 700_000_000
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
	in.Tokens, in.PrevTokens = 900_000_000, 100_000_000 // 9x but under the 1B floor
	in.Projects = nil
	if fs := Review(in); len(fs) != 0 {
		t.Fatalf("floor: %+v", fs)
	}
}

func TestOrderingAndCap(t *testing.T) {
	in := Inputs{SelectionSeconds: 86400,
		Models:   []ModelStat{{Model: "m", Unpriced: 1, Tokens: 1}},
		Critical: []AccountCritical{{Label: "a", Seconds: 50000, Episodes: 1}},
		Tokens:   5_000_000_000, PrevTokens: 1_000_000_000}
	fs := Review(in)
	if kinds(fs) != "time_in_critical,unpriced_model,spend_spike" {
		t.Fatalf("severity order: %s", kinds(fs))
	}
	var many []ModelStat
	for i := 0; i < 12; i++ {
		many = append(many, ModelStat{Model: "m" + string(rune('a'+i)), Unpriced: 1, Tokens: int64(i)})
	}
	capped := Review(Inputs{Models: many})
	if len(capped) != 8 {
		t.Fatalf("cap at 8, got %d", len(capped))
	}
	// The cap must keep the 8 LARGEST findings, not the first 8 appended: on a
	// real fleet with more than 8 same-kind, same-severity findings (e.g. 12
	// unpriced models), dropping the small ones and keeping the big ones is
	// the whole point of a findings list.
	for _, f := range capped {
		switch f.Scope["model"] {
		case "ma", "mb", "mc", "md":
			t.Fatalf("cap kept a small finding instead of a large one: %+v", capped)
		}
	}
	if capped[0].Scope["model"] != "ml" || capped[7].Scope["model"] != "me" {
		t.Fatalf("cap survivors not sorted by descending magnitude: %+v", capped)
	}
}

func TestNowFindings(t *testing.T) {
	now := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	old := now.Add(-2 * time.Hour)
	in := NowInputs{Now: now,
		Windows:   []WindowStat{{Label: "a@x", FiveHourPct: 82}, {Label: "b@x", FiveHourPct: 95}, {Label: "c@x", FiveHourPct: 10}},
		Endpoints: []EndpointSeen{{Label: "macmini-zx", LastSeen: &old}, {Label: "fresh", LastSeen: &now}, {Label: "never"}},
		Live:      []LiveStat{{SessionID: "s1", CWD: "/p", Tokens: 250_000_000}, {SessionID: "s2", Tokens: 1000}}}
	fs := Now(in)
	if kinds(fs) != "window_high,window_high,stale_agent,stale_agent,live_runaway" {
		t.Fatalf("%s", kinds(fs))
	}
	if fs[0].Severity != "critical" || fs[1].Severity != "warning" || !strings.Contains(fs[0].Title, "b@x") {
		t.Fatalf("%+v", fs[:2])
	}
	in.Windows, in.Live = nil, nil
	in.Endpoints = []EndpointSeen{{Label: "fresh", LastSeen: &now}}
	if fs := Now(in); len(fs) != 0 {
		t.Fatalf("control: %+v", fs)
	}
}
