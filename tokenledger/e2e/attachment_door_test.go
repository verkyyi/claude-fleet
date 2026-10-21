package e2e

import (
	. "github.com/verkyyi/claude-fleet/tokenledger/hub/api"

	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/agent/door"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// A browser terminal through the nearest door (XX79): the real hub admits the
// person and signs, the real home agent and PTY run the terminal, a real door
// (agent/door's pipe on TLS) joins the two halves. The hub's own sockets carry
// signals only — its payload counters stay 0.
type doorRig struct {
	*termRig
	door  *httptest.Server
	mu    sync.Mutex
	lines []door.PipeLine
}

func newDoorRig(t *testing.T) *doorRig {
	t.Helper()
	r := &doorRig{termRig: newTermRig(t, true)}
	tok := r.h.Enroll(t, "door-us")
	pipes, err := door.NewPipes(door.PipeConfig{ID: "us", Key: control.ChatTokenHash(tok)}, func(v any) {
		r.mu.Lock()
		defer r.mu.Unlock()
		r.lines = append(r.lines, v.(door.PipeLine))
	})
	if err != nil {
		t.Fatal(err)
	}
	r.door = httptest.NewTLSServer(pipes.Handler())
	t.Cleanup(r.door.Close)
	agent.SetDoorPipeClientForTest(r.door.Client())
	t.Cleanup(func() { agent.SetDoorPipeClientForTest(nil) })
	r.setDoors(t, "wss://"+strings.TrimPrefix(r.door.URL, "https://")+control.DoorPipePath)
	return r
}

func (r *doorRig) setDoors(t *testing.T, pipeURL string) {
	t.Helper()
	v, _ := json.Marshal([]map[string]string{{"id": "us", "url": pipeURL, "endpoint": "ep_door-us", "label": "美国门"}})
	if err := r.h.Srv.Store.SetFleetSetting(TermDoorsKey, string(v), time.Now()); err != nil {
		t.Fatal(err)
	}
}

// openDoor attaches alice's worker and selects the door; it answers the
// hub's signals, the door socket (nil when the home could not reach the
// door) and the hub's error, if any.
func openDoor(t *testing.T, r *doorRig) (sigs <-chan AttachmentFrameForTest, hub, pipe *websocket.Conn, failure string) {
	t.Helper()
	c, st := dialAttachment(t, r.termRig, "service=term&worker="+r.wid, r.alice)
	if c == nil {
		t.Fatalf("attach status %d", st)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); c.CloseNow() })
	sigs = ReadAttachmentFramesForTest(ctx, c)
	var config control.AttachmentSignal
	if f := receiveAttachment(t, sigs); json.Unmarshal(f.Data, &config) != nil || config.T != "config" {
		t.Fatalf("config %s", f.Data)
	}
	if len(config.Doors) != 1 || config.Doors[0].ID != "us" || config.Doors[0].Label != "美国门" ||
		!strings.HasSuffix(config.Doors[0].Probe, "/healthz") {
		t.Fatalf("doors offered: %+v", config.Doors)
	}
	SendAttachmentSignalForTest(ctx, c, control.AttachmentSignal{T: "relay"})
	SendAttachmentSignalForTest(ctx, c, control.AttachmentSignal{T: "select", Mode: "door", Door: "us"})
	for {
		var sig control.AttachmentSignal
		f := receiveAttachment(t, sigs)
		if json.Unmarshal(f.Data, &sig) != nil {
			t.Fatalf("a payload frame on the hub socket: %q", f.Data)
		}
		switch sig.T {
		case "selecting":
			if sig.Mode != "door" || sig.Door != "us" || sig.Ticket == "" || sig.URL != config.Doors[0].URL {
				t.Fatalf("selecting %+v", sig)
			}
			dctx, dcancel := context.WithTimeout(ctx, 5*time.Second)
			d, _, err := websocket.Dial(dctx, sig.URL+"?t="+url.QueryEscape(sig.Ticket), &websocket.DialOptions{HTTPClient: r.door.Client()})
			dcancel()
			if err != nil {
				continue // a door this browser cannot reach either: wait for the hub's word
			}
			pipe = d
			t.Cleanup(func() { d.CloseNow() })
		case "selected":
			if sig.Mode != "door" || sig.Pair != "door" {
				t.Fatalf("selected %+v", sig)
			}
			rctx, rcancel := context.WithTimeout(ctx, 10*time.Second)
			typ, b, err := pipe.Read(rctx)
			rcancel()
			if err != nil || typ != websocket.MessageText || !strings.Contains(string(b), `"ready"`) {
				t.Fatalf("ready through the door: %v %q %v", typ, b, err)
			}
			return sigs, c, pipe, ""
		case "error":
			return sigs, c, pipe, sig.Error
		}
	}
}

func pipeOutput(t *testing.T, pipe *websocket.Conn, want string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var out strings.Builder
	for !strings.Contains(out.String(), want) {
		_, b, err := pipe.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %q (have %q): %v", want, out.String(), err)
		}
		out.Write(b)
	}
}

func TestAttachmentDoorCarriesTheTerminal(t *testing.T) {
	r := newDoorRig(t)
	_, hub, pipe, failure := openDoor(t, r)
	if failure != "" {
		t.Fatal(failure)
	}
	ctx := context.Background()
	b := []byte("中文\n")
	for _, part := range [][]byte{b[:1], b[1:4], b[4:]} {
		if err := pipe.Write(ctx, websocket.MessageBinary, part); err != nil {
			t.Fatal(err)
		}
	}
	pipeOutput(t, pipe, "got:中文")
	// the browser's echo report lands on the audit row: numbers, never bytes
	SendAttachmentSignalForTest(ctx, hub, control.AttachmentSignal{T: "stats", EchoP50: 18, EchoP95: 31, EchoN: 200})
	waitFor(t, 10*time.Second, "echo recorded", func() bool {
		rows, _ := r.h.Srv.Store.FleetTermSessions(pAlice, 5)
		return len(rows) == 1 && rows[0].EchoP50 == 18 && rows[0].EchoP95 == 31 && rows[0].EchoN == 200
	})
	pipe.CloseNow()
	waitFor(t, 30*time.Second, "door resources cleaned", func() bool { return r.procs() == 0 && r.h.Srv.TermRelaysOpenForTest() == 0 })
	rows, err := r.h.Srv.Store.FleetTermSessions(pAlice, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Mode != "door" || !strings.HasPrefix(rows[0].Outcome, "door us") || rows[0].BytesUp != 0 || rows[0].BytesDown != 0 {
		t.Fatalf("the hub carried payload, or the row is wrong: %+v", rows)
	}
	waitFor(t, 10*time.Second, "the door's record", func() bool {
		r.mu.Lock()
		defer r.mu.Unlock()
		return len(r.lines) == 1 && r.lines[0].Result == "joined" && r.lines[0].Up > 0 && r.lines[0].Down > 0
	})
}

// door-term-down: a door the home cannot reach ends the attempt with
// door_unavailable at once — no terminal started — and the next attempt
// through the hub works as before.
func TestAttachmentDoorDownFallsBackToTheHub(t *testing.T) {
	r := newDoorRig(t)
	dead := httptest.NewTLSServer(http.NotFoundHandler())
	deadURL := "wss://" + strings.TrimPrefix(dead.URL, "https://") + control.DoorPipePath
	dead.Close()
	r.setDoors(t, deadURL)
	start := time.Now()
	_, _, _, failure := openDoor(t, r)
	if failure != "door_unavailable" {
		t.Fatalf("a dead door: %q", failure)
	}
	if took := time.Since(start); took > 8*time.Second {
		t.Fatalf("a dead door took %s to say so", took)
	}
	if n := len(r.starts()); n != 0 {
		t.Fatalf("a terminal started for a door that never joined: %v", r.starts())
	}
	a := connectAttachmentTest(t, r.termRig, false)
	a.send(t, []byte("after-door\n"))
	a.output(t, "got:after-door")
}

// With no door set (or a node that cannot take one) the config names none: the
// page goes on exactly as before.
func TestTermDoorsOffAddsNothing(t *testing.T) {
	r := newTermRig(t, true)
	c, st := dialAttachment(t, r, "service=term&worker="+r.wid, r.alice)
	if c == nil {
		t.Fatalf("attach status %d", st)
	}
	defer c.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "doors") {
		t.Fatalf("a door offered with none set: %s", b)
	}
	// and a select naming a door nobody set ends the attempt
	SendAttachmentSignalForTest(ctx, c, control.AttachmentSignal{T: "relay"})
	SendAttachmentSignalForTest(ctx, c, control.AttachmentSignal{T: "select", Mode: "door", Door: "us"})
	for {
		_, b, err := c.Read(ctx)
		if err != nil {
			break
		}
		if strings.Contains(string(b), `"selecting"`) {
			t.Fatalf("a door nobody set was selected: %s", b)
		}
	}
	if n := len(r.starts()); n != 0 {
		t.Fatalf("a terminal started: %v", r.starts())
	}
}
