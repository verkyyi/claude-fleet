// Package identity answers two questions the transcripts cannot: which
// subscription this machine's usage belongs to, and which machine it is.
//
// Claude Code's transcript files record no account. The agent stamps identity
// at scan time from ~/.claude.json. That is a real seam: if a machine logs out
// and into a different account, rows already ingested keep the old
// attribution. The hub records the switch so the seam is visible rather than
// silent — see the account_switches table and spec §10.2.
package identity

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"time"

	"github.com/verkyyi/ccquota/internal/model"
)

// claudeConfig is the subset of ~/.claude.json ccquota reads.
type claudeConfig struct {
	MachineID    string `json:"machineID"`
	UserID       string `json:"userID"`
	OAuthAccount *struct {
		AccountUUID      string `json:"accountUuid"`
		EmailAddress     string `json:"emailAddress"`
		OrganizationUUID string `json:"organizationUuid"`
		OrganizationName string `json:"organizationName"`
		DisplayName      string `json:"displayName"`
		AccountCreatedAt string `json:"accountCreatedAt"`
	} `json:"oauthAccount"`
	LastReleaseNotesSeen string `json:"lastReleaseNotesSeen"`
}

var semverish = regexp.MustCompile(`^\d+\.\d+\.\d+`)

// Detect builds an Identity from a Claude Code home directory (the parent of
// .claude, normally $HOME).
//
// hostname/OS/arch come from the running machine. Subscription type and tier
// are not here: they live alongside the OAuth token, and reading them is the
// credential path's job — Detect stays usable on a machine where the token is
// unreadable.
func Detect(home string) (*model.Identity, error) {
	path := filepath.Join(home, ".claude.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg claudeConfig
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if cfg.OAuthAccount == nil || cfg.OAuthAccount.AccountUUID == "" {
		return nil, fmt.Errorf("%s has no oauthAccount.accountUuid: is Claude Code logged in?", path)
	}

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	id := &model.Identity{
		AccountUUID: cfg.OAuthAccount.AccountUUID,
		Email:       cfg.OAuthAccount.EmailAddress,
		OrgUUID:     cfg.OAuthAccount.OrganizationUUID,
		OrgName:     cfg.OAuthAccount.OrganizationName,
		DisplayName: cfg.OAuthAccount.DisplayName,
		MachineID:   cfg.MachineID,
		Hostname:    hostname,
		OS:          runtime.GOOS,
		Arch:        runtime.GOARCH,
	}
	// The account boundary. Turns older than this cannot belong to this
	// subscription, whatever the transcripts imply.
	if ts := cfg.OAuthAccount.AccountCreatedAt; ts != "" {
		if t, err := time.Parse(time.RFC3339Nano, ts); err == nil {
			id.AccountCreatedAt = t.UTC()
		}
	}

	// Approximate: Claude Code records the version whose release notes were
	// last shown, which tracks the installed version closely enough to tell
	// "this fleet is on 2.1.x" without shelling out to the CLI on every poll.
	if semverish.MatchString(cfg.LastReleaseNotesSeen) {
		id.CCVersion = cfg.LastReleaseNotesSeen
	}
	return id, nil
}

// ProjectsDir is where Claude Code writes transcripts.
func ProjectsDir(home string) string {
	return filepath.Join(home, ".claude", "projects")
}
