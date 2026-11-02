package api

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"
)

// Exercise the authenticated HTTP open and its actual relay request. Only the
// relay's dial is replaced: the home service echoes what it would start.
func TestChatOpenPodProvider(t *testing.T) {
	for _, tc := range []struct {
		name, machine, setting, body, want string
		status                             int
		notice                             bool
		agents                             []string
	}{
		{"explicit", "u-testpod", "", `{"agent":"claude","text":"hello","images":[{"ref":"image"}]}`, "codex", 200, true, []string{"codex"}},
		{"omitted", "u-testpod", "", `{"text":"hello"}`, "codex", 200, true, []string{"codex"}},
		{"empty", "u-testpod", "", `{"agent":"","text":"hello"}`, "codex", 200, true, []string{"codex"}},
		{"empty-body", "u-testpod", "", ``, "codex", 200, true, []string{"codex"}},
		{"empty-object", "u-testpod", "", `{}`, "codex", 200, true, []string{"codex"}},
		{"array-body", "u-testpod", "", `[]`, "", 400, false, []string{"codex"}},
		{"null-body", "u-testpod", "", `null`, "", 400, false, []string{"codex"}},
		{"malformed-body", "u-testpod", "", `{`, "", 400, false, []string{"codex"}},
		{"codex", "u-testpod", "", `{"agent":"codex","text":"hello"}`, "codex", 200, false, []string{"codex"}},
		{"ordinary", "home-box", "", `{"agent":"claude","text":"hello"}`, "claude", 200, false, []string{"claude", "codex"}},
		{"wildcard", "u-testpod", "*", `{"agent":"claude","text":"hello"}`, "claude", 200, false, []string{"claude", "codex"}},
		{"claude-enabled", "u-testpod", "claude,codex", `{"agent":"claude","text":"hello"}`, "claude", 200, false, []string{"claude", "codex"}},
		{"no-codex-fallback", "u-testpod", "deepseek", `{"agent":"claude","text":"hello"}`, "", 409, false, []string{}},
		{"invalid-agent", "u-testpod", "", `{"agent":"typo","text":"hello"}`, "", 400, false, []string{"codex"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newFleetHarness(t)
			enablePeople(t, h, pAlice)
			setChatHome(t, h, pAlice, tc.machine, "alice")
			if tc.setting != "" {
				setRegion(t, h, CredPodProvidersKey, tc.setting)
			}
			h.srv.ChatRelayKeepSecs = 60
			h.srv.ChatPerMinute = -1
			got := make(chan map[string]any, 1)
			service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				_ = json.NewDecoder(r.Body).Decode(&body)
				got <- body
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(map[string]any{"fid": "test-fid", "state": "sent", "agent": body["agent"]})
			}))
			defer service.Close()
			tr := h.srv.chatPool.transport(pAlice+"\x00"+tc.machine+"\x00alice", time.Minute, func(ctx context.Context) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "tcp", service.Listener.Addr().String())
			})
			defer tr.CloseIdleConnections()
			resp, out := regionOpen(t, h, pAlice, tc.body)
			if resp.StatusCode != tc.status {
				t.Fatalf("open: %d %v; want %d", resp.StatusCode, out, tc.status)
			}
			if tc.status == 200 {
				body := <-got
				if body["agent"] != tc.want {
					t.Fatalf("relayed %v; want %s and original text", body, tc.want)
				}
				var original map[string]any
				_ = json.Unmarshal([]byte(tc.body), &original)
				if !reflect.DeepEqual(body["images"], original["images"]) || body["text"] != original["text"] {
					t.Fatalf("images changed: %v", body)
				}
				if tc.notice && out["notice"] != "这台托管机器只能用 Codex，已用 Codex 打开" {
					t.Fatalf("missing fallback receipt: %v", out)
				}
				if !tc.notice && out["notice"] != nil {
					t.Fatalf("unexpected fallback receipt: %v", out)
				}
				if out["agent"] != tc.want {
					t.Fatalf("wrong receipt agent: %v", out)
				}
			} else {
				select {
				case body := <-got:
					t.Fatalf("refused request relayed: %v", body)
				default:
				}
			}
			homeResp := chatDo(t, h, "GET", "/v1/chat/home", personCookie(pAlice, "alice"), nil, "")
			raw, _ := io.ReadAll(homeResp.Body)
			var home struct {
				Agents []string `json:"agents"`
			}
			if json.Unmarshal(raw, &home) != nil || !reflect.DeepEqual(home.Agents, tc.agents) {
				t.Fatalf("home agents: %s; want %v", raw, tc.agents)
			}
		})
	}
}
