package api

import (
	"strings"
	"testing"
)

// The console frames nothing unless the deploy names an origin (task T773 ④),
// and a value that is not plain https origins is refused whole.
func TestChatFrameOrigins(t *testing.T) {
	if (&Server{}).consolePolicy() != consoleCSP || strings.Contains(consoleCSP, "frame-src") {
		t.Fatal("no origins: the policy must stay the console's own")
	}
	got, err := ParseChatFrameOrigins(" https://pages.example.com, https://*.example.com:8443 ,")
	if err != nil || len(got) != 2 {
		t.Fatalf("parse: %v %v", got, err)
	}
	p := (&Server{ChatFrameOrigins: got}).consolePolicy()
	if !strings.HasSuffix(p, "; frame-src https://pages.example.com https://*.example.com:8443") || !strings.Contains(p, "frame-ancestors 'none'") {
		t.Errorf("policy %q", p)
	}
	for _, bad := range []string{"http://pages.example.com", "https://x.com; script-src *", "*", "https://x.com/path", "https://localhost", "javascript:alert(1)"} {
		if _, err := ParseChatFrameOrigins(bad); err == nil {
			t.Errorf("%q was taken", bad)
		}
	}
}
