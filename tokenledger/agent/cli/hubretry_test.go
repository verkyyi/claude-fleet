package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// claude-fleet#4933: a hub replica stopping in a rolling release cut a place
// it still held, and the spawn read `hub unreachable (EOF)`. The connection
// dropping under the request (or a gateway answering for the gone replica) is
// retried with the SAME request — same idempotency key — so the caller sees
// the answer, never the EOF; a real answer is never retried.
func TestHubRetryTransient(t *testing.T) {
	old := hubRetryDelays
	hubRetryDelays = []time.Duration{time.Millisecond, time.Millisecond}
	defer func() { hubRetryDelays = old }()

	// fail is what the first n calls get: "eof" hangs up mid-request, "502"
	// is a gateway's HTML page, "503json" is the hub's own answer.
	serve := func(fail string, n int, ok string) (*httptest.Server, func() []map[string]any) {
		var mu sync.Mutex
		var got []map[string]any
		ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var b map[string]any
			_ = json.NewDecoder(r.Body).Decode(&b)
			mu.Lock()
			got = append(got, b)
			k := len(got)
			mu.Unlock()
			if k <= n {
				switch fail {
				case "eof":
					c, _, _ := w.(http.Hijacker).Hijack()
					c.Close()
				case "502":
					w.Header().Set("Content-Type", "text/html")
					w.WriteHeader(http.StatusBadGateway)
					_, _ = w.Write([]byte("<html>502 Bad Gateway</html>"))
				case "503json":
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusServiceUnavailable)
					_, _ = w.Write([]byte(`{"error":{"code":"NO_ELIGIBLE_NODE","message":"No machine can take a new session now"}}`))
				}
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(ok))
		}))
		return ts, func() []map[string]any {
			mu.Lock()
			defer mu.Unlock()
			return append([]map[string]any(nil), got...)
		}
	}
	wid := "11111111-1111-4111-8111-111111111111/issue-7"
	done := `{"local":false,"placement":{"machine":"mac-a","reason":"chose mac-a"},"operation":{"operation_id":"op_2","status":"succeeded"},"outcome":{"state":"done","exit":0,"window":"@42","node":"mac-a"}}`

	for _, fail := range []string{"eof", "502"} {
		t.Run("place "+fail, func(t *testing.T) {
			ts, got := serve(fail, 2, done)
			defer ts.Close()
			var out, errb bytes.Buffer
			code, err := place([]string{"--hub", ts.URL, "--token", "tok", "o/r", "7", wid}, &out, &errb)
			if code != 0 || strings.TrimRight(out.String(), "\n") != "REMOTE mac-a op_2 done @42\tchose mac-a" {
				t.Fatalf("code %d err %v out %q stderr %q; want the answer after two retries", code, err, out.String(), errb.String())
			}
			reqs := got()
			k, _ := reqs[0]["idempotency_key"].(string)
			if len(reqs) != 3 || !strings.HasPrefix(k, "place-") || reqs[1]["idempotency_key"] != k || reqs[2]["idempotency_key"] != k {
				t.Fatalf("requests %v; want 3 carrying one minted key", reqs)
			}
			if n := strings.Count(errb.String(), "ccquota place: retry "); n != 2 {
				t.Fatalf("stderr %q; want two retry lines", errb.String())
			}
		})
	}
	t.Run("place gives up", func(t *testing.T) {
		ts, got := serve("eof", 9, done)
		defer ts.Close()
		code, err := place([]string{"--hub", ts.URL, "--token", "tok", "o/r", "7", wid}, &bytes.Buffer{}, &bytes.Buffer{})
		if code != 1 || err == nil || len(got()) != 1+len(hubRetryDelays) {
			t.Fatalf("code %d err %v after %d tries; want exit 1 after %d", code, err, len(got()), 1+len(hubRetryDelays))
		}
	})
	t.Run("place keeps a named key", func(t *testing.T) {
		ts, got := serve("eof", 1, done)
		defer ts.Close()
		if code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "--key", "k-1", "o/r", "7", wid}, &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
			t.Fatalf("exit %d", code)
		}
		if reqs := got(); len(reqs) != 2 || reqs[0]["idempotency_key"] != "k-1" || reqs[1]["idempotency_key"] != "k-1" {
			t.Fatalf("requests %v; want k-1 twice", reqs)
		}
	})
	t.Run("the hub's own 503 is an answer", func(t *testing.T) {
		ts, got := serve("503json", 9, done)
		defer ts.Close()
		var out bytes.Buffer
		code, _ := place([]string{"--hub", ts.URL, "--token", "tok", "o/r", "7", wid}, &out, &bytes.Buffer{})
		if code != placeRefused || len(got()) != 1 {
			t.Fatalf("code %d after %d tries; want REFUSED at once", code, len(got()))
		}
	})
	t.Run("lease eof", func(t *testing.T) {
		ts, got := serve("eof", 1, `{"granted":true,"lease":{"node":"mac-a","worker_id":"`+wid+`"}}`)
		defer ts.Close()
		var out, errb bytes.Buffer
		code, err := lease([]string{"acquire", "--hub", ts.URL, "--token", "tok", "o/r", "7", wid}, &out, &errb)
		if code != 0 || strings.TrimSpace(out.String()) != "GRANTED mac-a" || len(got()) != 2 {
			t.Fatalf("code %d err %v out %q tries %d stderr %q", code, err, out.String(), len(got()), errb.String())
		}
	})
}
