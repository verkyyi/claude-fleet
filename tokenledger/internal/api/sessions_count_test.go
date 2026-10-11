package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
)

// 我的会话 is ONE number, however the page reads it (claude-fleet#3321).
//
// The page draws the list from /v1/fleet/fleet_sessions and then takes every
// `sessions` event of /v1/fleet/stream as the same read (app-shell.js). For an
// admin the first was cut to their own (#2515) while the stream carried the
// whole fleet, so a reload showed 35 or 51 depending on which answer landed
// last. Every door, on every replica sharing the store, must say the same.

// streamSessionLogins reads the first `sessions` event of base's stream as c.
func streamSessionLogins(t *testing.T, base string, c *http.Cookie) []string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+FleetStreamPath+"?topics=sessions", nil)
	req.AddCookie(c)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("stream: HTTP %d", resp.StatusCode)
	}
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	event := ""
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			event = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: ") && event == "sessions":
			var f struct {
				Body struct {
					Sessions []FleetSession `json:"sessions"`
				} `json:"body"`
			}
			if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &f); err != nil {
				t.Fatalf("sessions event: %v", err)
			}
			got := []string{}
			for _, s := range f.Body.Sessions {
				got = append(got, s.MachineName+"/"+s.OSUser)
			}
			sort.Strings(got)
			return got
		}
	}
	t.Fatal("stream ended before a sessions event")
	return nil
}

func TestSessionsCountOneAnswer(t *testing.T) {
	h, admin, user := adminViewsHarness(t)

	// A second replica: its own process state, the same store.
	srv2 := &Server{Store: h.srv.Store, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(),
		GitHub: h.srv.GitHub}
	fullServer(srv2)
	ts2 := httptest.NewServer(srv2.Handler())
	t.Cleanup(ts2.Close)
	h2 := &ghHarness{srv: srv2, http: ts2, gh: h.gh}

	for _, c := range []struct {
		who  string
		sess *http.Cookie
		want []string
	}{
		{"admin", admin, []string{"mini/verkyyi"}},
		{"user", user, []string{"alicebox/" + aliceLogin}},
	} {
		for i, hh := range []*ghHarness{h, h2} {
			for n := 0; n < 3; n++ {
				if _, got := sessionLogins(t, hh, c.sess, "/v1/fleet/fleet_sessions"); !equalStrings(got, c.want) {
					t.Errorf("%s replica %d fleet_sessions = %v; want %v", c.who, i+1, got, c.want)
				}
				if got := streamSessionLogins(t, hh.http.URL, c.sess); !equalStrings(got, c.want) {
					t.Errorf("%s replica %d stream sessions = %v; want %v (the same as fleet_sessions)", c.who, i+1, got, c.want)
				}
			}
		}
	}
}
