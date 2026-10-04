package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ccquota move's one-line, one-exit-code contract (claude-fleet#1426) — what
// fleet-move.sh --via hub branches on.
func TestMoveCLIContract(t *testing.T) {
	movePollEvery = 10 * time.Millisecond
	wid := "11111111-1111-4111-8111-111111111111/issue-7"
	bundle := filepath.Join(t.TempDir(), "b.tar")
	if err := os.WriteFile(bundle, []byte("tar"), 0o600); err != nil {
		t.Fatal(err)
	}
	send := []string{"send", "--node", "m4", "--bundle", bundle, "--branch", "issue-7", "--sid", "s", "--name", "n", "verkyyi/claude-fleet", wid}
	cases := []struct {
		name   string
		args   []string
		move   []string // answers to successive POST /v1/node/move
		status int
		code   int
		out    string
	}{
		{"plan local", []string{"plan", "verkyyi/claude-fleet", wid}, []string{`{"local":true,"placement":{"machine":"m5.local","reason":"chose m5"}}`}, 200,
			0, "LOCAL m5\tchose m5"},
		{"plan remote", []string{"plan", "--node", "m4", "verkyyi/claude-fleet", wid}, []string{`{"local":false,"movable":true,"placement":{"machine":"m4","reason":"chose m4"}}`}, 200,
			0, "REMOTE m4 movable\tchose m4"},
		{"moved after a wait", send, []string{
			`{"placement":{"machine":"m4"},"to_wid":"22222222-2222-4222-8222-222222222222/issue-7","operation":{"operation_id":"op","status":"accepted"}}`,
			`{"operation":{"operation_id":"op","status":"running"}}`,
			`{"operation":{"operation_id":"op","status":"succeeded","result":{"window":"@3","pid":"42"}}}`}, 200,
			0, "MOVED m4 @3 42\t22222222-2222-4222-8222-222222222222/issue-7"},
		{"target failed", send, []string{
			`{"placement":{"machine":"m4"},"operation":{"operation_id":"op","status":"failed","result":{"error":{"code":"EXECUTION_FAILED","message":"stale branch"}}}}`}, 200,
			5, "FAILED EXECUTION_FAILED\tstale branch"},
		{"held", send, []string{`{"error":{"code":"ALREADY_CLAIMED","message":"#7 is leased to m3"},"holder":{"node":"m3"}}`}, 409,
			3, "HELD m3\t#7 is leased to m3"},
		{"busy", send, []string{`{"error":{"code":"INVALID_STATE","message":"a working session is never moved"}}`}, 400,
			4, "REFUSED INVALID_STATE\ta working session is never moved"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			n := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer tok" {
					http.Error(w, "bad", http.StatusUnauthorized)
					return
				}
				if r.URL.Path == "/v1/node/move/bundle" {
					_, _ = w.Write([]byte(`{"bundle_id":"0123456789abcdef0123456789abcdef"}`))
					return
				}
				var req map[string]any
				_ = json.NewDecoder(r.Body).Decode(&req)
				if req["action"] == "move" && req["bundle_id"] != "0123456789abcdef0123456789abcdef" {
					http.Error(w, "no bundle named", http.StatusBadRequest)
					return
				}
				body := c.move[len(c.move)-1]
				if n < len(c.move) {
					body = c.move[n]
				}
				n++
				if n == 1 {
					w.WriteHeader(c.status)
				}
				_, _ = w.Write([]byte(body))
			}))
			defer srv.Close()
			var stdout, stderr bytes.Buffer
			code, err := move(append([]string{c.args[0], "--hub", srv.URL, "--token", "tok"}, c.args[1:]...), &stdout, &stderr)
			if err != nil || code != c.code || strings.TrimSpace(stdout.String()) != c.out {
				t.Fatalf("got %d %v %q (stderr %q); want %d %q", code, err, stdout.String(), stderr.String(), c.code, c.out)
			}
		})
	}
}

func TestMoveCLIUnknownAfterWait(t *testing.T) {
	movePollEvery = 10 * time.Millisecond
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/node/move/bundle" {
			_, _ = w.Write([]byte(`{"bundle_id":"0123456789abcdef0123456789abcdef"}`))
			return
		}
		_, _ = w.Write([]byte(`{"placement":{"machine":"m4"},"operation":{"operation_id":"op","status":"accepted"}}`))
	}))
	defer srv.Close()
	bundle := filepath.Join(t.TempDir(), "b.tar")
	_ = os.WriteFile(bundle, []byte("tar"), 0o600)
	var stdout, stderr bytes.Buffer
	code, _ := move([]string{"send", "--hub", srv.URL, "--token", "tok", "--node", "m4", "--bundle", bundle, "--branch", "b",
		"--sid", "s", "--name", "n", "--wait", "50ms", "o/r", "11111111-1111-4111-8111-111111111111/issue-7"}, &stdout, &stderr)
	if code != moveUnknown || !strings.HasPrefix(stdout.String(), "UNKNOWN op\t") {
		t.Fatalf("got %d %q; want UNKNOWN (never a guess)", code, stdout.String())
	}
}
