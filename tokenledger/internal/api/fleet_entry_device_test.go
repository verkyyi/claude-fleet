package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
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

// reachable(machine) (C6) feeds the route list: a machine the hub reached at
// its entry port gets `entry` routes on those addresses — IPv4 first, IPv6 a
// literal — one never reached (or reached too long ago) gets none, and a
// machine whose node names its own `entry=` keeps that one alone.
func TestEntryRoutesFromReach(t *testing.T) {
	h, _, _, _, _ := homeHarness(t)
	setRoutes := func(js string) {
		t.Helper()
		routes, err := ParseFleetRoutes(js)
		if err != nil {
			t.Fatal(err)
		}
		h.srv.FleetRoutes = routes
	}
	setRoutes(`[{"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5","port":22022}]},
	  {"hostname":"m4","routes":[{"name":"public","host":"203.0.113.4","port":22023}]}]`)
	if err := h.srv.Store.SetFleetSetting(EntryKey, "on", time.Now()); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for m, rows := range map[string][]store.EntryReach{
		"m5": {{Addr: "2001:db8::5", Port: 22122, Family: "ipv6", Reachable: true, CheckedAt: now},
			{Addr: "203.0.113.5", Port: 22122, Family: "ipv4", Reachable: true, CheckedAt: now}},
		"m4": {{Addr: "203.0.113.4", Port: 22123, Family: "ipv4", Reachable: false, Reason: "timeout", CheckedAt: now},
			{Addr: "198.51.100.4", Port: 22123, Family: "ipv4", Reachable: true, CheckedAt: now.Add(-time.Hour)}},
	} {
		if _, err := h.srv.Store.SetEntryReach(m, rows); err != nil {
			t.Fatal(err)
		}
	}
	a := newDevice(t)
	a.scan(t, h, pAlice, "MacBook")
	list := func() map[string]string {
		t.Helper()
		ts := time.Now().Unix()
		code, body := postJSON(t, h, control.RoutesPath, map[string]any{"cert": a.cert, "ts": ts,
			"sig": sshsig(t, a.signer, control.RoutesSigNamespace, []byte(control.RoutesSigMessage(ts)))})
		if code != 200 {
			t.Fatalf("routes: %d %s", code, body)
		}
		var out RoutesResponse
		if err := json.Unmarshal(body, &out); err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for _, m := range out.Machines {
			var rs []string
			for _, r := range m.Routes {
				rs = append(rs, fmt.Sprintf("%s=%s:%d", r.Name, r.Host, r.Port))
			}
			got[m.Hostname] = strings.Join(rs, ",")
		}
		return got
	}
	want := map[string]string{
		"m5": "public=203.0.113.5:22022,entry=203.0.113.5:22122,entry-2=2001:db8::5:22122",
		"m4": "public=203.0.113.4:22023", // unreachable, and a reach an hour old
	}
	got := list()
	for m, w := range want {
		if got[m] != w {
			t.Fatalf("%s: %s, want %s", m, got[m], w)
		}
	}
	// The node names its own entry=: that one alone.
	setRoutes(`[{"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5","port":22022},{"name":"entry","host":"ssh.example.com","port":22122}]}]`)
	if g := list()["m5"]; g != "public=203.0.113.5:22022,entry=ssh.example.com:22122" {
		t.Fatalf("m5 with entry=: %s", g)
	}
	// The door off: as before.
	if err := h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now()); err != nil {
		t.Fatal(err)
	}
	setRoutes(`[{"hostname":"m5","routes":[{"name":"public","host":"203.0.113.5","port":22022}]}]`)
	if g := list()["m5"]; g != "public=203.0.113.5:22022" {
		t.Fatalf("door off: %s", g)
	}
}
