package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
	"github.com/verkyyi/ccquota/internal/store"
)

// flowBody is the shape these tests read out of /v1/repo/flow. Declared here
// rather than reused from repo_test.go because what matters below is the one
// field that file does not name.
type flowBody struct {
	Repo   string               `json:"repo"`
	Days   []model.RepoDay      `json:"days"`
	Health *store.RepoHealthRow `json:"verify_health"`
}

func health(readings ...model.RepoReading) *model.RepoVerifyHealth {
	after := 172800.0
	return &model.RepoVerifyHealth{
		Source:            "tools/cd/measure-verify-health.js",
		StaleAfterSeconds: &after,
		Readings:          readings,
	}
}

func reading(key, value string) model.RepoReading {
	return model.RepoReading{Key: key, Label: key, Value: value, Note: "note for " + key, OK: true}
}

// The readings travel verbatim and in order. Order is load-bearing: the
// producer prints a ratio and the denominator that qualifies it as adjacent
// rows, and a surface that reorders them separates a figure from the sentence
// that keeps it honest.
func TestRepoHealth_RoundTripsVerbatim(t *testing.T) {
	h := newHarness(t)
	now := time.Now().UTC()
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Days: []model.RepoDay{{Day: now.Format(model.RepoDayLayout), Opened: 1, Closed: 1, OpenAtEnd: 9}},
		VerifyHealth: health(
			reading("touch", "p50 1.7 天 · p90 ≥ 8.8 天"),
			reading("rot", "此刻红着 1 张（分母 < 8，不出比例）"),
			reading("inflow", "0%（0 / 252）"),
		),
	})

	var flow flowBody
	h.getJSON(t, "/v1/repo/flow?repo=o/r", &flow)
	if flow.Health == nil {
		t.Fatal("flow carried no verify_health")
	}
	if got, want := len(flow.Health.Readings), 3; got != want {
		t.Fatalf("readings = %d, want %d", got, want)
	}
	for i, want := range []string{"touch", "rot", "inflow"} {
		if flow.Health.Readings[i].Key != want {
			t.Fatalf("reading %d = %q, want %q", i, flow.Health.Readings[i].Key, want)
		}
	}
	// The exact string, punctuation and bound marker included: the marker is
	// the difference between "8.8 days" and "at least 8.8 days", and a hub
	// that normalises it away reports a response time faster than the measured
	// one.
	if got := flow.Health.Readings[0].Value; got != "p50 1.7 天 · p90 ≥ 8.8 天" {
		t.Fatalf("value = %q, mangled in transit", got)
	}
	if flow.Health.Source != "tools/cd/measure-verify-health.js" {
		t.Fatalf("source = %q", flow.Health.Source)
	}
	if flow.Health.StaleAfterSeconds == nil || *flow.Health.StaleAfterSeconds != 172800 {
		t.Fatalf("stale_after_seconds = %v — without it the page cannot tell stale from fresh", flow.Health.StaleAfterSeconds)
	}
	if flow.Health.ObservedAt.IsZero() {
		t.Fatal("observed_at is zero — the page would have nothing to age these figures against")
	}
}

// Null, not an empty block. A page that receives `{"readings":[]}` prints a
// card with nothing wrong in it; one that receives null can say nobody looked.
func TestRepoHealth_NullWhenNobodyShipsIt(t *testing.T) {
	h := newHarness(t)
	now := time.Now().UTC()
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		Days: []model.RepoDay{{Day: now.Format(model.RepoDayLayout), Opened: 1, Closed: 0, OpenAtEnd: 1}},
	})
	var flow flowBody
	h.getJSON(t, "/v1/repo/flow?repo=o/r", &flow)
	if flow.Health != nil {
		t.Fatalf("verify_health = %+v, want null", flow.Health)
	}
}

// The shipper that measures this runs on its own schedule and need not have
// issue or day rows to send. Refusing a health-only snapshot would force it to
// pad the payload with facts it did not gather.
func TestRepoHealth_ShipsAlone(t *testing.T) {
	h := newHarness(t)
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: time.Now().UTC(),
		VerifyHealth: health(reading("inflow", "0%（0 / 252）")),
	})
	// ...and the repo picker must see it. A repository whose only shipped fact
	// is this one would otherwise be absent from /v1/repos, and the page never
	// asks about a repo it was not offered.
	var repos []store.Repo
	h.getJSON(t, "/v1/repos", &repos)
	if len(repos) != 1 || repos[0].Repo != "o/r" {
		t.Fatalf("repos = %+v", repos)
	}
}

// Every rejection below is a 400 with a reason, because each one is a shipper
// bug the shipper can fix -- and because storing any of them would put a
// figure on the page that nobody can tell from a measured one.
func TestRepoHealth_RefusesDishonestBlocks(t *testing.T) {
	h := newHarness(t)
	tok := h.enroll(t, "shipper")
	now := time.Now().UTC()

	for _, tc := range []struct {
		name string
		hb   *model.RepoVerifyHealth
	}{
		// "Could not measure" still has to say why. A blank value renders as
		// an empty cell, and an empty cell reads as "nothing wrong" -- the one
		// conclusion a missing figure never supports.
		{"blank value", health(model.RepoReading{Key: "rot", Value: "  ", OK: false})},
		{"no readings", &model.RepoVerifyHealth{Source: "x"}},
		// Two rows under one key is not two readings; it is one silently
		// replacing the other.
		{"duplicate key", health(reading("touch", "a"), reading("touch", "b"))},
		{"upper-case key", health(reading("Touch", "a"))},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := h.pushRepo(t, tok, model.RepoSnapshot{
				Repo: "o/r", ObservedAt: now, VerifyHealth: tc.hb,
			})
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", resp.StatusCode)
			}
			var body struct {
				Error string `json:"error"`
			}
			json.NewDecoder(resp.Body).Decode(&body)
			if body.Error == "" {
				t.Fatal("refused without saying why")
			}
		})
	}
}

// A retried snapshot can arrive after a newer one. Everywhere else in this
// table that would reopen a closed issue; here it would restore confidence
// that has since been withdrawn, which is worse -- these three figures are
// what says whether the checks behind every other figure still work.
func TestRepoHealth_OlderSnapshotDoesNotRewind(t *testing.T) {
	h := newHarness(t)
	now := time.Now().UTC()
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now,
		VerifyHealth: health(reading("inflow", "fresh")),
	})
	seedRepo(t, h, model.RepoSnapshot{
		Repo: "o/r", ObservedAt: now.Add(-6 * time.Hour),
		VerifyHealth: health(reading("inflow", "stale")),
	})
	var flow flowBody
	h.getJSON(t, "/v1/repo/flow?repo=o/r", &flow)
	if flow.Health == nil || flow.Health.Readings[0].Value != "fresh" {
		t.Fatalf("late snapshot overwrote the newer reading: %+v", flow.Health)
	}
}
