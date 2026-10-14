package agent

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// installsHome lays a fake fleet-installs.sh under <tmp>/<login> that prints
// body (with $FLEET_INSTALLS_LOGIN etc. expanded by the shell) and exits rc.
func installsHome(t *testing.T, login, body string, rc int) string {
	t.Helper()
	home := filepath.Join(t.TempDir(), login)
	bin := filepath.Join(home, ".claude", "fleet", "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	sh := "cat <<EOF\n" + body + "\nEOF\nexit " + string(rune('0'+rc)) + "\n"
	if err := os.WriteFile(filepath.Join(bin, "fleet-installs.sh"), []byte(sh), 0o755); err != nil {
		t.Fatal(err)
	}
	return home
}

// The beat's installs are this login's own (claude-fleet#2697): the script is
// asked for one home with no sudo and no hub, and its JSON is carried even on
// exit 1 / 2 (behind, no stable known here).
func TestInstallsReadOwnLogin(t *testing.T) {
	home := installsHome(t, "alice", `{"host":"m","stable":null,"lane":"stable","runtime":{"version":"aaaa111","source":"hub","at_stable":null},
"logins":[{"login":"$FLEET_INSTALLS_LOGIN","install":{"kind":"link","version":"bbbb222","source":"runtime","at_stable":null},"shell":null,"client":{"version":"cccc333","source":"hub","at_stable":false}}],
"unreadable":["sudo=[$FLEET_INSTALLS_SUDO]","hub=[$FLEET_INSTALLS_HUB]","homes=$FLEET_INSTALLS_HOMES"]}`, 2)
	var p installsProbe
	now := time.Now()
	in := p.reading(context.Background(), home, now)
	if in == nil {
		t.Fatal("no reading")
	}
	if in.Runtime == nil || in.Runtime.Version != "aaaa111" || in.Runtime.AtStable != nil {
		t.Fatalf("runtime = %+v", in.Runtime)
	}
	if len(in.Logins) != 1 || in.Logins[0].Login != "alice" || in.Logins[0].Install.Kind != "link" {
		t.Fatalf("logins = %+v", in.Logins)
	}
	if c := in.Logins[0].Client; c == nil || c.AtStable == nil || *c.AtStable {
		t.Fatalf("client = %+v", c)
	}
	if in.Stable != "" || in.Lane != "stable" || in.At == nil {
		t.Fatalf("installs = %+v", in)
	}
	if got := installsOwnVersion(in, home); got != "bbbb222" {
		t.Fatalf("own version = %q", got)
	}
	// cached within the interval: the script is not asked again
	os.Remove(filepath.Join(home, installsScript))
	if p.reading(context.Background(), home, now.Add(time.Minute)) != in {
		t.Fatal("re-read inside the interval")
	}
	if p.reading(context.Background(), home, now.Add(installsInterval)) != nil {
		t.Fatal("a missing script still reports")
	}
}

// The probe's seams: no sudo, no hub, the one home.
func TestInstallsAsksOneHomeNoSudoNoHub(t *testing.T) {
	home := installsHome(t, "bob", `{"logins":[],"runtime":null,"lane":"$FLEET_INSTALLS_SUDO|$FLEET_INSTALLS_HUB|$FLEET_INSTALLS_LOGIN|$FLEET_INSTALLS_HOMES"}`, 0)
	in := installsRead(context.Background(), home, time.Now())
	if in == nil {
		t.Fatal("no reading")
	}
	if want := "||bob|" + filepath.Dir(home); in.Lane != want {
		t.Fatalf("env = %q, want %q", in.Lane, want)
	}
	if in.Runtime != nil {
		t.Fatalf("runtime = %+v", in.Runtime)
	}
}

// A login without the script, or one that prints no JSON: no installs, and
// the beat carries none.
func TestInstallsMissingOrGarbage(t *testing.T) {
	if installsRead(context.Background(), t.TempDir(), time.Now()) != nil {
		t.Fatal("no script, still a reading")
	}
	home := installsHome(t, "carol", "not json", 1)
	if installsRead(context.Background(), home, time.Now()) != nil {
		t.Fatal("garbage read as installs")
	}
	var hb control.Heartbeat
	fleetPart{}.fill(&hb, time.Time{})
	if hb.Installs != nil {
		t.Fatal("an empty part filled installs")
	}
	if installsOwnVersion(nil, "/x/y") != "" {
		t.Fatal("nil reading has a version")
	}
}
