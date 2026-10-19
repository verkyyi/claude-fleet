package limits

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

// fixture is a real response recorded on 2026-08-31 from a Max 20x account.
// It is the contract: when Anthropic changes the shape, this test is the
// tripwire that fires before a user sees a wrong gauge.
func fixture(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/usage_2026-08-31.json")
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParse_RecordedContract(t *testing.T) {
	snap, err := Parse(fixture(t))
	if err != nil {
		t.Fatal(err)
	}

	if snap.FiveHour.Utilization != 4.0 {
		t.Errorf("five_hour utilization = %v, want 4", snap.FiveHour.Utilization)
	}
	if snap.SevenDay.Utilization != 8.0 {
		t.Errorf("seven_day utilization = %v, want 8", snap.SevenDay.Utilization)
	}

	if snap.FiveHour.ResetsAt == nil {
		t.Fatal("five_hour resets_at was not parsed")
	}
	want := time.Date(2026, 9, 1, 8, 29, 59, 996201000, time.UTC)
	if !snap.FiveHour.ResetsAt.Equal(want) {
		t.Errorf("five_hour resets_at = %v, want %v", snap.FiveHour.ResetsAt, want)
	}

	if len(snap.Scoped) != 1 {
		t.Fatalf("scoped windows = %d, want 1 (weekly_scoped only)", len(snap.Scoped))
	}
	if snap.Scoped[0].Model != "Fable" {
		t.Errorf("scoped model = %q, want Fable", snap.Scoped[0].Model)
	}

	if snap.RawJSON == "" || snap.SpendJSON == "" || snap.ExtraUsageJSON == "" {
		t.Error("raw/spend/extra_usage JSON should be retained for later analysis")
	}
}

// session and weekly_all repeat the headline windows. Including them in Scoped
// would show every user two duplicate gauges.
func TestParse_ScopedExcludesHeadlineDuplicates(t *testing.T) {
	snap, err := Parse(fixture(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range snap.Scoped {
		if s.Kind != "weekly_scoped" {
			t.Errorf("Scoped contains kind %q; session and weekly_all duplicate the headline windows", s.Kind)
		}
	}
}

// The degrade path is a requirement, not error handling. Every one of these
// must be an explicit "unknown", never a snapshot reading 0%.
func TestFetch_DegradesRatherThanReportingZero(t *testing.T) {
	cases := map[string]http.HandlerFunc{
		"404": func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(404) },
		"500": func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) },
		"garbage": func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte("<html>not json</html>"))
		},
		"json but not this endpoint": func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"hello":"world"}`))
		},
		"windows present but empty": func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"five_hour":{},"seven_day":{}}`))
		},
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(h)
			defer srv.Close()

			c := New()
			c.Endpoint = srv.URL
			snap, err := c.Fetch(context.Background(), "tok")

			if !errors.Is(err, ErrUnavailable) {
				t.Fatalf("err = %v, want ErrUnavailable", err)
			}
			if snap != nil {
				t.Fatalf("snapshot = %+v, want nil — a degraded read must not produce a 0%% gauge", snap)
			}
		})
	}
}

// A genuine 0% is real data and must survive, distinct from the absent case
// above.
func TestParse_GenuineZeroIsKept(t *testing.T) {
	snap, err := Parse([]byte(`{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":{"utilization":0.0}}`))
	if err != nil {
		t.Fatalf("a real 0%% reading must parse, got %v", err)
	}
	if snap.FiveHour.Utilization != 0 {
		t.Errorf("utilization = %v, want 0", snap.FiveHour.Utilization)
	}
	if snap.FiveHour.ResetsAt != nil {
		t.Errorf("resets_at = %v, want nil", snap.FiveHour.ResetsAt)
	}
}

func TestFetch_SendsOAuthHeaders(t *testing.T) {
	var gotAuth, gotBeta string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotBeta = r.Header.Get("anthropic-beta")
		w.Write([]byte(`{"five_hour":{"utilization":1},"seven_day":{"utilization":2}}`))
	}))
	defer srv.Close()

	c := New()
	c.Endpoint = srv.URL
	if _, err := c.Fetch(context.Background(), "sk-ant-oat01-x"); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer sk-ant-oat01-x" {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if gotBeta != oauthBeta {
		t.Errorf("anthropic-beta = %q, want %q", gotBeta, oauthBeta)
	}
}

func TestFetch_EmptyTokenIsUnavailable(t *testing.T) {
	if _, err := New().Fetch(context.Background(), ""); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("err = %v, want ErrUnavailable", err)
	}
}
