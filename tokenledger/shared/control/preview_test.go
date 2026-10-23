package control

import (
	"testing"
	"time"
)

func TestPreviewGrant(t *testing.T) {
	now := time.Now()
	g := PreviewGrant{V: 1, Person: "alice", Login: "alice", Node: "node", Generation: "generation", Relay: "relay", Preview: "id", Socket: "app.sock", Iat: now.Unix(), Exp: now.Add(30 * time.Second).Unix()}
	signed := SignPreview(g, "key")
	if _, e := VerifyPreview(signed, "key", "alice", "relay", "generation", now); e != nil {
		t.Fatal(e)
	}
	for _, v := range [][4]string{{"bad", "alice", "relay", "generation"}, {"key", "bob", "relay", "generation"}, {"key", "alice", "other", "generation"}, {"key", "alice", "relay", "new-generation"}} {
		if _, e := VerifyPreview(signed, v[0], v[1], v[2], v[3], now); e == nil {
			t.Fatal("forged grant accepted")
		}
	}
	if _, e := VerifyPreview(signed, "key", "alice", "relay", "generation", now.Add(time.Minute)); e == nil {
		t.Fatal("expired grant accepted")
	}
	for _, name := range []string{"/tmp/app.sock", "../app.sock", "app/one.sock", "https://example.com", "127.0.0.1:8000", ".sock", "app.sock/.."} {
		if PreviewSocketName(name) {
			t.Fatal("path accepted", name)
		}
	}
}
