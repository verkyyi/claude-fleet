package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

func dialChatAttachment(t *testing.T, h *harness, cookie *http.Cookie, query string) (*websocket.Conn, int) {
	t.Helper()
	header := http.Header{"Origin": {h.http.URL}}
	if cookie != nil {
		header.Set("Cookie", cookie.String())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, r, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(h.http.URL, "http")+"/v1/chat/connect?"+query, &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		if r != nil {
			return nil, r.StatusCode
		}
		t.Fatal(err)
	}
	return c, 101
}

// WebSocket refusals carry the original HTTP status on the signaling lane.
func chatAttachmentRefusal(t *testing.T, h *harness, cookie *http.Cookie, query string) int {
	t.Helper()
	c, st := dialChatAttachment(t, h, cookie, query)
	if c == nil {
		return st
	}
	defer c.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := c.Read(ctx)
	var sig control.AttachmentSignal
	if err != nil || json.Unmarshal(b, &sig) != nil || sig.T != "error" {
		t.Fatalf("expected refusal, got %s %v", b, err)
	}
	return sig.Status
}

func chatAttachmentQuery(route, id, body string) string {
	return fmt.Sprintf("target=%s&request=%s&bytes=%d", route, id, len(body))
}

func (a *attachmentClient) text(t *testing.T, value string) {
	t.Helper()
	var err error
	if a.dc != nil {
		err = a.dc.SendText(value)
	} else {
		err = a.ws.Write(context.Background(), websocket.MessageText, []byte(value))
	}
	if err != nil {
		t.Fatal(err)
	}
}

func chatAttachmentResponse(t *testing.T, a *attachmentClient, body string) (int, string) {
	t.Helper()
	if body != "" {
		a.send(t, []byte(body))
	}
	a.text(t, `{"t":"request_end"}`)
	ch := a.signals
	if a.dc != nil {
		ch = a.data
	}
	status := 0
	var out strings.Builder
	for {
		f := receiveAttachment(t, ch)
		if f.typ == websocket.MessageBinary {
			out.Write(f.b)
			continue
		}
		var v control.ChatAttachmentFrame
		if err := json.Unmarshal(f.b, &v); err != nil {
			t.Fatal(err)
		}
		switch v.T {
		case "headers":
			status = v.Status
		case "end":
			a.text(t, `{"t":"received"}`)
			return status, out.String()
		case "failed":
			t.Fatalf("request failed: %s", v.Error)
		}
	}
}

func TestChatAttachmentRequests(t *testing.T) {
	for _, direct := range []bool{false, true} {
		t.Run(fmt.Sprint(direct), func(t *testing.T) {
			h, svc, host, login := chatHarness(t)
			setChatHome(t, h, pAlice, host, login)
			cookie := personCookie(pAlice, "Alice")
			close(svc.release)
			for _, route := range []string{"conversation", "turn", "stop", "answer"} {
				body := `{"text":"中文-once","turn":"t1","rid":"r1"}`
				if route == "conversation" {
					body = ""
				}
				id := control.NewOpID()
				c, status := dialChatAttachment(t, h, cookie, chatAttachmentQuery(route, id, body))
				if status != 101 {
					t.Fatalf("%s: %d", route, status)
				}
				a := connectAttachmentSocket(t, c, direct)
				status, response := chatAttachmentResponse(t, a, body)
				if status != 200 || response == "" {
					t.Fatalf("%s: %d %q", route, status, response)
				}
				if route == "turn" && !strings.Contains(response, "中文-once") {
					t.Fatalf("lost NDJSON/UTF-8: %q", response)
				}
				waitFor(t, 5*time.Second, "request released", func() bool { return h.srv.chatRelays.open() == 0 })
				var outcome string
				var up, down int64
				if err := h.srv.Store.DB().QueryRow(`SELECT outcome, bytes_up, bytes_down FROM fleet_chat_requests WHERE id = ?`, id).Scan(&outcome, &up, &down); err != nil {
					t.Fatal(err)
				}
				if direct && (up != 0 || down != 0 || !strings.HasPrefix(outcome, "direct ")) {
					t.Fatalf("payload through hub: %s %d/%d", outcome, up, down)
				}
				if !direct && (down == 0 || (body != "" && up == 0) || !strings.HasPrefix(outcome, "relay ")) {
					t.Fatalf("missing fallback traffic: %s %d/%d", outcome, up, down)
				}
				t.Logf("%s %s: hub payload up=%d down=%d", route, outcome, up, down)
				if st := chatAttachmentRefusal(t, h, cookie, chatAttachmentQuery(route, id, body)); st != 409 {
					t.Fatalf("duplicate %s: %d", id, st)
				}
			}
			if hits := svc.seen(); len(hits) != 4 {
				t.Fatalf("request duplicated: %v", hits)
			}
			for _, hit := range svc.seen() {
				if !strings.Contains(hit, "person="+pAlice+" cookie=") {
					t.Fatal(hit)
				}
			}
			if h.srv.termRelays.open() != 0 {
				t.Fatal("chat touched terminal resources")
			}
		})
	}
}

func TestChatAttachmentAdmission(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setChatHome(t, h, pAlice, host, login)
	cookie := personCookie(pAlice, "Alice")
	query := func() string { return chatAttachmentQuery("conversation", control.NewOpID(), "") }
	for _, q := range []string{query() + "&person=" + pBob, strings.Replace(query(), "conversation", "../../etc/passwd", 1), query() + "&previous=old", "target=turn&request=bad&bytes=0", "target=turn&request=" + control.NewOpID() + "&bytes=1048577"} {
		if st := chatAttachmentRefusal(t, h, cookie, q); st < 400 {
			t.Fatalf("admitted %s: %d", q, st)
		}
	}
	if st := chatAttachmentRefusal(t, h, nil, query()); st == 101 {
		t.Fatalf("anonymous admitted: %d", st)
	}
	setHubSetting(t, h.srv, maintenanceKey(host), "drill")
	if st := chatAttachmentRefusal(t, h, cookie, query()); st != 503 {
		t.Fatalf("maintenance: %d", st)
	}
	setHubSetting(t, h.srv, maintenanceKey(host), "")
	h.srv.ChatMaxPerPerson = 1
	c, st := dialChatAttachment(t, h, cookie, query())
	if st != 101 {
		t.Fatal(st)
	}
	if st := chatAttachmentRefusal(t, h, cookie, query()); st != 429 {
		t.Fatalf("concurrent cap: %d", st)
	}
	c.CloseNow()
	waitFor(t, 5*time.Second, "admission released", func() bool {
		h.srv.chatGate.mu.Lock()
		defer h.srv.chatGate.mu.Unlock()
		return len(h.srv.chatGate.inflight) == 0
	})
	if len(svc.seen()) != 0 {
		t.Fatal("refusal opened chat socket")
	}
	// A terminal-shaped frame on a chat lane opens neither a socket nor a PTY.
	c, st = dialChatAttachment(t, h, cookie, query())
	if st != 101 {
		t.Fatal(st)
	}
	a := connectAttachmentSocket(t, c, true)
	a.text(t, `{"t":"resize","cols":80,"rows":24}`)
	waitFor(t, 5*time.Second, "malformed chat closed", func() bool { return h.srv.chatRelays.open() == 0 })
	if len(svc.seen()) != 0 || h.srv.termRelays.open() != 0 {
		t.Fatal("cross-kind dispatch")
	}
}

func TestChatAttachmentTrialAccounting(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	setHubSetting(t, h.srv, TrialKey, "on")
	setHubSetting(t, h.srv, TrialMaxMsgsKey, "1")
	const pid = "p:00000000-0000-4000-8000-000000004375"
	cookie := trialSession(t, h, pid)
	if err := h.srv.Store.PlaceTrial(pid, host, time.Now()); err != nil {
		t.Fatal(err)
	}
	setChatHome(t, h, pid, host, login)
	for _, test := range []struct {
		code   int
		answer string
		count  int
	}{
		{503, `{"error":"no sdk"}`, 0},
		{200, "{\"t\":\"error\",\"msg\":\"no credential\"}\n", 0},
		{200, "{\"t\":\"text\",\"d\":\"reply\"}\n{\"t\":\"error\"}\n", 1},
	} {
		svc.mu.Lock()
		svc.turn = func(w http.ResponseWriter) { w.WriteHeader(test.code); io.WriteString(w, test.answer) }
		svc.mu.Unlock()
		body := `{"text":"once"}`
		id := control.NewOpID()
		c, st := dialChatAttachment(t, h, cookie, chatAttachmentQuery("turn", id, body))
		if st != 101 {
			t.Fatal(st)
		}
		a := connectAttachmentSocket(t, c, true)
		st, _ = chatAttachmentResponse(t, a, body)
		if st != test.code {
			t.Fatal(st)
		}
		waitFor(t, 5*time.Second, "trial request released", func() bool { return h.srv.chatRelays.open() == 0 })
		tr, _ := h.srv.Store.Trial(pid)
		if tr.Msgs != test.count {
			t.Fatalf("trial count %d want %d", tr.Msgs, test.count)
		}
		if st := chatAttachmentRefusal(t, h, cookie, chatAttachmentQuery("turn", id, body)); st != 409 {
			t.Fatalf("duplicate grant: %d", st)
		}
	}
	if st := chatAttachmentRefusal(t, h, cookie, chatAttachmentQuery("turn", control.NewOpID(), `{}`)); st != 403 {
		t.Fatalf("line cap bypass: %d", st)
	}
	if len(svc.seen()) != 3 {
		t.Fatalf("turns=%d want 3", len(svc.seen()))
	}
}

func TestChatAttachmentRevocationAndControlIsolation(t *testing.T) {
	for _, scenario := range []string{"maintenance", "forged-accounting"} {
		t.Run(scenario, func(t *testing.T) {
			h, svc, host, login := chatHarness(t)
			setChatHome(t, h, pAlice, host, login)
			id := control.NewOpID()
			c, st := dialChatAttachment(t, h, personCookie(pAlice, "Alice"), chatAttachmentQuery("turn", id, `{}`))
			if st != 101 {
				t.Fatal(st)
			}
			a := connectAttachmentSocket(t, c, scenario == "maintenance")
			if scenario == "maintenance" {
				setHubSetting(t, h.srv, maintenanceKey(host), "drill")
			} else {
				a.text(t, `{"t":"chat_recorded","conn":"`+id+`"}`)
			}
			waitFor(t, 10*time.Second, "revoked or forged control closes chat", func() bool { return h.srv.chatRelays.open() == 0 })
			if len(svc.seen()) != 0 {
				t.Fatal("unauthorized input opened the service")
			}
		})
	}
}
