package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// ccquota place's one-line, one-exit-code contract (claude-fleet#1425) — what
// dash-issue-session.sh branches on.
func TestPlaceCLIContract(t *testing.T) {
	var got map[string]any
	answer := func(status int, body string) *httptest.Server {
		return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/v1/node/place" || r.Header.Get("Authorization") != "Bearer tok" {
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
		code       int
		out        string
	}{
		{"local", `{"local":true,"placement":{"machine":"m5","reason":"chose m5 (score 0.7)"}}`, 200,
			0, "LOCAL m5\tchose m5 (score 0.7)"},
		{"remote", `{"local":false,"placement":{"machine":"m4","reason":"chose m4;\n m5 excluded: load 1.00/core > 0.8"},
			"operation":{"operation_id":"op_1","status":"accepted"}}`, 200,
			0, "REMOTE m4 op_1 accepted\tchose m4; m5 excluded: load 1.00/core > 0.8"},
		// claude-fleet#1586: what became of the start there.
		{"remote done", `{"local":false,"placement":{"machine":"m4","reason":"chose m4"},
			"operation":{"operation_id":"op_2","status":"succeeded"},"outcome":{"state":"done","exit":0,"window":"@42","node":"m4"}}`, 200,
			0, "REMOTE m4 op_2 done @42\tchose m4"},
		{"remote declined", `{"local":false,"placement":{"machine":"m4","reason":"chose m4"},
			"operation":{"operation_id":"op_3","status":"failed"},
			"outcome":{"state":"refused","exit":2,"stderr1":"dash-issue-session: at capacity:\n 6/6","node":"m4"}}`, 200,
			5, "DECLINED m4 op_3 2\tdash-issue-session: at capacity: 6/6"},
		{"remote unknown", `{"local":false,"placement":{"machine":"m4","reason":"chose m4"},
			"operation":{"operation_id":"op_4","status":"accepted"},"outcome":{"state":"unknown","stderr1":"no final state from m4","node":"m4"}}`, 200,
			6, "UNKNOWN m4 op_4\tno final state from m4"},
		{"held", `{"error":{"code":"ALREADY_CLAIMED","message":"#7 is leased to m4"},"holder":{"node":"m4"}}`, 409,
			3, "HELD m4\t#7 is leased to m4"},
		{"no machine", `{"error":{"code":"NO_ELIGIBLE_NODE","message":"No machine can take a new session now"}}`, 503,
			4, "REFUSED NO_ELIGIBLE_NODE\tNo machine can take a new session now"},
		{"not a hub fleet", `{"error":"fleet x is not registered to this node"}`, 403, 1, ""},
		{"hub broken", `{"error":{"code":"INTERNAL","message":"db"}}`, 500, 1, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ts := answer(c.status, c.body)
			defer ts.Close()
			var out, errb bytes.Buffer
			code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "--origin-wid", "p/issue-1", "o/r", "7", wid}, &out, &errb)
			if code != c.code || strings.TrimRight(out.String(), "\n") != c.out {
				t.Fatalf("code %d out %q, want %d %q", code, out.String(), c.code, c.out)
			}
		})
	}
	if got["node"] != "auto" || got["issue"] != float64(7) || got["worker_id"] != wid || got["origin_wid"] != "p/issue-1" {
		t.Fatalf("last request body %v", got)
	}
	if _, has := got["wait"]; has {
		t.Fatalf("no --wait sent a wait: %v; the hub's default must apply", got)
	}
	ts := answer(200, `{"local":true,"placement":{"machine":"m5"}}`)
	defer ts.Close()
	var out, errb bytes.Buffer
	if code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "--wait", "0", "o/r", "7", wid}, &out, &errb); code != 0 || got["wait"] != float64(0) {
		t.Fatalf("--wait 0: code %d, body %v; want wait 0 sent", code, got)
	}

	t.Setenv("CCQUOTA_HUB_URL", "")
	if code, _ := place([]string{"o/r", "7", wid}, &bytes.Buffer{}, &bytes.Buffer{}); code != 1 {
		t.Fatalf("no hub: exit %d, want 1", code)
	}
	if code, _ := place([]string{"--hub", "http://127.0.0.1:1", "--token", "t", "o/r", "7", wid},
		&bytes.Buffer{}, &bytes.Buffer{}); code != 1 {
		t.Fatalf("hub down: exit %d, want 1", code)
	}
	if code, _ := place([]string{"o/r", "7"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 2 {
		t.Fatalf("missing worker_id: exit %d, want 2", code)
	}
}
