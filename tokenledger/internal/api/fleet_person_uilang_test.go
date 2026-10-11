package api

import (
	"net/http"
	"strings"
	"testing"
	"time"
)

// A person's interface language (claude-fleet#3329, EPIC #3178 D7): the
// personal layer takes `ui_lang` "zh" | "en", nothing else; the team never does.
func TestPersonUILangValidation(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())

	v := 0
	for _, lang := range []string{"en", "zh"} {
		code, out, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": map[string]any{"ui_lang": lang}}, "")
		v++
		if code != 200 || out.Version != v || !strings.Contains(string(out.Bundle), `"ui_lang":"`+lang+`"`) {
			t.Fatalf("ui_lang %q: HTTP %d %s", lang, code, raw)
		}
	}
	for name, val := range map[string]any{"another language": "fr", "a locale": "en_US.UTF-8", "empty": "", "not text": 1, "a list": []any{"zh"}} {
		code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": map[string]any{"ui_lang": val}}, "")
		if code != http.StatusUnprocessableEntity || !strings.Contains(raw, "ui_lang") {
			t.Errorf("%s: HTTP %d %s, want 422 naming ui_lang", name, code, raw)
		}
	}
	if code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": map[string]any{"ui_lang": "en"}}, ""); code != http.StatusUnprocessableEntity {
		t.Fatalf("team PUT with ui_lang: HTTP %d %s, want 422", code, raw)
	}
}
