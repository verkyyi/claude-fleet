package control

import (
	"strings"
	"testing"
	"time"
)

func TestChatPerson(t *testing.T) {
	now := time.Now()
	key := ChatTokenHash("tok")
	c := ChatPerson{V: 1, Person: "alice", Login: "alice", Relay: "r1", Iat: now.Unix(), Exp: now.Add(time.Minute).Unix()}
	s := SignChatPerson(c, key)
	if got, err := VerifyChatPerson(s, key, "alice", "r1", now); err != nil || got.Person != "alice" {
		t.Fatalf("good statement: %v, %v", got, err)
	}
	for name, tc := range map[string]struct {
		s, key, login, relay string
		at                   time.Time
	}{
		"another key":    {s, ChatTokenHash("other"), "alice", "r1", now},
		"no key":         {s, "", "alice", "r1", now},
		"another login":  {s, key, "bob", "r1", now},
		"another relay":  {s, key, "alice", "r2", now},
		"expired":        {s, key, "alice", "r1", now.Add(2 * time.Minute)},
		"tampered":       {strings.Replace(s, ".", ".x", 1), key, "alice", "r1", now},
		"another prefix": {"fwa1" + strings.TrimPrefix(s, "fpp1"), key, "alice", "r1", now},
	} {
		if _, err := VerifyChatPerson(tc.s, tc.key, tc.login, tc.relay, tc.at); err == nil {
			t.Errorf("%s: verified", name)
		}
	}
}
