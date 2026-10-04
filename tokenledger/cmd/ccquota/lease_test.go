package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ccquota lease's one-line, one-exit-code contract (claude-fleet#1422) — what
// dash-issue-session.sh branches on.
func TestLeaseCLIContract(t *testing.T) {
	var got map[string]any
	answer := func(status int, body string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/v1/node/lease" || r.Header.Get("Authorization") != "Bearer tok" {
				http.Error(w, "bad", http.StatusUnauthorized)
				return
			}
			_ = json.NewDecoder(r.Body).Decode(&got)
			w.WriteHeader(status)
			_, _ = w.Write([]byte(body))
		}))
	}
	wid := "11111111-1111-4111-8111-111111111111/issue-7"
	cases := []struct {
		name, body string
		status     int
		args       []string
		code       int
		out        string
	}{
		{"granted", `{"granted":true,"lease":{"node":"m4","worker_id":"w"}}`, 200,
			[]string{"acquire", "o/r", "7", wid}, 0, "GRANTED m4"},
		{"held", `{"granted":false,"holder":{"node":"m5","worker_id":"x/issue-7","expires_at":"2026-10-03T12:00:00Z"}}`, 409,
			[]string{"acquire", "o/r", "7", wid}, 3, "HELD m5 x/issue-7 2026-10-03T12:00:00Z"},
		{"forced", `{"granted":true,"lease":{"node":"m4"},"displaced":{"node":"m5","worker_id":"x/issue-7"}}`, 200,
			[]string{"acquire", "--force", "o/r", "7", wid}, 0, "FORCED m4 m5 x/issue-7"},
		{"released", `{"released":true}`, 200, []string{"release", "o/r", "7", wid}, 0, "RELEASED"},
		{"not held", `{"released":false}`, 200, []string{"release", "o/r", "7", wid}, 0, "NOT_HELD"},
		{"hub error", `{"error":"x"}`, 403, []string{"acquire", "o/r", "7", wid}, 1, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ts := answer(c.status, c.body)
			defer ts.Close()
			var out, errb bytes.Buffer
			args := append([]string{c.args[0], "--hub", ts.URL, "--token", "tok"}, c.args[1:]...)
			code, _ := lease(args, &out, &errb)
			if code != c.code || strings.TrimSpace(out.String()) != c.out {
				t.Fatalf("code %d out %q, want %d %q", code, out.String(), c.code, c.out)
			}
		})
	}
	if got["force"] != false || got["issue"] != float64(7) || got["worker_id"] != wid {
		t.Fatalf("last request body %v", got)
	}

	// No hub configured, or one that is down: exit 1, so the caller falls back.
	t.Setenv("CCQUOTA_HUB_URL", "")
	if code, _ := lease([]string{"acquire", "o/r", "7", wid}, &bytes.Buffer{}, &bytes.Buffer{}); code != 1 {
		t.Fatalf("no hub: exit %d, want 1", code)
	}
	if code, _ := lease([]string{"acquire", "--hub", "http://127.0.0.1:1", "--token", "t", "o/r", "7", wid},
		&bytes.Buffer{}, &bytes.Buffer{}); code != 1 {
		t.Fatalf("hub down: exit %d, want 1", code)
	}
	if code, _ := lease([]string{"grab", "o/r", "7", wid}, &bytes.Buffer{}, &bytes.Buffer{}); code != 2 {
		t.Fatalf("bad action: exit %d, want 2", code)
	}
}
