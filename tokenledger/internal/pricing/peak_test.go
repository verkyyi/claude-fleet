package pricing

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

func peakTable(t *testing.T, models string) *Table {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "pricing.json")
	doc := `{"gateway":{"rates_as_of":"2026-09-13","models":` + models + `}}`
	if err := os.WriteFile(path, []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	tb := Default()
	if err := tb.LoadOverrides(path); err != nil {
		t.Fatalf("LoadOverrides: %v", err)
	}
	return tb
}

func peakEvent(ts time.Time, in, out int64) *model.UsageEvent {
	return &model.UsageEvent{
		Source: "gateway", Model: "deepseek-chat", Provider: "api.deepseek.com",
		TS: ts, InputTokens: in, OutputTokens: out,
		Details: &model.UsageDetails{Provider: "api.deepseek.com"},
	}
}

// The case that forced the feature: one model, two prices, decided by when the
// call happened. Before this the honest options were to leave it unpriced or to
// pick one number and be wrong for most of the day.
func TestPeak_SameCallCostsMoreInsideTheWindow(t *testing.T) {
	tb := peakTable(t, `{"deepseek-chat":{"input":1.0,"output":2.0,
		"peak":{"multiplier":2,"utc_hours":["01:00-04:00"],"weekdays_only":true}}}`)

	// Wednesday 2026-09-02: 02:00 UTC is inside, 05:00 is not.
	peak := tb.Cost(peakEvent(time.Date(2026, 9, 2, 2, 0, 0, 0, time.UTC), 1_000_000, 1_000_000))
	off := tb.Cost(peakEvent(time.Date(2026, 9, 2, 5, 0, 0, 0, time.UTC), 1_000_000, 1_000_000))
	if peak == nil || off == nil {
		t.Fatalf("unpriced: peak=%v off=%v", peak, off)
	}
	if *peak <= *off {
		t.Fatalf("peak %v is not dearer than off-peak %v", *peak, *off)
	}
	if got, want := *peak / *off, 2.0; got < want-1e-9 || got > want+1e-9 {
		t.Errorf("peak/off = %v; want exactly the multiplier %v", got, want)
	}
	// The base rate is the OFF-PEAK one: 3 CNY per MTok over the pinned FX.
	if want := 3.0 / GatewayCNYPerUSD; *off < want-1e-9 || *off > want+1e-9 {
		t.Errorf("off-peak = %v; want %v (the base rate, unscaled)", *off, want)
	}
}

// A figure that moved must say why it moved, in the basis that travels with it.
func TestPeak_ThePriceBasisNamesTheTier(t *testing.T) {
	tb := peakTable(t, `{"deepseek-chat":{"input":1.0,"output":2.0,
		"peak":{"multiplier":2,"utc_hours":["01:00-04:00"]}}}`)
	for _, tc := range []struct {
		name, want string
		ts         time.Time
	}{
		{"inside", "peak x2", time.Date(2026, 9, 2, 2, 0, 0, 0, time.UTC)},
		{"outside", "off-peak", time.Date(2026, 9, 2, 5, 0, 0, 0, time.UTC)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := peakEvent(tc.ts, 1000, 1000)
			if tb.Cost(e) == nil {
				t.Fatal("unpriced")
			}
			if !strings.Contains(e.Details.PriceBasis, tc.want) {
				t.Errorf("basis %q does not say %q", e.Details.PriceBasis, tc.want)
			}
		})
	}
}

// A contract with one price around the clock must read exactly as it did before
// peak windows existed — no stray ", off-peak" on every basis in the ledger.
func TestPeak_AFlatRateBasisIsUnchanged(t *testing.T) {
	tb := peakTable(t, `{"deepseek-chat":{"input":1.0,"output":2.0}}`)
	e := peakEvent(time.Date(2026, 9, 2, 2, 0, 0, 0, time.UTC), 1000, 1000)
	if tb.Cost(e) == nil {
		t.Fatal("unpriced")
	}
	for _, absent := range []string{"peak", "off-peak"} {
		if strings.Contains(e.Details.PriceBasis, absent) {
			t.Errorf("flat-rate basis %q mentions %q", e.Details.PriceBasis, absent)
		}
	}
}

// The EVENT's timestamp decides, never the clock. This is what makes repricing
// history correct: run store.Reprice at any hour and last month's calls land in
// the tier they actually happened in.
func TestPeak_TheEventsOwnTimestampDecides(t *testing.T) {
	tb := peakTable(t, `{"deepseek-chat":{"input":1.0,"output":2.0,
		"peak":{"multiplier":3,"utc_hours":["01:00-04:00"]}}}`)
	// Same event priced twice, far apart in wall-clock terms, must agree.
	ts := time.Date(2026, 9, 2, 3, 30, 0, 0, time.UTC)
	first := tb.Cost(peakEvent(ts, 1000, 1000))
	second := tb.Cost(peakEvent(ts, 1000, 1000))
	if first == nil || second == nil || *first != *second {
		t.Fatalf("same event priced differently: %v vs %v", first, second)
	}
	// And a non-UTC timestamp is converted, not read off the wall.
	tokyo := time.FixedZone("JST", 9*3600)
	inTokyo := tb.Cost(peakEvent(ts.In(tokyo), 1000, 1000))
	if inTokyo == nil || *inTokyo != *first {
		t.Fatalf("the same instant in another zone priced differently: %v vs %v", inTokyo, first)
	}
}

func TestPeakWindow_AppliesAt(t *testing.T) {
	// 2026-09-02 is a Wednesday; 2026-09-05 a Saturday.
	wed := func(h, m int) time.Time { return time.Date(2026, 9, 2, h, m, 0, 0, time.UTC) }
	sat := func(h, m int) time.Time { return time.Date(2026, 9, 5, h, m, 0, 0, time.UTC) }

	for _, tc := range []struct {
		name string
		w    *PeakWindow
		ts   time.Time
		want bool
	}{
		{"nil is never peak", nil, wed(2, 0), false},
		{"start is inclusive", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}}, wed(1, 0), true},
		{"end is exclusive", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}}, wed(4, 0), false},
		{"inside", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}}, wed(3, 59), true},
		{"before", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}}, wed(0, 59), false},
		{"second window", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00", "06:00-10:00"}}, wed(7, 0), true},
		{"between windows", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00", "06:00-10:00"}}, wed(5, 0), false},
		{"half hour boundary", &PeakWindow{Multiplier: 2, UTCHours: []string{"22:30-02:00"}}, wed(22, 29), false},
		{"crosses midnight, late", &PeakWindow{Multiplier: 2, UTCHours: []string{"22:30-02:00"}}, wed(23, 0), true},
		{"crosses midnight, early", &PeakWindow{Multiplier: 2, UTCHours: []string{"22:30-02:00"}}, wed(1, 0), true},
		{"crosses midnight, outside", &PeakWindow{Multiplier: 2, UTCHours: []string{"22:30-02:00"}}, wed(12, 0), false},
		{"weekend excluded", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}, WeekdaysOnly: true}, sat(2, 0), false},
		{"weekend included when not restricted", &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}}, sat(2, 0), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.w.AppliesAt(tc.ts); got != tc.want {
				t.Errorf("AppliesAt(%s) = %v; want %v", tc.ts.Format(time.RFC3339), got, tc.want)
			}
		})
	}
}

// Every rejection here is a case where a running hub would otherwise report
// money that is quietly wrong, so each must be refused at load rather than
// shrugged off at price time.
func TestPeak_RejectsAMisconfiguredWindow(t *testing.T) {
	for _, tc := range []struct{ name, models, want string }{
		{
			name:   "multiplier below one",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":0.5,"utc_hours":["01:00-04:00"]}}}`,
			want:   "inverted",
		},
		{
			name:   "multiplier of exactly one",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":1,"utc_hours":["01:00-04:00"]}}}`,
			want:   "costs MORE than off-peak",
		},
		{
			name:   "no hours",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":2,"utc_hours":[]}}}`,
			want:   "surcharge nothing",
		},
		{
			name:   "unreadable window",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":2,"utc_hours":["1am to 4am"]}}}`,
			want:   "unreadable peak window",
		},
		{
			name:   "hour out of range",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":2,"utc_hours":["25:00-26:00"]}}}`,
			want:   "unreadable peak window",
		},
		{
			name:   "zero width",
			models: `{"m":{"input":1,"output":2,"peak":{"multiplier":2,"utc_hours":["02:00-02:00"]}}}`,
			want:   "zero-width",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "p.json")
			doc := `{"gateway":{"rates_as_of":"2026-09-13","models":` + tc.models + `}}`
			if err := os.WriteFile(path, []byte(doc), 0o600); err != nil {
				t.Fatal(err)
			}
			tb := Default()
			err := tb.LoadOverrides(path)
			if err == nil {
				t.Fatal("loaded a misconfigured peak block without complaint")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

// A peak block rides the per-UNIT shape too — audio by the second is as likely
// to have a time tier as tokens are.
func TestPeak_ScalesThePerUnitShape(t *testing.T) {
	tb := peakTable(t, `{"tts":{"unit":"second","price":1.0,
		"peak":{"multiplier":4,"utc_hours":["01:00-04:00"]}}}`)
	mk := func(h int) *model.UsageEvent {
		secs := 10.0
		return &model.UsageEvent{
			Source: "gateway", Model: "tts", Provider: "p",
			TS:      time.Date(2026, 9, 2, h, 0, 0, 0, time.UTC),
			Details: &model.UsageDetails{Provider: "p", Usage: &secs, UsageUnit: "second"},
		}
	}
	peak, off := tb.Cost(mk(2)), tb.Cost(mk(5))
	if peak == nil || off == nil {
		t.Fatalf("unpriced: peak=%v off=%v", peak, off)
	}
	if got := *peak / *off; got < 4-1e-9 || got > 4+1e-9 {
		t.Errorf("peak/off = %v; want the multiplier 4", got)
	}
}

// THE COPY TRAP. gatewayRate lists its fields by hand, and a new field added to
// Rates is dropped in silence unless someone remembers this function. That has
// already happened once — Unit/Price (#6130), whose symptom was a per-image rate
// quietly pricing as "CNY 0 in / 0 out per MTok". This checks the whole struct by
// reflection so the NEXT field cannot repeat it, without anyone having to think
// of writing a test for it.
func TestGatewayRate_CarriesEveryPriceableField(t *testing.T) {
	// The cache fields are deliberately dropped: this source reports no cache
	// tokens and validateGatewayRates rejects a file that sets them, so carrying
	// one through would make that rejection a lie.
	dropped := map[string]bool{"CacheWrite5m": true, "CacheWrite1h": true, "CacheRead": true}

	full := Rates{
		Input: 1, Output: 2, Unit: "second", Price: 3,
		CacheWrite5m: 4, CacheWrite1h: 5, CacheRead: 6,
		Peak: &PeakWindow{Multiplier: 2, UTCHours: []string{"01:00-04:00"}},
	}
	// Guard the guard: if a field is added to Rates and not set above, this test
	// would pass while checking nothing about it.
	rt := reflect.TypeOf(full)
	v := reflect.ValueOf(full)
	for i := 0; i < rt.NumField(); i++ {
		if v.Field(i).IsZero() {
			t.Fatalf("Rates.%s is not exercised by this test's fixture; set it in `full` above", rt.Field(i).Name)
		}
	}

	got := reflect.ValueOf(gatewayRate(full))
	for i := 0; i < rt.NumField(); i++ {
		name := rt.Field(i).Name
		kept := !got.Field(i).IsZero()
		switch {
		case dropped[name] && kept:
			t.Errorf("gatewayRate carried %s through; this source has no cache tokens to price", name)
		case !dropped[name] && !kept:
			t.Errorf("gatewayRate dropped %s -- a rate field that cannot reach pricing prices as zero, in silence", name)
		}
	}
}

// The shape a peak block takes in the overrides file is part of the contract with
// whoever edits it, so pin the JSON spelling.
func TestPeak_JSONSpelling(t *testing.T) {
	var r Rates
	if err := json.Unmarshal([]byte(`{"input":1,"output":2,
		"peak":{"multiplier":2,"utc_hours":["01:00-04:00","06:00-10:00"],"weekdays_only":true}}`), &r); err != nil {
		t.Fatal(err)
	}
	if r.Peak == nil {
		t.Fatal("peak did not parse")
	}
	if r.Peak.Multiplier != 2 || len(r.Peak.UTCHours) != 2 || !r.Peak.WeekdaysOnly {
		t.Fatalf("peak = %+v", r.Peak)
	}
}
