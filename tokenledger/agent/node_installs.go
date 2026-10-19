package agent

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

// The heartbeat's installs (claude-fleet#2697): this login's three kinds of
// install — the machine runtime, its own login install, its client shell — as
// `fleet-installs.sh --json` reads them. The ONE reading is the claude-fleet
// script's, never a second copy here; each login asks for its own home only
// (FLEET_INSTALLS_LOGIN), with no sudo and no hub, and the hub folds every
// login's into the machine's 「安装」 and judges them against its stable.

var installsScript = filepath.Join(".claude", "fleet", "bin", "fleet-installs.sh")

const (
	// installsInterval: an install moves when a release lands, not per beat.
	installsInterval = 5 * time.Minute
	installsTimeout  = 30 * time.Second
)

// installsCommand is the seam the tests replace.
var installsCommand = credsepCommand

type installsProbe struct {
	at  time.Time
	val *control.Installs
}

// reading is this login's installs; nil when the script is missing or said
// nothing readable (the beat then carries none, like an older agent).
func (p *installsProbe) reading(ctx context.Context, home string, now time.Time) *control.Installs {
	if !p.at.IsZero() && now.Sub(p.at) < installsInterval {
		return p.val
	}
	p.at, p.val = now, installsRead(ctx, home, now)
	return p.val
}

func installsRead(ctx context.Context, home string, now time.Time) *control.Installs {
	if home == "" {
		return nil
	}
	script := filepath.Join(home, installsScript)
	if _, err := os.Stat(script); err != nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, installsTimeout)
	defer cancel()
	cmd := installsCommand(ctx, "/bin/bash", script, "--json")
	cmd.Env = append(os.Environ(), "HOME="+home,
		"FLEET_INSTALLS_HOMES="+filepath.Dir(home), "FLEET_INSTALLS_LOGIN="+filepath.Base(home),
		"FLEET_INSTALLS_SUDO=", "FLEET_INSTALLS_HUB=")
	if err := prepCmd(ctx, cmd); err != nil {
		return nil
	}
	// exit 1 (one is behind) and 2 (no stable known here) still print the JSON
	out, _ := cmd.Output()
	var got struct {
		Stable  *string                `json:"stable"`
		Runtime *control.InstallItem   `json:"runtime"`
		Logins  []control.LoginInstall `json:"logins"`
	}
	if json.Unmarshal(out, &got) != nil {
		return nil
	}
	in := &control.Installs{Runtime: got.Runtime, Logins: got.Logins}
	if got.Stable != nil {
		in.Stable = *got.Stable
	}
	at := now.UTC()
	in.At = &at
	return in
}

// installsOwnVersion is the version of the login's own install in a reading,
// "" when it has none. A managed login's ~/.claude/fleet is a link tree with
// no git (claude-fleet#2774), so fleet-install-version.sh says no head there;
// this is what the beat's fleet_version falls back to (claude-fleet#2697).
func installsOwnVersion(in *control.Installs, home string) string {
	if in == nil {
		return ""
	}
	me := filepath.Base(home)
	for _, l := range in.Logins {
		if l.Login == me && l.Install != nil && l.Install.Version != "-" {
			return l.Install.Version
		}
	}
	return ""
}
