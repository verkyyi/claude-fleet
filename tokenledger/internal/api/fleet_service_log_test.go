package api

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// svcLogRig is m4 as one machine link carrying alpha (alice's) and beta (not
// hers), each lane saying CapServiceLog, an entry each in the register; bob
// is an admin person.
func svcLogRig(t *testing.T) (*harness, *machNode) {
	t.Helper()
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pCarol)
	// bob is an admin the way a deploy names one: GitHub.Admins + the pin.
	id, _ := githubIDOf(pBob)
	h.srv.GitHub.Admins = []string{"bob"}
	if _, err := h.srv.Store.PinLogin("bob", id, time.Now()); err != nil {
		t.Fatal(err)
	}
	h.enroll(t, "mach")
	logins := []string{"alpha", "beta"}
	for _, l := range logins {
		h.enroll(t, l)
		identify(t, h, l, "m4", l)
	}
	n := dialMachine(t, h, h.tokens["mach"])
	var svcs []control.ServiceStatus
	for _, l := range logins {
		if r := n.login(l, h.tokens[l], false, control.CapRead, control.CapServiceLog); r.Type != control.TypeWelcome {
			t.Fatalf("%s's hello answered %+v", l, r)
		}
		n.beat(l, control.Heartbeat{Hostname: "m4", OSUser: l, NCPU: 10, ObservedAt: time.Now()})
		svcs = append(svcs, control.ServiceStatus{Name: l + "-svc", Kind: "service", Login: l, State: "running"})
	}
	n.beat("", control.Heartbeat{Hostname: "m4", OSUser: "root", NCPU: 10, ObservedAt: time.Now(), Services: svcs})
	if code := operatorPost(t, h, FleetAccountRequest{Action: "adopt", PrincipalID: pAlice, Hostname: "m4", Login: "alpha"}); code != 200 {
		t.Fatalf("adopt alice: HTTP %d", code)
	}
	waitFor(t, 3*time.Second, "m4's register", func() bool {
		for _, m := range roster(t, h).Machines {
			if m.Hostname == "m4" && len(m.Services) == 2 {
				return true
			}
		}
		return false
	})
	return h, n
}

// svcLogReq is a GET as who: "" the operator's viewer token, "admin" bob's
// session, else that person's.
func svcLogReq(t *testing.T, h *harness, ctx context.Context, path, who string) *http.Response {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.http.URL+path, nil)
	switch who {
	case "":
		req.Header.Set("Authorization", "Bearer "+viewerToken)
	case "admin":
		req.AddCookie(personCookie(pBob, ""))
	default:
		req.AddCookie(personCookie(who, ""))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// sseRead hands every event of resp to the channel until the body ends.
func sseRead(resp *http.Response) <-chan sseEvent {
	ch := make(chan sseEvent, 64)
	go func() {
		defer close(ch)
		sc := bufio.NewScanner(resp.Body)
		var ev sseEvent
		for sc.Scan() {
			line := sc.Text()
			switch {
			case strings.HasPrefix(line, "event: "):
				ev.name = line[len("event: "):]
			case strings.HasPrefix(line, "data: "):
				ev.data = line[len("data: "):]
			case line == "":
				if ev.name != "" {
					ch <- ev
				}
				ev = sseEvent{}
			}
		}
	}()
	return ch
}

// nextLaneMsg is the next message of type typ on login's lane.
func nextLaneMsg(t *testing.T, n *machNode, login, typ string, d time.Duration) (control.Message, bool) {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case m := <-n.inbox(login):
			if m.Type == typ {
				return m, true
			}
		case <-deadline:
			return control.Message{}, false
		}
	}
}

func svcLogPath(login, name string) string {
	return "/v1/nodes/m4/" + ServiceLogSegment + "/" + login + "/" + name + "/log"
}

// claude-fleet#2797's 完成判据 + BREAK-IT service-log-cross-login: a user who
// spells another login into the URL — or one that does not exist — is 403
// before any node is asked; the operator and an admin person get the stream.
func TestServiceLogCrossLoginIs403(t *testing.T) {
	h, n := svcLogRig(t)
	for _, path := range []string{svcLogPath("beta", "beta-svc"), svcLogPath("beta", "nosuch"),
		svcLogPath("gamma", "x"), "/v1/nodes/m5/services/alpha/alpha-svc/log"} {
		resp := svcLogReq(t, h, context.Background(), path, pAlice)
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("alice %s: HTTP %d %s, want 403", path, resp.StatusCode, b)
		}
		if strings.Contains(string(b), "beta-svc") {
			t.Fatalf("the 403 names the entry: %s", b)
		}
	}
	// carol has no login at all.
	resp := svcLogReq(t, h, context.Background(), svcLogPath("alpha", "alpha-svc"), pCarol)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("carol: HTTP %d, want 403", resp.StatusCode)
	}
	if _, asked := nextLaneMsg(t, n, "beta", control.TypeServiceLog, 300*time.Millisecond); asked {
		t.Fatal("a refused reader still made the node read beta's log")
	}

	for _, who := range []string{"", "admin"} {
		ctx, cancel := context.WithCancel(context.Background())
		resp := svcLogReq(t, h, ctx, svcLogPath("beta", "beta-svc"), who)
		if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
			t.Fatalf("%q beta-svc: HTTP %d %s", who, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
		cancel()
		resp.Body.Close()
	}
	// An admin's unknown entry is 404, not a stream.
	resp = svcLogReq(t, h, context.Background(), svcLogPath("beta", "nosuch"), "admin")
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("admin nosuch: HTTP %d, want 404", resp.StatusCode)
	}
	// HEAD is the page's preflight: the same answers, no node asked.
	for path, want := range map[string]int{svcLogPath("beta", "beta-svc"): 403, svcLogPath("alpha", "alpha-svc"): 200, svcLogPath("alpha", "nosuch"): 404} {
		req, _ := http.NewRequest(http.MethodHead, h.http.URL+path, nil)
		req.AddCookie(personCookie(pAlice, ""))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("HEAD %s: HTTP %d, want %d", path, resp.StatusCode, want)
		}
	}
	if _, asked := nextLaneMsg(t, n, "alpha", control.TypeServiceLog, 300*time.Millisecond); asked {
		t.Fatal("a HEAD asked the node")
	}
	// Alice reads her own.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resp = svcLogReq(t, h, ctx, svcLogPath("alpha", "alpha-svc"), pAlice)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("alice alpha-svc: HTTP %d", resp.StatusCode)
	}
}

// Two people watching one service cost the node one follow; their lines are
// masked on the hub; the last one gone, the node is told to stop.
func TestServiceLogOneFollowForManyViewers(t *testing.T) {
	defer func(l time.Duration) { svcLogLinger = l }(svcLogLinger)
	svcLogLinger = 200 * time.Millisecond
	h, n := svcLogRig(t)

	ctx1, cancel1 := context.WithCancel(context.Background())
	r1 := svcLogReq(t, h, ctx1, svcLogPath("alpha", "alpha-svc"), pAlice)
	defer r1.Body.Close()
	if r1.StatusCode != 200 {
		t.Fatalf("alice: HTTP %d", r1.StatusCode)
	}
	e1 := sseRead(r1)
	open, ok := nextLaneMsg(t, n, "alpha", control.TypeServiceLog, 5*time.Second)
	if !ok {
		t.Fatal("the node was never asked")
	}
	var req control.ServiceLog
	_ = json.Unmarshal(open.Payload, &req)
	if req.Login != "alpha" || req.Name != "alpha-svc" || !req.Follow || req.Tail != control.ServiceLogTail || req.Renew {
		t.Fatalf("follow asked = %+v", req)
	}
	lines, _ := control.New(control.TypeServiceLogLines, control.ServiceLogLines{From: 0, Start: true, At: time.Now().UTC(),
		Lines: []control.ServiceLogLine{{Text: "boot"}, {Text: "key=sk-ant-api03-abcdefghijklmnop"}, {Text: "gateway timeout"}}})
	lines.OpID = open.OpID
	n.send("alpha", lines)
	ev := nextEvent(t, e1, "lines", 5*time.Second)
	if strings.Contains(ev.data, "sk-ant-") || !strings.Contains(ev.data, "gateway timeout") || !strings.Contains(ev.data, svcLogMask) {
		t.Fatalf("first viewer's lines = %s", ev.data)
	}

	ctx2, cancel2 := context.WithCancel(context.Background())
	r2 := svcLogReq(t, h, ctx2, svcLogPath("alpha", "alpha-svc"), "")
	defer r2.Body.Close()
	e2 := sseRead(r2)
	// The second viewer starts from the lines already there, unasked.
	if ev := nextEvent(t, e2, "lines", 5*time.Second); !strings.Contains(ev.data, "gateway timeout") || strings.Contains(ev.data, "sk-ant-") {
		t.Fatalf("second viewer's first lines = %s", ev.data)
	}
	if m, again := nextLaneMsg(t, n, "alpha", control.TypeServiceLog, 400*time.Millisecond); again {
		t.Fatalf("a second viewer asked the node again: %s", m.Payload)
	}
	more, _ := control.New(control.TypeServiceLogLines, control.ServiceLogLines{From: 40, At: time.Now().UTC(),
		Lines: []control.ServiceLogLine{{Text: "Authorization: Bearer abcdefghijklmnopqrstuvwx"}}})
	more.OpID = open.OpID
	n.send("alpha", more)
	for _, ch := range []<-chan sseEvent{e1, e2} {
		if ev := nextEvent(t, ch, "lines", 5*time.Second); strings.Contains(ev.data, "abcdefghijklmnop") {
			t.Fatalf("a bearer token reached a viewer: %s", ev.data)
		}
	}
	if got := h.srv.svcLogs.count(); got != 1 {
		t.Fatalf("follows open = %d, want 1", got)
	}

	cancel1()
	cancel2()
	stop, ok := nextLaneMsg(t, n, "alpha", control.TypeServiceLogStop, 5*time.Second)
	if !ok || stop.OpID != open.OpID {
		t.Fatalf("no stop for the follow after the last viewer left: %+v", stop)
	}
	waitFor(t, 2*time.Second, "the follow forgotten", func() bool { return h.srv.svcLogs.count() == 0 })
}

// A page scrolled up is one request to the node, masked too; the node's
// refusal is the reader's 404.
func TestServiceLogPageBefore(t *testing.T) {
	h, n := svcLogRig(t)
	go func() {
		for i := 0; i < 2; i++ {
			m, ok := nextLaneMsg(t, n, "alpha", control.TypeServiceLog, 5*time.Second)
			if !ok {
				return
			}
			var req control.ServiceLog
			_ = json.Unmarshal(m.Payload, &req)
			var out control.Message
			if req.Before != nil && *req.Before == 4096 && !req.Follow {
				out, _ = control.New(control.TypeServiceLogLines, control.ServiceLogLines{From: 1024, Done: true, At: time.Now().UTC(),
					Lines: []control.ServiceLogLine{{Text: "older"}, {Text: "push ghp_abcdefghijklmnopqrstuvwxyz0123"}}})
			} else {
				out = control.Message{Type: control.TypeError, Error: &control.Error{Code: "NOT_FOUND", Message: "gone"}}
			}
			out.OpID = m.OpID
			n.send("alpha", out)
		}
	}()
	resp := svcLogReq(t, h, context.Background(), svcLogPath("alpha", "alpha-svc")+"?before=4096", pAlice)
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"from":1024`) || !strings.Contains(string(b), "older") || strings.Contains(string(b), "ghp_") {
		t.Fatalf("page: HTTP %d %s", resp.StatusCode, b)
	}
	resp = svcLogReq(t, h, context.Background(), svcLogPath("alpha", "alpha-svc")+"?before=1", pAlice)
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("refused page: HTTP %d, want 404", resp.StatusCode)
	}
	resp = svcLogReq(t, h, context.Background(), svcLogPath("beta", "beta-svc")+"?before=1", pAlice)
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("alice's page of beta: HTTP %d, want 403", resp.StatusCode)
	}
}

// The link going takes every follow with it: the viewer hears `end`.
func TestServiceLogEndsWithTheLink(t *testing.T) {
	h, n := svcLogRig(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resp := svcLogReq(t, h, ctx, svcLogPath("alpha", "alpha-svc"), pAlice)
	defer resp.Body.Close()
	ev := sseRead(resp)
	if _, ok := nextLaneMsg(t, n, "alpha", control.TypeServiceLog, 5*time.Second); !ok {
		t.Fatal("the node was never asked")
	}
	n.c.CloseNow()
	if e := nextEvent(t, ev, "end", 5*time.Second); !strings.Contains(e.data, "link closed") {
		t.Fatalf("end = %s", e.data)
	}
}

func TestRedactLogLine(t *testing.T) {
	for in, gone := range map[string]string{
		"using key sk-ant-api03-AbCdEfGh_1234567890":            "sk-ant-api03",
		"git push https://ghp_abcdefghijklmnopqrstuvwxyz0123@x": "ghp_abcdefghij",
		"curl -H 'Authorization: Bearer abc.def-ghi_jkl.mnopq'": "abc.def-ghi",
		"GITHUB_TOKEN=s3cr3t-value-here":                        "s3cr3t",
		`{"password": "hunter22"}`:                              "hunter22",
	} {
		out := redactLogLine(in)
		if strings.Contains(out, gone) || !strings.Contains(out, svcLogMask) {
			t.Errorf("redactLogLine(%q) = %q", in, out)
		}
	}
	for _, keep := range []string{"gateway timeout after 30s", "GET /v1/nodes 200 12ms", "", "output_tokens: 5000", "token=abc"} {
		if out := redactLogLine(keep); out != keep {
			t.Errorf("redactLogLine(%q) = %q, want unchanged", keep, out)
		}
	}
}

func TestParseServiceLogPath(t *testing.T) {
	if h, l, n, ok := parseServiceLogPath("m4/services/alpha/sms-watch/log"); !ok || h != "m4" || l != "alpha" || n != "sms-watch" {
		t.Fatalf("parse = %q %q %q %v", h, l, n, ok)
	}
	for _, p := range []string{"m4", "m4/extra", "m4/services/alpha/log", "m4/services/alpha/x/y", "m4/svc/alpha/x/log", "/services/a/b/log"} {
		if _, _, _, ok := parseServiceLogPath(p); ok {
			t.Errorf("%q parsed as a log path", p)
		}
	}
}
