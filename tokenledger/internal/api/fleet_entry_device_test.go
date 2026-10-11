package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// A computer's key on its person's door list (claude-fleet#3075, EPIC #3067
// C9): the door off, a scan puts nothing there; on, the next renewal adds the
// device's key as 「<device> · fleet」, a key the person took off stays off
// through renewals and comes back only with a fresh scan, and revoking the
// device revokes the key.
func TestEntryDeviceKey(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	a := newDevice(t)
	live := func() []string {
		t.Helper()
		ks, err := h.srv.Store.EntryKeys(pAlice, false)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, k := range ks {
			if k.FP != a.fp {
				t.Fatalf("a key that is not the device's: %+v", k)
			}
			out = append(out, k.Name)
		}
		return out
	}

	a.scan(t, h, pAlice, "MacBook")
	if got := live(); len(got) != 0 {
		t.Fatalf("door off: keys %v after a scan, want none", got)
	}
	if v, _ := h.srv.Store.EntryVersion(); v != 0 {
		t.Fatalf("door off: version %d", v)
	}

	if err := h.srv.Store.SetFleetSetting(EntryKey, "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	// Registered before the door was on: the next renewal brings its key.
	if code, _ := a.renew(t, h, time.Now().Unix()); code != 200 {
		t.Fatalf("renew: %d", code)
	}
	if got := live(); len(got) != 1 || got[0] != "MacBook · fleet" {
		t.Fatalf("after a renewal: %v, want [MacBook · fleet]", got)
	}
	// Again: still one.
	a.renew(t, h, time.Now().Unix())
	if got := live(); len(got) != 1 {
		t.Fatalf("a second renewal: %v", got)
	}

	// The person takes it off on the keys page: renewals leave it off.
	ks, _ := h.srv.Store.EntryKeys(pAlice, false)
	if _, _, err := h.srv.entryRevoke(entryCaller{actor: pAlice, person: pAlice}, ks[0].ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	a.renew(t, h, time.Now().Unix())
	if got := live(); len(got) != 0 {
		t.Fatalf("a renewal brought back a key the person revoked: %v", got)
	}
	// A scan is a fresh proof: it is back.
	a.scan(t, h, pAlice, "MacBook")
	if got := live(); len(got) != 1 {
		t.Fatalf("after a re-scan: %v", got)
	}

	// The device is revoked: so is its key.
	body, _ := json.Marshal(map[string]string{"fingerprint": a.fp})
	r, _ := http.NewRequest(http.MethodPost, h.http.URL+"/v1/fleet/devices/revoke", bytes.NewReader(body))
	r.Header.Set("Authorization", "Bearer "+viewerToken)
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("revoke: %d", resp.StatusCode)
	}
	if got := live(); len(got) != 0 {
		t.Fatalf("a revoked device's key is still on the door: %v", got)
	}
	audit, _ := h.srv.Store.EntryAudits(pAlice, 0)
	n := 0
	for _, l := range audit {
		if l.Kind == "key_revoke" && l.FP == a.fp && l.Actor == "operator" {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("the door's record has %d operator revocations of the device key, want 1: %+v", n, audit)
	}
}
