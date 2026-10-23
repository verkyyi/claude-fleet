package credproxy

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// An isolated upstream makes response IDs account scoped. A later HTTP
// request is not automatically an independent inference request.
func TestCodexContinuationDoesNotCrossAccount(t *testing.T) {
	var wrong atomic.Int64
	h := newHarness(t, true, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if strings.Contains(string(body), `"previous_response_id":"resp_old"`) && r.Header.Get("Authorization") != "Bearer tok-old" {
			wrong.Add(1)
			http.Error(w, "response belongs to another account", http.StatusConflict)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"id":"resp_old","output":[]}`)
	})
	pass := PassPrefix + "s"
	h.hub.set(func() { h.hub.bind[pass] = "old" })
	h.do(t, "/v1/proxy/codex/responses", pass, `{"input":"first"}`, nil)
	h.hub.set(func() { h.hub.bind[pass] = "new" })
	h.tick(time.Minute)
	h.do(t, "/v1/proxy/codex/responses", pass, `{"previous_response_id":"resp_old","input":"continue"}`, nil)
	if wrong.Load() != 0 {
		t.Fatal("account-bound continuation forwarded to another subscription")
	}
}

func TestCodexContinuationClassification(t *testing.T) {
	for _, tc := range []struct {
		name, body           string
		header               map[string]string
		independent, unknown bool
		refs                 int
	}{
		{"text", `{"input":"hello","store":false}`, nil, true, false, 0},
		{"full text", `{"input":[{"role":"assistant","content":[{"type":"output_text","text":"old"}]},{"role":"user","content":"new"}]}`, nil, true, false, 0},
		{"previous", `{"previous_response_id":"r","input":"new"}`, nil, false, false, 1},
		{"conversation", `{"conversation":{"id":"c"},"input":"new"}`, nil, false, false, 1},
		{"encrypted", `{"input":[{"type":"compaction","encrypted_content":"blob"}]}`, nil, false, false, 1},
		{"function", `{"input":[{"type":"function_call_output","call_id":"call","output":"result"}]}`, nil, false, false, 1},
		{"header", `{"input":"hello"}`, map[string]string{"X-Codex-Turn-State": "opaque"}, false, false, 1},
		{"metadata", `{"input":"hello","client_metadata":{"x-codex-turn-state":"opaque"}}`, nil, false, false, 1},
		{"duplicate", `{"previous_response_id":"r","previous_response_id":null}`, nil, false, true, 0},
		{"unknown", `{"unknown_state":"opaque"}`, nil, false, true, 0},
		{"file", `{"input":[{"role":"user","content":[{"type":"input_file","file_id":"file"}]}]}`, nil, false, true, 0},
		{"server tool", `{"input":"hello","tools":[{"type":"file_search","vector_store_ids":["v"]}]}`, nil, false, true, 0},
		{"compressed", `{"input":"hello"}`, map[string]string{"Content-Encoding": "zstd"}, false, true, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/v1/proxy/codex/responses", nil)
			for k, v := range tc.header {
				req.Header.Set(k, v)
			}
			got := codexRoute(req, []byte(tc.body))
			if got.Independent != tc.independent || got.Unknown != tc.unknown || len(got.References) != tc.refs {
				t.Fatalf("%+v", got)
			}
			for _, ref := range got.References {
				if len(ref) != 64 {
					t.Fatalf("raw state in protocol: %q", ref)
				}
			}
		})
	}
}

// Sanitized native exec/resume shapes captured against a loopback fake token
// server; the same vectors are exercised by the Python local proxy.
func TestCodexNativeContextSharedVectors(t *testing.T) {
	raw, err := os.ReadFile("testdata/codex_native_context.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name        string            `json:"name"`
		Method      string            `json:"method"`
		Path        string            `json:"path"`
		Headers     map[string]string `json:"headers"`
		Body        json.RawMessage   `json:"body"`
		Independent bool              `json:"independent"`
		Unknown     bool              `json:"unknown"`
		References  []struct {
			Kind  string `json:"kind"`
			Value string `json:"value"`
		} `json:"references"`
	}
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.Name, func(t *testing.T) {
			r := httptest.NewRequest(tc.Method, tc.Path, nil)
			for k, v := range tc.Headers {
				r.Header.Set(k, v)
			}
			got := codexRoute(r, tc.Body)
			want := map[string]bool{}
			for _, ref := range tc.References {
				want[CodexReference(ref.Kind, ref.Value)] = true
			}
			if got.Independent != tc.Independent || got.Unknown != tc.Unknown || len(got.References) != len(want) {
				t.Fatalf("classification %+v, expected independent=%v unknown=%v refs=%d", got, tc.Independent, tc.Unknown, len(want))
			}
			for _, ref := range got.References {
				if !want[ref] {
					t.Fatalf("unexpected reference %q", ref)
				}
			}
		})
	}
}

// Optional receipt check against the unmodified request bodies captured by
// Capacity.test_native_cli_tool_loopback. No inference or network is involved.
func TestCodexNativeToolWire(t *testing.T) {
	path := os.Getenv("FLEET_CODEX_NATIVE_WIRE")
	if path == "" {
		t.Skip("explicit native fixture capture only")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var requests []json.RawMessage
	if err := json.Unmarshal(raw, &requests); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 3 {
		t.Fatalf("want first/tool-result/resume, got %d", len(requests))
	}
	// Provider envelopes emitted by the Python fixture; client-generated IDs
	// must not appear among the references, even on native resume.
	ids := [][]string{nil, {"rs_source", "ct_source", "call_source"},
		{"rs_source", "ct_source", "call_source", "rs_source_2", "msg_source_2"}}
	for i, body := range requests {
		got := codexRoute(httptest.NewRequest("POST", "/codex/responses", nil), body)
		want := map[string]bool{}
		for _, id := range ids[i] {
			want[CodexReference("id", id)] = true
		}
		if i > 0 {
			want[CodexReference("encrypted", "fixture-opaque")] = true
		}
		if i > 1 {
			want[CodexReference("encrypted", "fixture-opaque_2")] = true
		}
		if got.Unknown || got.Independent != (i == 0) || len(got.References) != len(want) {
			t.Fatalf("request %d: %+v, want %d references", i+1, got, len(want))
		}
		for _, ref := range got.References {
			if !want[ref] {
				t.Fatalf("request %d: unexpected reference %s", i+1, ref)
			}
		}
	}
}

func TestCodexContinuationCommitsBeforeDelivery(t *testing.T) {
	event := "event: response.completed\r\ndata: {\"response\":{\"id\":\"ref\"}}\r\n\r\n"
	for _, sse := range []bool{false, true} {
		raw, ctype := `{"id":"ref"}`, "application/json"
		if sse {
			raw, ctype = event, "text/event-stream"
		}
		calls := 0
		reader, err := codexResponseReader(strings.NewReader(raw), ctype, func(map[string]any) error { calls++; return errors.New("fixture unavailable") })
		var got []byte
		if err == nil {
			got, err = io.ReadAll(reader)
		}
		if err == nil || len(got) != 0 || calls != 1 {
			t.Fatalf("uncommitted state delivered: sse=%v bytes=%q calls=%d error=%v", sse, got, calls, err)
		}
		reader, err = codexResponseReader(strings.NewReader(raw), ctype, func(map[string]any) error { return nil })
		if err != nil {
			t.Fatal(err)
		}
		got, err = io.ReadAll(reader)
		if err != nil || string(got) != raw {
			t.Fatal("response bytes changed", err)
		}
	}
	// Earlier delivered events cannot be retracted; never deliver a later event
	// whose source could not be committed and never replay the earlier event.
	calls := 0
	reader, _ := codexResponseReader(strings.NewReader(event+event), "text/event-stream", func(map[string]any) error {
		calls++
		if calls == 2 {
			return errors.New("fixture unavailable")
		}
		return nil
	})
	raw, err := io.ReadAll(reader)
	if err == nil || string(raw) != event || calls != 2 {
		t.Fatalf("unsafe partial stream %q %v calls=%d", raw, err, calls)
	}
}

func TestCodexContinuationOutputSources(t *testing.T) {
	refs, err := codexOutputReferences(map[string]any{"response": map[string]any{"id": "r", "conversation": "c", "output": []any{
		map[string]any{"id": "item", "type": "compaction", "encrypted_content": "blob"},
		map[string]any{"call_id": "call", "type": "function_call"},
	}}})
	if err != nil || len(refs) != 5 {
		t.Fatalf("refs=%v err=%v", refs, err)
	}
	for _, ref := range refs {
		if len(ref) != 64 {
			t.Fatal("raw state in record")
		}
	}
}

func TestCodexContinuationNeverFollowsRedirect(t *testing.T) {
	for _, status := range []int{http.StatusTemporaryRedirect, http.StatusSeeOther} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			var calls atomic.Int64
			h := newHarness(t, true, func(w http.ResponseWriter, r *http.Request) {
				if calls.Add(1) == 1 {
					w.Header().Set("Location", "/replayed")
					w.WriteHeader(status)
					return
				}
				io.WriteString(w, `{"id":"unexpected-replay"}`)
			})
			pass := PassPrefix + "s"
			h.hub.set(func() { h.hub.bind[pass] = "old" })
			req := httptest.NewRequest(http.MethodPost, "/v1/proxy/codex/responses", strings.NewReader(`{"input":"once"}`))
			req.Header.Set("Authorization", "Bearer "+pass)
			w := httptest.NewRecorder()
			h.p.Handler().ServeHTTP(w, req)
			if calls.Load() != 1 || w.Code != http.StatusBadRequest || w.Header().Get("Location") != "" {
				t.Fatalf("redirect replayed: calls=%d status=%d", calls.Load(), w.Code)
			}
		})
	}
}

func TestCodexContinuationRequiresHubCapability(t *testing.T) {
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// An old hub ignores the new JSON fields and returns a normal lease.
		io.WriteString(w, `{"valid":true,"access_token":"fixture","account":"old"}`)
	}))
	defer hub.Close()
	router := &HubResolver{URL: hub.URL, Token: "fixture"}
	got, err := router.ResolveCodex(t.Context(), "fixture-pass", CodexRoute{Independent: true})
	if err != nil || got.Valid || got.Error != CodexContinuationUnavailable {
		t.Fatalf("legacy hub accepted: %+v %v", got, err)
	}
	if err := router.RecordCodexAffinity(t.Context(), "fixture-pass", Resolution{Owner: "pool", Account: "old", CredentialID: "fixture"}, []string{CodexReference("id", "ref")}); err == nil {
		t.Fatal("legacy hub falsely acknowledged source registration")
	}
}
