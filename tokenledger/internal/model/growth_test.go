package model

import (
	"strings"
	"testing"
	"time"
)

func growthOK(day string, aiUpdated time.Time) GrowthSnapshot {
	return GrowthSnapshot{
		Source: "growth-facts", Day: day,
		H5: GrowthH5{ARRCNY: 303600, ExpiringInWindowCNY: 282000,
			ExpiringAccounts: 52, ChurnedAccounts: 6, ActiveAccounts: 76},
		AI:  GrowthAI{UpdatedAt: aiUpdated},
		OKR: GrowthOKR{Focus: "wechat_agent", Quarter: "2026Q4-首单", TargetAnnualized: 420000, DaysToKillSwitch: 76},
	}
}

// The staleness boundary is the one number on this board that decides whether
// a figure may be shown at all, so it is pinned rather than left to a reading
// of the constant.
func TestGrowthAI_StalenessBoundary(t *testing.T) {
	now := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		name  string
		ago   time.Duration
		stale bool
		days  int
	}{
		{"just filed", time.Minute, false, 0},
		{"a day old", 25 * time.Hour, false, 1},
		{"exactly three days", 72 * time.Hour, false, 3},
		{"a second past three days", 72*time.Hour + time.Second, true, 3},
		{"five days", 5 * 24 * time.Hour, true, 5},
	} {
		ai := GrowthAI{UpdatedAt: now.Add(-tc.ago)}
		if got := ai.Stale(now); got != tc.stale {
			t.Errorf("%s: Stale = %v, want %v", tc.name, got, tc.stale)
		}
		if got := ai.DaysSinceUpdate(now); got != tc.days {
			t.Errorf("%s: DaysSinceUpdate = %d, want %d", tc.name, got, tc.days)
		}
	}
	// A filing stamped in the near future is a clock, not a time machine: it
	// must read as fresh and as zero days, never as a negative count.
	ahead := GrowthAI{UpdatedAt: now.Add(time.Minute)}
	if ahead.Stale(now) || ahead.DaysSinceUpdate(now) != 0 {
		t.Error("a just-ahead timestamp must read as fresh and zero days old")
	}
}

func TestGrowthSnapshot_Validate(t *testing.T) {
	now := time.Date(2026, 9, 15, 12, 0, 0, 0, time.UTC)
	fresh := now.Add(-time.Hour)

	if err := growthOK("2026-09-15", fresh).Validate(now); err != nil {
		t.Fatalf("the frozen contract was refused: %v", err)
	}
	// A shipper east of UTC files its own local date; one day of slack is the
	// difference between tolerating a timezone and tolerating a broken clock.
	if err := growthOK("2026-09-16", fresh).Validate(now); err != nil {
		t.Errorf("tomorrow's date from an eastern shipper was refused: %v", err)
	}

	bad := map[string]GrowthSnapshot{
		"empty source": func() GrowthSnapshot { s := growthOK("2026-09-15", fresh); s.Source = ""; return s }(),
		"shouting source": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.Source = "Growth-Facts"
			return s
		}(),
		"padded source": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.Source = " growth-facts"
			return s
		}(),
		"day is prose":  func() GrowthSnapshot { s := growthOK("yesterday", fresh); return s }(),
		"day far ahead": func() GrowthSnapshot { s := growthOK("2026-10-01", fresh); return s }(),
		"no ai.updated_at": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.AI.UpdatedAt = time.Time{}
			return s
		}(),
		"ai filed in the future": growthOK("2026-09-15", now.Add(2*time.Hour)),
		"negative arr": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.H5.ARRCNY = -1
			return s
		}(),
		"negative leads": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.AI.QualifiedLeads = -2
			return s
		}(),
		"no focus": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.OKR.Focus = "  "
			return s
		}(),
		"no quarter": func() GrowthSnapshot {
			s := growthOK("2026-09-15", fresh)
			s.OKR.Quarter = ""
			return s
		}(),
	}
	for name, s := range bad {
		if err := s.Validate(now); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}

	// The kill-switch countdown goes negative once the date passes, and that
	// is a fact somebody needs to see rather than an invalid document.
	past := growthOK("2026-09-15", fresh)
	past.OKR.DaysToKillSwitch = -12
	if err := past.Validate(now); err != nil {
		t.Errorf("an elapsed kill switch was refused: %v", err)
	}
}

func TestValidGrowthSource(t *testing.T) {
	for _, ok := range []string{"growth-facts", "g", "a.b_c-1", "facts2026"} {
		if err := ValidGrowthSource(ok); err != nil {
			t.Errorf("%q was refused: %v", ok, err)
		}
	}
	for _, bad := range []string{"", "Growth", "growth facts", "-lead", "trail-", "a/b", "你好",
		strings.Repeat("g", maxGrowthSource+1)} {
		if err := ValidGrowthSource(bad); err == nil {
			t.Errorf("%q was accepted as a source", bad)
		}
	}
}
