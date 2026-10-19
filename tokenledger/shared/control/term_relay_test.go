package control

import (
	"strings"
	"testing"
	"time"
)

func TestTermGrant(t *testing.T) {
	key := ChatTokenHash("tok-a")
	now := time.Now()
	ok := TermGrant{V: 1, Aud: TermAudience, Person: "p1", Login: "alice", Relay: "r1",
		Target: TermWorkerTarget("0f3c-aa"), Iat: now.Unix(), Exp: now.Add(2 * time.Minute).Unix()}
	if g, err := VerifyTermGrant(SignTermGrant(ok, key), key, "alice", "r1", now); err != nil || g.Target != "worker:0f3c-aa" {
		t.Fatalf("a good grant: %v %+v", err, g)
	}
	mut := func(f func(*TermGrant)) string { g := ok; f(&g); return SignTermGrant(g, key) }
	cases := map[string]struct{ s, key, login, relay, want string }{
		"another login's key":  {SignTermGrant(ok, ChatTokenHash("tok-b")), key, "alice", "r1", "signature"},
		"for another login":    {SignTermGrant(ok, key), key, "bob", "r1", "another login"},
		"for another relay":    {SignTermGrant(ok, key), key, "alice", "r2", "another relay"},
		"expired":              {mut(func(g *TermGrant) { g.Iat, g.Exp = now.Add(-3*time.Minute).Unix(), now.Add(-time.Minute).Unix() }), key, "alice", "r1", "expired"},
		"lives too long":       {mut(func(g *TermGrant) { g.Exp = now.Add(time.Hour).Unix() }), key, "alice", "r1", "out of range"},
		"another audience":     {mut(func(g *TermGrant) { g.Aud = "chat" }), key, "alice", "r1", "another service"},
		"a path for a target":  {mut(func(g *TermGrant) { g.Target = "worker:../../etc" }), key, "alice", "r1", "no such target"},
		"a command for target": {mut(func(g *TermGrant) { g.Target = "/bin/sh" }), key, "alice", "r1", "no such target"},
		"no person":            {mut(func(g *TermGrant) { g.Person = "" }), key, "alice", "r1", "malformed"},
		"no key":               {SignTermGrant(ok, key), "", "alice", "r1", "no key"},
		"garbage":              {"ftg1.x", key, "alice", "r1", "malformed"},
		"a chat statement":     {SignChatPerson(ChatPerson{V: 1, Person: "p1", Login: "alice", Relay: "r1", Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}, key), key, "alice", "r1", "malformed"},
	}
	for name, c := range cases {
		if _, err := VerifyTermGrant(c.s, c.key, c.login, c.relay, now); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", name, err, c.want)
		}
	}
	// …and a terminal grant never opens a conversation.
	if _, err := VerifyChatPerson(SignTermGrant(ok, key), key, "alice", "r1", now); err == nil {
		t.Fatal("a terminal grant verified as a chat statement")
	}
}

func TestTermControlFrames(t *testing.T) {
	if c, r, err := ParseTermResize([]byte(`{"t":"resize","cols":120,"rows":40}`)); err != nil || c != 120 || r != 40 {
		t.Fatalf("resize: %d %d %v", c, r, err)
	}
	for _, bad := range []string{`{"t":"resize","cols":0,"rows":40}`, `{"t":"resize","cols":5000,"rows":40}`,
		`{"t":"exec","cmd":"sh"}`, `not json`, `{"t":"resize","cols":80,"rows":24,"pad":"` + strings.Repeat("x", 2000) + `"}`} {
		if _, _, err := ParseTermResize([]byte(bad)); err == nil {
			t.Errorf("resize %q accepted", bad[:min(len(bad), 40)])
		}
	}
	if c, err := ParseTermAgentControl([]byte(`{"t":"exit","code":3,"msg":"x"}`)); err != nil || c.Code != 3 || c.Msg != "" {
		t.Fatalf("exit: %+v %v", c, err)
	}
	if _, err := ParseTermAgentControl([]byte(`{"t":"hello"}`)); err == nil {
		t.Fatal("an agent's hello accepted")
	}
	for _, ok := range []string{"personal", "worker:3f2a-1b"} {
		if !ValidTermTarget(ok) {
			t.Errorf("%s refused", ok)
		}
	}
	for _, bad := range []string{"", "worker:", "worker:a b", "worker:a;b", "shell", "worker:/tmp/x"} {
		if ValidTermTarget(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}
