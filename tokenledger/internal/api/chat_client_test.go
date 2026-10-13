package api

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The browser's place (claude-fleet#4034): the entry writes X-Fleet-Client on
// the relayed request — the address it saw (the right-most public
// X-Forwarded-For entry) and, from an offline ip2region xdb, its city — and
// never passes on one the browser sent.

// writeTestXDB builds a minimal IPv4 xdb: one segment per (start, end, region).
func writeTestXDB(t *testing.T, segs []struct {
	start, end netip.Addr
	region     string
}) string {
	t.Helper()
	b := make([]byte, geoHeader+geoVector)
	binary.LittleEndian.PutUint16(b[0:], 2)
	type seg struct {
		s, e uint32
		ptr  int
		n    int
	}
	var all []seg
	for _, x := range segs {
		ptr := len(b)
		b = append(b, x.region...)
		s4, e4 := x.start.As4(), x.end.As4()
		all = append(all, seg{binary.BigEndian.Uint32(s4[:]), binary.BigEndian.Uint32(e4[:]), ptr, len(x.region)})
	}
	segStart := len(b)
	for _, x := range all {
		var r [geoSegment]byte
		binary.LittleEndian.PutUint32(r[0:], x.s)
		binary.LittleEndian.PutUint32(r[4:], x.e)
		binary.LittleEndian.PutUint16(r[8:], uint16(x.n))
		binary.LittleEndian.PutUint32(r[10:], uint32(x.ptr))
		b = append(b, r[:]...)
	}
	// every /16 points at the whole (sorted, non-overlapping) segment list
	last := segStart + (len(all)-1)*geoSegment
	for i := 0; i < 256*256; i++ {
		binary.LittleEndian.PutUint32(b[geoHeader+i*8:], uint32(segStart))
		binary.LittleEndian.PutUint32(b[geoHeader+i*8+4:], uint32(last))
	}
	p := filepath.Join(t.TempDir(), "ip2region.xdb")
	if err := os.WriteFile(p, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func testGeoSegs() []struct {
	start, end netip.Addr
	region     string
} {
	a := netip.MustParseAddr
	return []struct {
		start, end netip.Addr
		region     string
	}{
		{a("1.0.0.0"), a("1.0.0.255"), "美国|0|0|0|0"},
		{a("203.0.113.0"), a("203.0.113.255"), "中国|0|广东省|深圳市|电信"},
		{a("203.0.114.0"), a("203.0.114.255"), "中国|上海|上海市|联通|CN"},
	}
}

func TestChatGeoLookup(t *testing.T) {
	db, err := loadGeoDB(writeTestXDB(t, testGeoSegs()))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ ip, country, province, city string }{
		{"203.0.113.9", "中国", "广东省", "深圳市"},
		{"203.0.114.1", "中国", "上海", "上海市"},
		{"1.0.0.7", "美国", "", ""},
		{"9.9.9.9", "", "", ""},
		{"2001:db8::1", "", "", ""},
	} {
		co, pr, ci := db.lookup(netip.MustParseAddr(c.ip))
		if co != c.country || pr != c.province || ci != c.city {
			t.Errorf("%s → %q %q %q; want %q %q %q", c.ip, co, pr, ci, c.country, c.province, c.city)
		}
	}
	if _, err := loadGeoDB(filepath.Join(t.TempDir(), "none")); err == nil {
		t.Error("a missing database loaded")
	}
}

func TestChatClientIP(t *testing.T) {
	for _, c := range []struct{ xff, remote, want string }{
		{"", "198.51.100.4:5555", "198.51.100.4"},
		{"10.0.0.1, 203.0.113.9", "10.1.1.1:80", "203.0.113.9"},                // oss-ok: 私网段是这条用例要验的（副本转交一跳）
		{"203.0.113.9, 198.51.100.7, 10.2.0.3", "10.1.1.1:80", "198.51.100.7"}, // oss-ok: 私网段是这条用例要验的（副本转交一跳）
		{"junk", "[::ffff:192.0.2.1]:80", "192.0.2.1"},
	} {
		r, _ := http.NewRequest("GET", "/", nil)
		r.RemoteAddr = c.remote
		if c.xff != "" {
			r.Header.Set("X-Forwarded-For", c.xff)
		}
		if got := chatClientIP(r).String(); got != c.want {
			t.Errorf("xff %q remote %q → %s; want %s", c.xff, c.remote, got, c.want)
		}
	}
}

func decodeChatClient(t *testing.T, v string) ChatClient {
	t.Helper()
	raw, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil {
		t.Fatalf("X-Fleet-Client %q: %v", v, err)
	}
	var c ChatClient
	if err := json.Unmarshal(raw, &c); err != nil {
		t.Fatalf("X-Fleet-Client %q: %v", raw, err)
	}
	return c
}

func TestChatRelaysClientPlace(t *testing.T) {
	h, svc, host, login := chatHarness(t)
	h.srv.ChatGeoDB = writeTestXDB(t, testGeoSegs())
	setChatHome(t, h, pAlice, host, login)
	alice := personCookie(pAlice, "alice")
	forged := base64.RawURLEncoding.EncodeToString([]byte(`{"ip":"6.6.6.6","city":"假的"}`))
	resp := chatDo(t, h, "GET", "/v1/chat/conversation", alice,
		map[string]string{"X-Fleet-Client": forged, "X-Forwarded-For": "203.0.113.9"}, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("conversation: %d", resp.StatusCode)
	}
	svc.mu.Lock()
	got := append([]string(nil), svc.clients...)
	svc.mu.Unlock()
	if len(got) != 1 {
		t.Fatalf("the service saw %d requests; want 1", len(got))
	}
	c := decodeChatClient(t, got[0])
	if c.IP != "203.0.113.9" || c.City != "深圳市" || c.Province != "广东省" || c.Country != "中国" {
		t.Fatalf("the service heard %+v; want the entry's own 203.0.113.9 in 深圳市, never the browser's", c)
	}
	waitFor(t, 5*time.Second, "relay released", func() bool { return h.srv.chatRelays.open() == 0 })
}
