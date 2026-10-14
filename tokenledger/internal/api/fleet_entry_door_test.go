package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// entryDoor is principal's door, as GET EntryKeysPath answers it.
func entryDoor(t *testing.T, h *harness, principal string) EntryDoor {
	t.Helper()
	code, raw := entryCall(t, h, http.MethodGet, control.EntryKeysPath, asSession(principal), nil)
	var v EntryView
	if err := json.Unmarshal([]byte(raw), &v); code != http.StatusOK || err != nil || v.Door == nil {
		t.Fatalf("GET keys: HTTP %d %v %s", code, err, raw)
	}
	return *v.Door
}

func TestEntryWhen(t *testing.T) {
	now := time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)
	for d, want := range map[time.Duration]string{10 * time.Second: "刚才", 5 * time.Minute: "5 分钟前", 3 * time.Hour: "3 小时前", 50 * time.Hour: "2 天前", 30 * 24 * time.Hour: "2026-09-10"} {
		if got := entryWhen(now.Add(-d), now); got != want {
			t.Fatalf("entryWhen(-%v) = %q, want %q", d, got, want)
		}
	}
}

// 设备's phone tab (claude-fleet#3930) reads the door through GET
// EntryKeysPath: the address, the port, the home's login, the door's state
// and the three as a QR code; each home choice carries its name.
func TestEntryViewCarriesTheDoor(t *testing.T) {
	h := entryHarness(t)
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.example.com", time.Now())
	code, raw := entryCall(t, h, http.MethodGet, control.EntryKeysPath, asSession(pAlice), nil)
	var v EntryView
	if err := json.Unmarshal([]byte(raw), &v); code != 200 || err != nil || v.Door == nil {
		t.Fatalf("GET keys: HTTP %d %v %s", code, err, raw)
	}
	d := v.Door
	if d.Address != "user1001.cf.example.com" || d.Port != entryPort || d.Login != "alice" || d.State != "nokey" || d.HomeName == "" {
		t.Fatalf("door %+v; want the address, %d, alice, nokey", d, entryPort)
	}
	if len(d.QR) < 21 || len(d.QR[0]) != len(d.QR) || strings.Trim(strings.Join(d.QR, ""), "#.") != "" {
		t.Fatalf("door QR %v; want a square of # and .", d.QR)
	}
	if got := entrySSHURL(d.Login, d.Address, d.Port); got != "ssh://alice@user1001.cf.example.com:22022" {
		t.Fatalf("ssh URL %q", got)
	}
	for _, c := range v.HomeChoices {
		if c.Name == "" {
			t.Errorf("home choice %+v has no name", c)
		}
	}
	// a key: the door opens (or is opening), never nokey
	line := entryKeyLine(t, "termius")
	if code, raw := entryCall(t, h, http.MethodPost, control.EntryKeysPath, asSession(pAlice), map[string]any{"public_key": line}); code != http.StatusCreated {
		t.Fatalf("add a key: HTTP %d %s", code, raw)
	}
	if d := entryDoor(t, h, pAlice); d.State == "nokey" {
		t.Fatalf("after a key: %+v", d)
	}
}

// The sign-in sends a browser back only where the cookie may name: an old
// page's address (it moves on from there) or the trial, never elsewhere.
func TestEntryReturn(t *testing.T) {
	for v, want := range map[string]string{
		EntryPagePath:                         EntryPagePath,
		TicketsPagePath + "/o/r/7":            TicketsPagePath + "/o/r/7",
		TryPagePath:                           TryPagePath,
		"https://evil.example/":               AppPrefix,
		TicketsPagePath + "/../../etc/passwd": AppPrefix,
	} {
		r := httptest.NewRequest(http.MethodGet, "/auth/github/callback", nil)
		r.AddCookie(&http.Cookie{Name: entryReturnCookie, Value: v})
		if got := loginReturn(httptest.NewRecorder(), r); got != want {
			t.Errorf("cookie %q: back to %q, want %q", v, got, want)
		}
	}
}
