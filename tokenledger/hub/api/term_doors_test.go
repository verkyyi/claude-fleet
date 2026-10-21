package api

import (
	"strings"
	"testing"
)

func TestTermDoorsSetting(t *testing.T) {
	good := `[{"id":"us","url":"wss://door-us.example.com/v1/door/pipe","endpoint":"ep_door","label":"美国门"}]`
	if v, why := termDoorsCheck(nil, good); why != "" || v != good {
		t.Fatalf("a good list: %q %q", v, why)
	}
	for _, v := range []string{"", "none"} {
		if _, why := termDoorsCheck(nil, v); why != "" {
			t.Errorf("%q: %s", v, why)
		}
	}
	for name, v := range map[string]string{
		"not JSON":       `us=wss://x`,
		"a plain ws":     `[{"id":"us","url":"ws://door/v1/door/pipe","endpoint":"e"}]`,
		"another path":   `[{"id":"us","url":"wss://door/relay","endpoint":"e"}]`,
		"no endpoint":    `[{"id":"us","url":"wss://door/v1/door/pipe"}]`,
		"a bad id":       `[{"id":"US door","url":"wss://door/v1/door/pipe","endpoint":"e"}]`,
		"the same twice": `[{"id":"us","url":"wss://a/v1/door/pipe","endpoint":"e"},{"id":"us","url":"wss://b/v1/door/pipe","endpoint":"e"}]`,
	} {
		if _, why := termDoorsCheck(nil, v); why == "" {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestConsoleCSPDoors(t *testing.T) {
	if withDoorOrigins(consoleCSP, nil) != consoleCSP {
		t.Fatal("no door changed the console's policy")
	}
	ds, _ := parseTermDoors(`[{"id":"us","url":"wss://door-us.example.com/v1/door/pipe","endpoint":"e"}]`)
	got := withDoorOrigins(consoleCSP, ds)
	if !strings.Contains(got, "connect-src 'self' wss://door-us.example.com https://door-us.example.com;") {
		t.Fatalf("the door's origins: %s", got)
	}
	if strings.Replace(got, " wss://door-us.example.com https://door-us.example.com", "", 1) != consoleCSP {
		t.Fatalf("more than connect-src moved: %s", got)
	}
	if b := browserDoors(ds); len(b) != 1 || b[0].Probe != "https://door-us.example.com/healthz" {
		t.Fatalf("what the browser is told: %+v", b)
	}
}
