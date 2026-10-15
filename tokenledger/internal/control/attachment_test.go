package control

import (
	"strings"
	"testing"
	"time"
)

func TestAttachmentGrant(t *testing.T) {
	now := time.Now()
	g := AttachmentGrant{V: 1, Person: "alice", Home: "node", Login: "alice", Node: "ep", Service: "term", Target: "personal", Conn: "request", Generation: "incarnation", Fingerprint: strings.TrimSuffix(strings.Repeat("AB:", 32), ":"), Mode: "negotiate", Epoch: 1, Iat: now.Unix(), Exp: now.Add(AttachmentLease).Unix()}
	check := func(g AttachmentGrant, key, login, conn, gen string, at time.Time) error {
		_, err := VerifyAttachment(SignAttachment(g, "test-key"), key, login, conn, gen, at)
		return err
	}
	if err := check(g, "test-key", "alice", "request", "incarnation", now); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"key", "login", "conn", "generation", "expiry", "service", "target", "fingerprint", "ttl", "epoch"} {
		t.Run(field, func(t *testing.T) {
			b := g
			key, login, conn, gen, at := "test-key", "alice", "request", "incarnation", now
			switch field {
			case "key":
				key = "other"
			case "login":
				login = "bob"
			case "conn":
				conn = "other"
			case "generation":
				gen = "replacement-pod"
			case "expiry":
				at = time.Unix(g.Exp, 0)
			case "service":
				b.Service = "chat"
			case "target":
				b.Target = "/bin/sh"
			case "fingerprint":
				b.Fingerprint = "sha1"
			case "ttl":
				b.Exp++
			case "epoch":
				b.Epoch = 0
			}
			if check(b, key, login, conn, gen, at) == nil {
				t.Fatal("accepted invalid authority")
			}
		})
	}
	if _, err := VerifyAttachment(SignTermGrant(TermGrant{}, "test-key"), "test-key", "alice", "request", "incarnation", now); err == nil {
		t.Fatal("cross-service prefix accepted")
	}
	b := g
	b.Mode = "relay"
	b.Epoch++
	b.Exp++
	if !SameAttachment(g, b) {
		t.Fatal("selection changed identity")
	}
	b.Target = "worker:other"
	if SameAttachment(g, b) {
		t.Fatal("selection changed target")
	}
}
