package codex

import (
	"testing"
	"time"
)

// The /wham/usage body (claude-fleet#2169) parses into the same pools and
// windows as an app-server read, marked as a complete account read.
func TestParseUsage(t *testing.T) {
	now := time.Now().UTC()
	raw := []byte(`{"plan_type":"pro",
	  "rate_limit":{"allowed":true,"limit_reached":false,
	    "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":60,"reset_at":1893456000},
	    "secondary_window":{"used_percent":34.5,"limit_window_seconds":604800,"reset_at":1893800000}},
	  "credits":{"has_credits":true,"unlimited":false,"balance":"5"},
	  "additional_rate_limits":[{"limit_name":"GPT-5 Codex Spark","metered_feature":"codex_spark",
	    "rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_at":1893456000}}}]}`)
	q, err := ParseUsage(raw, now)
	if err != nil {
		t.Fatal(err)
	}
	if q.Observation != ObservationAccountAPI || q.Plan != "pro" || len(q.Windows) != 3 || len(q.Pools) != 2 || !q.Blocked {
		t.Fatalf("%+v", q)
	}
	w := q.Windows[0]
	if w.ID != "codex:primary" || w.UsedPercent != 12 || w.Minutes != 300 || w.ResetsAt == nil || w.ResetsAt.Unix() != 1893456000 {
		t.Fatalf("primary: %+v", w)
	}
	if q.Windows[1].ID != "codex:secondary" || q.Windows[1].UsedPercent != 34.5 || q.Windows[1].Minutes != 10080 {
		t.Fatalf("secondary: %+v", q.Windows[1])
	}
	if q.Windows[2].ID != "codex_spark:primary" || q.Windows[2].Label != "GPT-5 Codex Spark · primary" {
		t.Fatalf("additional: %+v", q.Windows[2])
	}
	if len(q.Credits) != 1 || !q.Credits[0].HasCredits || *q.Credits[0].Balance != "5" {
		t.Fatalf("credits: %+v", q.Credits)
	}
	for _, bad := range []string{`not json`, `{}`, `{"plan_type":"plus","rate_limit":null}`} {
		if _, err := ParseUsage([]byte(bad), now); err == nil {
			t.Fatalf("%s parsed", bad)
		}
	}
}
