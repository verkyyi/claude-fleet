//go:build browseracceptance

package api

import (
	"context"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestChatAttachmentChromium(t *testing.T) {
	for _, blocked := range []bool{false, true} {
		t.Run(map[bool]string{false: "direct", true: "udp-denied"}[blocked], func(t *testing.T) {
			h, svc, host, login := chatHarness(t)
			setChatHome(t, h, pAlice, host, login)
			h.srv.ConsoleFS = os.DirFS("../../../extras/web-console/dist")
			var turnsStarted atomic.Int32
			svc.mu.Lock()
			svc.conversation = func(w http.ResponseWriter) {
				w.Header().Set("Content-Type", "application/json")
				if turnsStarted.Load() >= 4 {
					io.WriteString(w, `{"session":"s1","items":[{"t":"user","text":"ui-once"},{"t":"text","d":"recovered-ui-once"}]}`)
				} else {
					io.WriteString(w, `{"session":"s1","items":[]}`)
				}
			}
			svc.turn = func(w http.ResponseWriter) {
				w.Header().Set("Content-Type", "application/x-ndjson")
				io.WriteString(w, "{\"t\":\"text\",\"d\":\"中文-once\"}\n")
				w.(http.Flusher).Flush()
				if turnsStarted.Add(1) >= 3 {
					// Keep the third turn alive while the browser cuts its transport.
					time.Sleep(3 * time.Second)
				} else {
					time.Sleep(400 * time.Millisecond)
				}
				io.WriteString(w, "{\"t\":\"done\"}\n")
			}
			svc.mu.Unlock()
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
			defer cancel()
			args := []string{"chat-browser.mjs"}
			if blocked {
				args = append(args, "--deny-udp")
			}
			cmd := exec.CommandContext(ctx, "node", args...)
			cmd.Dir = filepath.Join("..", "..", "..", "extras", "browser-transport")
			cookie := personCookie(pAlice, "Alice")
			cmd.Env = append(os.Environ(), "FLEET_TEST_ORIGIN="+h.http.URL, "FLEET_TEST_COOKIE="+cookie.Name+"="+cookie.Value)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("Chromium: %v\n%s", err, out)
			}
			t.Log(string(out))
			waitFor(t, 10*time.Second, "chat attachments released", func() bool { return h.srv.chatRelays.open() == 0 })
			turns := 0
			for _, hit := range svc.seen() {
				if strings.HasPrefix(hit, "POST /api/turn ") {
					turns++
				}
			}
			want := 4
			if turns != want {
				t.Fatalf("turns %d want %d (replay)", turns, want)
			}
			var up, down int64
			if err := h.srv.Store.DB().QueryRow(`SELECT COALESCE(SUM(bytes_up),0), COALESCE(SUM(bytes_down),0) FROM fleet_chat_requests`).Scan(&up, &down); err != nil {
				t.Fatal(err)
			}
			if !blocked && (up != 0 || down != 0) {
				t.Fatalf("direct payload traversed hub: %d/%d", up, down)
			}
			if blocked && (up == 0 || down == 0) {
				t.Fatal("fallback counters missing")
			}
			t.Logf("node requests=%d model-turn stand-ins=%d hub payload up=%d down=%d chat relay entries=0 Safari=pending", len(svc.seen()), turns, up, down)
		})
	}
}
