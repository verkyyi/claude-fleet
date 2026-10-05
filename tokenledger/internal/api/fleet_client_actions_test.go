package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// Open it on the device in your hands (claude-fleet#1717, C7): a node sends an
// action to its owner's current client; only that lease's client receives
// it, signed under the key only it was told; its answer reaches the sender;
// after a takeover the old lease gets nothing and the new one gets the next.
func TestClientActionsReachTheOwnersLeaseSigned(t *testing.T) {
	h, _, n := peerHarness(t)
	post := func(path, tok string, body any, out any) int {
		t.Helper()
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		if out != nil {
			_ = json.NewDecoder(res.Body).Decode(out)
		}
		return res.StatusCode
	}
	send := func(tok string, a ClientActionSend) (int, ClientActionSendResponse) {
		var out ClientActionSendResponse
		return post("/v1/node/client/actions", tok, a, &out), out
	}
	poll := func(lease string, wait int) (int, ClientActionPollResponse) {
		var out ClientActionPollResponse
		return post(control.ClientPath+"/actions", viewerToken, ClientActionPoll{Action: "poll", Lease: lease, Wait: wait}, &out), out
	}

	// Nobody connected: none — the sender opens it its own way.
	if code, out := send(n["verk4"].token, ClientActionSend{Kind: "open_url", URL: "https://example.com/"}); code != 200 || out.State != "none" {
		t.Fatalf("nobody connected: HTTP %d %+v", code, out)
	}
	// The operator's client takes the lease (viewer door = the operator); the
	// acquire hands it the action key, a plain read never does.
	var acq ClientLeaseResponse
	post(control.ClientPath, viewerToken, ClientLeaseRequest{Action: "acquire", Device: "MacBook", Caps: []string{"open_url"}}, &acq)
	if acq.State != "active" || acq.ActionKey == "" || len(acq.ActionKey) != 64 {
		t.Fatalf("acquire = %+v, want an active lease with an action key", acq)
	}
	var got ClientLeaseResponse
	post(control.ClientPath, viewerToken, ClientLeaseRequest{Action: "get"}, &got)
	if got.ActionKey != "" {
		t.Fatalf("a get leaked the action key")
	}
	var ren ClientLeaseResponse
	post(control.ClientPath, viewerToken, ClientLeaseRequest{Action: "renew", Lease: acq.Lease.ID}, &ren)
	if ren.ActionKey != acq.ActionKey {
		t.Fatalf("renewal key %q, want the same %q", ren.ActionKey, acq.ActionKey)
	}

	// A loopback page on m4: queued for the lease, the machine is the hub's word.
	code, sent := send(n["verk4"].token, ClientActionSend{Kind: "open_url", RPort: 8765, Path: "d/x/",
		Links: ClientActionLinks{Tailnet: "https://m4.tail.ts.net/d/x/", Hub: "javascript:alert(1)"}})
	if code != 200 || sent.State != "queued" || sent.ID == "" || sent.Client == nil || sent.Client.Device != "MacBook" {
		t.Fatalf("send: HTTP %d %+v", code, sent)
	}
	code, p := poll(acq.Lease.ID, 0)
	if code != 200 || p.State != "active" || len(p.Actions) != 1 {
		t.Fatalf("poll: HTTP %d %+v", code, p)
	}
	sa := p.Actions[0]
	if sa.Sig != signClientAction(acq.ActionKey, []byte(sa.Payload)) {
		t.Fatalf("signature does not check under the lease's key")
	}
	var a ClientAction
	if err := json.Unmarshal([]byte(sa.Payload), &a); err != nil {
		t.Fatal(err)
	}
	if a.ID != sent.ID || a.Lease != acq.Lease.ID || a.Kind != "open_url" || a.RPort != 8765 || a.Path != "/d/x/" ||
		a.Scheme != "http" || a.Machine != "m4" || a.Host != "macmini-m4" || a.Links.Tailnet == "" || a.Links.Hub != "" {
		t.Fatalf("payload = %+v", a)
	}
	if _, p := poll(acq.Lease.ID, 0); len(p.Actions) != 0 {
		t.Fatalf("delivered twice: %+v", p)
	}

	// A long poll wakes on the send; the sender waiting gets the client's answer.
	type sres struct{ out ClientActionSendResponse }
	ch := make(chan sres, 1)
	go func() {
		time.Sleep(100 * time.Millisecond)
		_, o := send(n["verk4"].token, ClientActionSend{Kind: "notify", Title: "built", Wait: 5})
		ch <- sres{o}
	}()
	_, p = poll(acq.Lease.ID, 5)
	if len(p.Actions) != 1 {
		t.Fatalf("long poll: %+v", p)
	}
	_ = json.Unmarshal([]byte(p.Actions[0].Payload), &a)
	if c := post(control.ClientPath+"/actions", viewerToken, ClientActionPoll{Action: "done", Lease: acq.Lease.ID, ID: a.ID, OK: true, Result: "opened"}, nil); c != 200 {
		t.Fatalf("done: HTTP %d", c)
	}
	if r := <-ch; r.out.State != "done" || r.out.Result != "opened" {
		t.Fatalf("waiting sender: %+v", r.out)
	}

	// Bad bodies are refused; bob's node reaches nobody (it is not his lease).
	for _, bad := range []ClientActionSend{{Kind: "exec"}, {Kind: "open_url", URL: "file:///etc/passwd"},
		{Kind: "show_file", File: "relative.png"}, {Kind: "show_file", File: "/a/../etc"}, {Kind: "notify"}, {Kind: "open_url", RPort: 70000}} {
		if code, _ := send(n["verk4"].token, bad); code != 400 {
			t.Fatalf("%+v: HTTP %d, want 400", bad, code)
		}
	}
	if _, out := send(n["bob4"].token, ClientActionSend{Kind: "notify", Body: "x"}); out.State != "none" {
		t.Fatalf("bob's node reached %+v", out)
	}
	if code, _ := send("", ClientActionSend{Kind: "notify", Body: "x"}); code != 401 {
		t.Fatalf("no token: HTTP %d", code)
	}

	// Takeover: what was queued for the old lease goes with it, the old lease
	// polls taken_over, the next action is signed for the new one.
	send(n["verk4"].token, ClientActionSend{Kind: "notify", Body: "for the mac"})
	var ph ClientLeaseResponse
	post(control.ClientPath, viewerToken, ClientLeaseRequest{Action: "acquire", Device: "iPhone", Caps: []string{"link"}}, &ph)
	if ph.ActionKey == "" || ph.ActionKey == acq.ActionKey {
		t.Fatalf("the new lease must get its own key")
	}
	if _, p := poll(acq.Lease.ID, 0); p.State != "taken_over" || len(p.Actions) != 0 {
		t.Fatalf("old lease after takeover: %+v", p)
	}
	if _, p := poll(ph.Lease.ID, 0); len(p.Actions) != 0 {
		t.Fatalf("the mac's action followed the takeover: %+v", p)
	}
	send(n["verk4"].token, ClientActionSend{Kind: "show_file", File: "/tmp/shot.png", Size: 10})
	_, p = poll(ph.Lease.ID, 0)
	if len(p.Actions) != 1 || p.Actions[0].Sig != signClientAction(ph.ActionKey, []byte(p.Actions[0].Payload)) {
		t.Fatalf("new lease: %+v", p)
	}
	_ = json.Unmarshal([]byte(p.Actions[0].Payload), &a)
	if a.Name != "shot.png" || a.Lease != ph.Lease.ID {
		t.Fatalf("show_file payload %+v", a)
	}
	// Answering another lease's action is refused.
	if c := post(control.ClientPath+"/actions", viewerToken, ClientActionPoll{Action: "done", Lease: acq.Lease.ID, ID: a.ID, OK: true}, nil); c != 404 {
		t.Fatalf("done for another lease: HTTP %d", c)
	}
}
