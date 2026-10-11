package api

import (
	"context"
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/dns"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Every person's address follows their home (claude-fleet#3073, EPIC #3067
// C7) — on a fake zone.

// dnsReach makes machine reachable at addrs (checked at now), or not at all.
func dnsReach(t *testing.T, h *harness, machine string, now time.Time, ok bool, addrs ...string) {
	t.Helper()
	var rows []store.EntryReach
	for _, a := range addrs {
		port := entryPort // "addr", or "addr:port" / "[v6]:port" on the router's port
		if ap, err := netip.ParseAddrPort(a); err == nil {
			a, port = ap.Addr().String(), int(ap.Port())
		}
		fam := "ipv4"
		if strings.Contains(a, ":") {
			fam = "ipv6"
		}
		rows = append(rows, store.EntryReach{Machine: machine, Addr: a, Port: port, Family: fam, Via: "report",
			Reachable: ok, CheckedAt: now})
	}
	if _, err := h.srv.Store.SetEntryReach(machine, rows); err != nil {
		t.Fatal(err)
	}
}

// dnsZone is the zone but the unclaimed-name guard (dnsGuard's).
func dnsZone(f *dns.Fake) string {
	var b []string
	for _, r := range f.Records() {
		if r.Name == "*.cf" && r.Type == "TXT" {
			continue
		}
		b = append(b, r.Type+" "+r.Name+" "+r.Value)
	}
	return strings.Join(b, " | ")
}

func dnsAudits(t *testing.T, h *harness, person string) []string {
	t.Helper()
	all, err := h.srv.Store.EntryAudits(person, 200)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, a := range all {
		if a.Kind == "dns" {
			out = append(out, a.Result)
		}
	}
	return out
}

// The completion criterion: the address moves ⇒ the next tick changes the
// record; the home unreachable ⇒ nothing changes; the home moved by hand ⇒
// the next tick points at the new home; only the difference is written; a
// hand edit is put back with a line saying so; a retired name answers its
// seven days, then goes.
func TestEntryDNSFollowsTheHome(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	ctx := context.Background()
	now := time.Now().UTC()

	// Someone else's record in the zone (the fake lists it as if marked):
	// not under the subdomain, so never touched.
	if _, err := f.Upsert(ctx, dns.Record{Name: "www", Type: "A", Value: "47.107.245.170", TTL: 600}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini", now, true, "23.119.126.213", "2001:db8::5")

	if n := h.srv.EntryDNSTick(ctx, now); n != 3 {
		t.Fatalf("first tick: %d writes, want 3 — alice's two and the guard (%s)", n, dnsZone(f))
	}
	want := "A alice.cf 23.119.126.213 | AAAA alice.cf 2001:db8::5 | A www 47.107.245.170"
	if got := dnsZone(f); got != want {
		t.Fatalf("zone: %s\nwant %s", got, want)
	}
	// Records only as long as the person's name: the TTL is the zone's floor.
	for _, r := range f.Records() {
		if r.Name == "alice.cf" && r.TTL != dns.TTL {
			t.Fatalf("ttl %d", r.TTL)
		}
	}

	// Nothing moved: one List, no write.
	ups, dels := f.Calls["Upsert"], f.Calls["Delete"]
	if n := h.srv.EntryDNSTick(ctx, now.Add(time.Minute)); n != 0 || f.Calls["Upsert"] != ups || f.Calls["Delete"] != dels {
		t.Fatalf("still: %d writes, calls %v", n, f.Calls)
	}

	// The broadband's address changes: the next tick changes the one record,
	// in place (the same record id).
	var aID string
	for _, r := range f.Records() {
		if r.Name == "alice.cf" && r.Type == "A" {
			aID = r.ID
		}
	}
	t2 := now.Add(5 * time.Minute)
	dnsReach(t, h, "macmini", t2, true, "23.119.126.99", "2001:db8::5")
	if n := h.srv.EntryDNSTick(ctx, t2); n != 1 {
		t.Fatalf("moved: %d writes, want 1", n)
	}
	for _, r := range f.Records() {
		if r.Name == "alice.cf" && r.Type == "A" && (r.ID != aID || r.Value != "23.119.126.99") {
			t.Fatalf("moved: %+v, want id %s → 23.119.126.99", r, aID)
		}
	}

	// The home nobody reaches: nothing changes, the last address stays.
	before := dnsZone(f)
	t3 := t2.Add(5 * time.Minute)
	dnsReach(t, h, "macmini", t3, false, "23.119.126.99", "2001:db8::5")
	if n := h.srv.EntryDNSTick(ctx, t3); n != 0 || dnsZone(f) != before {
		t.Fatalf("unreachable: %d writes, zone %s (was %s)", n, dnsZone(f), before)
	}
	// …and a check gone stale (the home silent) is the same: no fresh
	// reachable address ⇒ hold.
	if n := h.srv.EntryDNSTick(ctx, t3.Add(EntryReachFresh+time.Minute)); n != 0 || dnsZone(f) != before {
		t.Fatalf("stale: %d writes, zone %s", n, dnsZone(f))
	}

	// Someone edits the record by hand: put back, and said so.
	t4 := t3.Add(5 * time.Minute)
	dnsReach(t, h, "macmini", t4, true, "23.119.126.99", "2001:db8::5")
	h.srv.EntryDNSTick(ctx, t4)
	f.Set(aID, "1.2.3.4")
	if n := h.srv.EntryDNSTick(ctx, t4.Add(time.Minute)); n != 1 {
		t.Fatalf("hand edit: %d writes", n)
	}
	if got := dnsAudits(t, h, pAlice); len(got) == 0 || !strings.Contains(got[0], "有人手改") || !strings.Contains(got[0], "1.2.3.4 → 23.119.126.99") {
		t.Fatalf("hand edit audit: %q", got)
	}

	// The person moves their home by hand: the next tick points at it — an
	// IPv4-only home, so the AAAA goes.
	t5 := t4.Add(5 * time.Minute)
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini-m4", Login: "alice", SetBy: "t", SetAt: t5}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini-m4", t5, true, "23.119.126.77")
	if n := h.srv.EntryDNSTick(ctx, t5); n != 2 {
		t.Fatalf("new home: %d writes, want 2 (%s)", n, dnsZone(f))
	}
	if got, want := dnsZone(f), "A alice.cf 23.119.126.77 | A www 47.107.245.170"; got != want {
		t.Fatalf("new home: %s\nwant %s", got, want)
	}
	for _, line := range dnsAudits(t, h, pAlice)[:2] {
		if strings.Contains(line, "有人手改") {
			t.Fatalf("a home move is no hand edit: %q", line)
		}
	}

	// A new name: the old one keeps answering its seven days, then goes.
	t6 := t5.Add(time.Minute)
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice2", t6); err != nil {
		t.Fatal(err)
	}
	h.srv.EntryDNSTick(ctx, t6)
	if got, want := dnsZone(f), "A alice.cf 23.119.126.77 | A alice2.cf 23.119.126.77 | A www 47.107.245.170"; got != want {
		t.Fatalf("renamed: %s\nwant %s", got, want)
	}
	t7 := t6.Add(store.EntryNameKeep + time.Hour)
	dnsReach(t, h, "macmini-m4", t7, true, "23.119.126.77")
	h.srv.EntryDNSTick(ctx, t7)
	if got, want := dnsZone(f), "A alice2.cf 23.119.126.77 | A www 47.107.245.170"; got != want {
		t.Fatalf("past seven days: %s\nwant %s", got, want)
	}
}

// A provider that fails: nothing written is counted as written, and the next
// tick tries again.
func TestEntryDNSRetriesAFailedWrite(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	ctx := context.Background()
	now := time.Now().UTC()
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini", now, true, "23.119.126.213")
	f.Fail = errors.New("list down")
	if n := h.srv.EntryDNSTick(ctx, now); n != 0 || len(f.Records()) != 0 {
		t.Fatalf("list down: %d writes", n)
	}
	h.srv.EntryDNSTick(ctx, now)
	if got := dnsZone(f); got != "A alice.cf 23.119.126.213" {
		t.Fatalf("after: %s", got)
	}
	if got := dnsAudits(t, h, pAlice); len(got) != 1 {
		t.Fatalf("audit: %q", got)
	}
}

// No token ⇒ no call at all; the book off ⇒ no call either, even with one.
func TestEntryDNSOffMakesNoCall(t *testing.T) {
	for _, k := range []string{"CCQUOTA_DNS_DP_ID", "CCQUOTA_DNS_DP_KEY", "CCQUOTA_DNS_DOMAIN", "CCQUOTA_DNS_SUBDOMAIN"} {
		t.Setenv(k, "")
	}
	if _, ok := dns.FromEnv(); ok {
		t.Fatal("FromEnv on with nothing set")
	}
	t.Setenv("CCQUOTA_DNS_DP_ID", "1")
	t.Setenv("CCQUOTA_DNS_DOMAIN", "24haowan.com")
	t.Setenv("CCQUOTA_DNS_SUBDOMAIN", "cf")
	if _, ok := dns.FromEnv(); ok {
		t.Fatal("FromEnv on without the key")
	}

	h := entryHarness(t)
	now := time.Now().UTC()
	if _, err := h.srv.Store.SetEntryName(pAlice, "alice", now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini", now, true, "23.119.126.213")
	// Off: RunEntryDNS returns at once, a tick does nothing.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { h.srv.RunEntryDNS(ctx); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("RunEntryDNS with no writer did not return")
	}
	if n := h.srv.EntryDNSTick(ctx, now); n != 0 {
		t.Fatalf("off: %d writes", n)
	}

	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	// With records the door defaults on (claude-fleet#3199): switched off by hand.
	if err := h.srv.Store.SetFleetSetting(EntryKey, "off", now); err != nil {
		t.Fatal(err)
	}
	if n := h.srv.EntryDNSTick(ctx, now); n != 0 || f.Total() != 0 {
		t.Fatalf("book off: %d writes, %d calls", n, f.Total())
	}
}

// The page says the home is not reachable from outside — only with the
// records on (no writer: the page as before), and not once C6 reaches it.
func TestEntryPageHomeUnreachableFromOutside(t *testing.T) {
	h := entryHarness(t)
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	home := func() store.EntryHome {
		_, _, _ = keysPage(t, h, pAlice, "", nil) // the first visit picks the home
		home, ok, err := h.srv.Store.EntryHomeOf(pAlice)
		if err != nil || !ok {
			t.Fatalf("no home: %v", err)
		}
		return home
	}()
	page := func(what, want string, not ...string) string {
		t.Helper()
		_, body, _ := keysPage(t, h, pAlice, "?step=5", nil)
		if !strings.Contains(body, want) {
			t.Fatalf("%s: no %q\n%s", what, want, body)
		}
		for _, n := range not {
			if strings.Contains(body, n) {
				t.Fatalf("%s: %q\n%s", what, n, body)
			}
		}
		return body
	}
	// No key: nothing listens, and that is no failure (claude-fleet#3199).
	page("no key", "加上第一把钥匙后，家机器会打开入口", "外面还连不上")
	keysPost(t, h, pAlice, "do", "add", "key", entryKeyLine(t, "p"), "label", "iPhone")
	// A key just added, no report since: opening, and the page reloads itself.
	body := page("just added", "正在为你打开入口", "外面还连不上")
	if !strings.Contains(body, `http-equiv="refresh"`) {
		t.Fatal("opening, but the page does not reload")
	}
	// The home reports, not listening yet: still opening.
	h.srv.entryReachSeen.Store(strings.ToLower(home.Machine), entryReachSeen{At: time.Now(), Listening: false})
	page("not listening yet", "正在为你打开入口")
	// Past the grace: say where it is stuck.
	old := entryOpenGrace
	entryOpenGrace = 0
	t.Cleanup(func() { entryOpenGrace = old })
	page("past the grace", "入口没在听", "正在为你打开")
	dnsReach(t, h, home.Machine, time.Now().UTC(), false, "23.119.126.213")
	page("dialled, nobody answers", "没有回应：路由器还没把端口 22022 转到")
	dnsReach(t, h, home.Machine, time.Now().UTC(), true, "23.119.126.213")
	page("reachable", "外面连得上", "外面还连不上", `http-equiv="refresh"`)
}

// Two homes behind one router (EPIC #3067 改约定 3): one address, the port
// the router forwards tells them apart. The page's Termius port is the
// home's, a move to the other says the port changes, and an IPv6 the door
// answers on another port than the A's gets no AAAA.
func TestEntryDNSPortIsTheHomes(t *testing.T) {
	h := entryHarness(t)
	f := dns.NewFake()
	h.srv.EntryDNS = NewEntryDNS(f, "cf")
	_ = h.srv.Store.SetFleetSetting(EntryDomainKey, "cf.24haowan.com", time.Now())
	keysPost(t, h, pAlice, "do", "name", "name", "alice")
	now := time.Now().UTC()
	if _, err := h.srv.Store.SetEntryHome(store.EntryHome{Person: pAlice, Machine: "macmini-m4", Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	dnsReach(t, h, "macmini", now, true, "23.119.126.213:22122")
	dnsReach(t, h, "macmini-m4", now, true, "23.119.126.213:22123", "[2001:db8::9]:22022")
	h.srv.EntryDNSTick(context.Background(), now)
	if got, want := dnsZone(f), "A alice.cf 23.119.126.213"; got != want {
		t.Fatalf("zone: %s\nwant %s (no AAAA on another port)", got, want)
	}
	_, body, _ := keysPage(t, h, pAlice, "?step=4", nil)
	if !strings.Contains(body, `<span class="v">22123</span>`) {
		t.Fatalf("home macmini-m4: the port is not 22123:\n%s", body)
	}
	_, body, _ = keysPage(t, h, pAlice, "?move=macmini&login=alice", nil)
	if !strings.Contains(body, "端口改成 <b>22122</b>（原来 22123）") {
		t.Fatalf("move sheet does not say the port changes:\n%s", body)
	}
}
