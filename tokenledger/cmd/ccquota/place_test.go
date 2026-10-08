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
		// claude-fleet#1610: machines that declined first ride the line's
		// third field; every machine declining is REFUSED ALL_DECLINED.
		{"done after a decline", `{"local":false,"placement":{"machine":"m3","reason":"chose m3"},
			"operation":{"operation_id":"op_5","status":"succeeded"},"outcome":{"state":"done","exit":0,"window":"@9","node":"m3"},
			"attempts":[{"machine":"m4","operation_id":"op_4","state":"failed","exit":1,"why":"fleet discover: fork/exec"}]}`, 200,
			0, "REMOTE m3 op_5 done @9\tchose m3\tafter m4:op_4:1"},
		{"local after a decline", `{"local":true,"placement":{"machine":"m5","reason":"chose m5"},
			"attempts":[{"machine":"m4","state":"refused","exit":1,"why":"node gone"}]}`, 200,
			0, "LOCAL m5\tchose m5\tafter m4:-:1"},
		{"all declined", `{"error":{"code":"ALL_DECLINED","message":"every machine that could take it said no — m4: declined: a; m3: declined: b"},
			"attempts":[{"machine":"m4","operation_id":"op_4","exit":1,"why":"a"},{"machine":"m3","operation_id":"op_6","exit":2,"why":"b"}]}`, 409,
			4, "REFUSED ALL_DECLINED\tevery machine that could take it said no — m4: declined: a; m3: declined: b\tafter m4:op_4:1,m3:op_6:2"},
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
	if got["tries"] != float64(placeTries) {
		t.Fatalf("tries = %v; want %d so the hub may try the next machine", got["tries"], placeTries)
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

// `scratch` in place of the issue (claude-fleet#1541): the body names the
// asking fleet and kind=scratch, carries --name, and no issue or worker_id.
func TestPlaceCLIScratch(t *testing.T) {
	var got map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{"local":false,"placement":{"machine":"m4","reason":"chose m4"},"operation":{"operation_id":"op_9","status":"succeeded"},"outcome":{"state":"done","exit":0,"window":"@7","node":"m4"}}`))
	}))
	defer ts.Close()
	fleet := "11111111-1111-4111-8111-111111111111"
	var out, errb bytes.Buffer
	code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "--node", "m4", "--name", "试一下", "o/r", "scratch", fleet}, &out, &errb)
	if code != 0 || strings.TrimRight(out.String(), "\n") != "REMOTE m4 op_9 done @7\tchose m4" {
		t.Fatalf("code %d out %q", code, out.String())
	}
	if got["kind"] != "scratch" || got["fleet_id"] != fleet || got["name"] != "试一下" || got["node"] != "m4" {
		t.Fatalf("request body %v", got)
	}
	for _, k := range []string{"issue", "worker_id"} {
		if _, has := got[k]; has {
			t.Fatalf("a scratch request carried %s: %v", k, got)
		}
	}
	if code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "o/r", "scratch", "not-a-uuid"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 2 {
		t.Fatalf("scratch with no fleet UUID: exit %d, want 2", code)
	}
	if code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "--name", "x", "o/r", "7", fleet + "/issue-7"}, &bytes.Buffer{}, &bytes.Buffer{}); code != 2 {
		t.Fatalf("--name on an issue: exit %d, want 2", code)
	}
}

// claude-fleet#1810: the worker assertion a session's tool service hands the
// spawn travels as the X-Fleet-Worker header, from the environment only —
// and with none set, no header at all (the node's own call, as before).
func TestPlaceCarriesWorkerAssertion(t *testing.T) {
	var hdr []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hdr = r.Header.Values("X-Fleet-Worker")
		_, _ = w.Write([]byte(`{"local":true,"placement":{"machine":"m5"}}`))
	}))
	defer ts.Close()
	wid := "11111111-1111-4111-8111-111111111111/issue-7"
	args := []string{"--hub", ts.URL, "--token", "tok", "o/r", "7", wid}
	t.Setenv(workerAssertEnv, "")
	if code, _ := place(args, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 || len(hdr) != 0 {
		t.Fatalf("no assertion: code %d, header %q; want 0 and none", code, hdr)
	}
	t.Setenv(workerAssertEnv, "fwa1.e30.c2ln")
	if code, _ := place(args, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 || len(hdr) != 1 || hdr[0] != "fwa1.e30.c2ln" {
		t.Fatalf("assertion: code %d, header %q; want it sent once", code, hdr)
	}
}
