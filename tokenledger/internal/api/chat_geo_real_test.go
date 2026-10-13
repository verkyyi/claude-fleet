package api

import (
	"net/netip"
	"os"
	"testing"
)

// TestChatGeoRealDB reads the pinned ip2region xdb the hub image carries
// (claude-fleet#4039) when CCQUOTA_TEST_GEO_DB names a copy of it; skipped
// otherwise — CI holds no 11 MB file.
func TestChatGeoRealDB(t *testing.T) {
	path := os.Getenv("CCQUOTA_TEST_GEO_DB")
	if path == "" {
		t.Skip("CCQUOTA_TEST_GEO_DB not set")
	}
	db, err := loadGeoDB(path)
	if err != nil {
		t.Fatal(err)
	}
	for ip, want := range map[string][3]string{
		"113.88.0.1": {"中国", "广东省", "深圳市"},
		"8.8.8.8":    {"United States", "", ""},
	} {
		c, p, ci := db.lookup(netip.MustParseAddr(ip))
		t.Logf("%s → %q %q %q", ip, c, p, ci)
		if want[0] != "" && c != want[0] {
			t.Errorf("%s: country %q, want %q", ip, c, want[0])
		}
		if want[2] != "" && (p != want[1] || ci != want[2]) {
			t.Errorf("%s: %q %q, want %q %q", ip, p, ci, want[1], want[2])
		}
	}
}
