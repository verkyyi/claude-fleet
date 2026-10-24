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

func TestPersonSessionListPreferences(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice)
	h.srv.Store.AdoptPrincipal(pAlice, "alice", "Alice", time.Now())
	before, err := h.srv.buildBoard(pAlice, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if before.SessionList != (SessionListPreferences{10, 24}) {
		t.Fatalf("defaults: %+v", before.SessionList)
	}
	for _, prefs := range []map[string]any{{"max_visible": 5, "idle_hours": 0}, {"max_visible": 15, "idle_hours": 72}, {"max_visible": 10, "idle_hours": 12}} {
		code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": map[string]any{"session_list": prefs, "ui_lang": "en"}}, "")
		if code != 200 {
			t.Fatalf("save: %d %s", code, raw)
		}
		board, err := h.srv.buildBoard(pAlice, nil, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if board.SessionList.MaxVisible != prefs["max_visible"] || board.SessionList.IdleHours != prefs["idle_hours"] || board.Digest == before.Digest {
			t.Fatalf("board preferences/etag: %+v", board)
		}
		other, err := h.srv.buildBoard("another-person", nil, time.Now())
		if err != nil || other.SessionList != (SessionListPreferences{10, 24}) {
			t.Fatalf("preferences crossed owners: %+v %v", other, err)
		}
	}
	for _, prefs := range []any{nil, true, []int{10, 24}, map[string]any{"max_visible": 10}, map[string]any{"max_visible": true, "idle_hours": 24}, map[string]any{"max_visible": 10, "idle_hours": -1}, map[string]any{"max_visible": 11, "idle_hours": 24}, map[string]any{"max_visible": 10, "idle_hours": 24, "extra": 1}} {
		code, _, raw, _ := personCall(t, h, http.MethodPut, asSession(pAlice), map[string]any{"bundle": map[string]any{"session_list": prefs}}, "")
		if code != http.StatusUnprocessableEntity || !strings.Contains(raw, "session_list") {
			t.Fatalf("invalid preferences: %d %s", code, raw)
		}
	}
	code, _, raw, _ := teamCall(t, h, http.MethodPut, asOperator, map[string]any{"bundle": map[string]any{"session_list": map[string]int{"max_visible": 10, "idle_hours": 24}}}, "")
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("team preferences: %d %s", code, raw)
	}
}
