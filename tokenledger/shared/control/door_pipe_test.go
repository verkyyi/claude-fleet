package control

import (
	"strings"
	"testing"
	"time"
)

func TestDoorPipeTicket(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	key, other := ChatTokenHash("door-token"), ChatTokenHash("another-door")
	good := DoorPipeTicket{V: 1, Door: "us", Pipe: "abcdefghijklmnopqrstuvwx", Role: DoorPipeBrowser, Iat: now.Unix(), Exp: now.Add(DoorPipeTicketTTL).Unix()}
	if got, err := VerifyDoorPipe(SignDoorPipe(good, key), key, "us", now); err != nil || got != good {
		t.Fatalf("a good ticket: %+v %v", got, err)
	}
	for name, c := range map[string]struct {
		mut  func(*DoorPipeTicket)
		key  string
		door string
		at   time.Time
	}{
		"another door's key": {key: other},
		"for another door":   {door: "sz"},
		"expired":            {at: now.Add(DoorPipeTicketTTL + time.Second)},
		"too long a window":  {mut: func(d *DoorPipeTicket) { d.Exp = now.Add(10 * time.Minute).Unix() }},
		"no role":            {mut: func(d *DoorPipeTicket) { d.Role = "" }},
		"an unknown role":    {mut: func(d *DoorPipeTicket) { d.Role = "admin" }},
		"a short pipe":       {mut: func(d *DoorPipeTicket) { d.Pipe = "short" }},
		"version 2":          {mut: func(d *DoorPipeTicket) { d.V = 2 }},
	} {
		tk := good
		if c.mut != nil {
			c.mut(&tk)
		}
		vk, door, at := key, "us", now
		if c.key != "" {
			vk = c.key
		}
		if c.door != "" {
			door = c.door
		}
		if !c.at.IsZero() {
			at = c.at
		}
		if _, err := VerifyDoorPipe(SignDoorPipe(tk, key), vk, door, at); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// a terminal grant is not a door ticket, nor the reverse
	if _, err := VerifyDoorPipe(SignAttachment(AttachmentGrant{V: 1}, key), key, "us", now); err == nil {
		t.Error("an attachment grant opened a pipe")
	}
}

func TestDoorPipeURL(t *testing.T) {
	for _, u := range []string{"wss://door-us.example.com/v1/door/pipe", "wss://door-us.example.com:8443/v1/door/pipe"} {
		if !ValidDoorPipeURL(u) {
			t.Errorf("%s refused", u)
		}
	}
	for _, u := range []string{"ws://door/v1/door/pipe", "https://door/v1/door/pipe", "wss://door/relay",
		"wss://door/v1/door/pipe?x=1", "wss://u:p@door/v1/door/pipe", "wss:///v1/door/pipe"} {
		if ValidDoorPipeURL(u) {
			t.Errorf("%s accepted", u)
		}
	}
}

func TestAttachmentGrantDoor(t *testing.T) {
	now := time.Now()
	key := ChatTokenHash("node")
	g := AttachmentGrant{V: 1, Person: "alice", Home: "node", Login: "alice", Node: "ep", Service: "term", Target: "personal",
		Conn: "request", Generation: "incarnation", Mode: "door", Door: "wss://door-us.example.com/v1/door/pipe",
		Pipe: strings.Repeat("p", 24), Epoch: 2, Iat: now.Unix(), Exp: now.Add(AttachmentLease).Unix()}
	if _, err := VerifyAttachment(SignAttachment(g, key), key, "alice", "request", "incarnation", now); err != nil {
		t.Fatalf("a door grant: %v", err)
	}
	for name, mut := range map[string]func(*AttachmentGrant){
		"door with no pipe":        func(g *AttachmentGrant) { g.Pipe = "" },
		"door with a plain ws URL": func(g *AttachmentGrant) { g.Door = "ws://door/v1/door/pipe" },
		"a relay naming a door":    func(g *AttachmentGrant) { g.Mode = "relay" },
		"a chat through a door": func(g *AttachmentGrant) {
			g.Service, g.Target, g.Chat = "chat", "turn", ChatAttachmentRequest{ID: "r1"}
		},
	} {
		b := g
		mut(&b)
		if _, err := VerifyAttachment(SignAttachment(b, key), key, "alice", "request", "incarnation", now); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// a select may set the door; a lease may never move it
	sel := g
	sel.Door, sel.Pipe, sel.Mode, sel.Epoch = "", "", "negotiate", 1
	if !SameAttachment(sel, g) {
		t.Error("the selection of a door is not the same attachment")
	}
	moved := g
	moved.Door = "wss://elsewhere.example.com/v1/door/pipe"
	if SameAttachment(g, moved) {
		t.Error("a lease moved the door")
	}
}
