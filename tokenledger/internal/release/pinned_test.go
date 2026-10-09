package release

import (
	"strings"
	"testing"
)

// claude-fleet#2631: the names release.json pins, as fleet-node-update.py
// pinned-artifacts expands them.
func TestPinned(t *testing.T) {
	rj := []byte(`{"schema":1,"components":{"ccquota":{"artifact":"ccquota-{os}-{arch}"},` +
		`"claude":{"version":"2.1.295","artifact":"claude-{version}-{os}-{arch}"},` +
		`"supervisor":{"script":"bin/fleet-node-supervisor.py"}}}`)
	got, err := Pinned(rj, []string{"darwin-arm64", "linux-amd64"})
	if err != nil {
		t.Fatal(err)
	}
	want := "ccquota-darwin-arm64 ccquota-linux-amd64 claude-2.1.295-darwin-arm64 claude-2.1.295-linux-amd64"
	if strings.Join(got, " ") != want {
		t.Fatalf("Pinned = %v, want %s", got, want)
	}
	if _, err := Pinned([]byte("{"), DefaultPlatforms); err == nil {
		t.Error("bad JSON accepted")
	}
	if _, err := Pinned(rj, []string{"darwin"}); err == nil {
		t.Error("a platform with no arch accepted")
	}
	if _, err := Pinned([]byte(`{"components":{"x":{"artifact":"../{os}"}}}`), DefaultPlatforms); err == nil {
		t.Error("a climbing artifact name accepted")
	}
}
