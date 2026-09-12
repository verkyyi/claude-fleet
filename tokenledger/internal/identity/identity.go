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
	"errors"
	"fmt"
	"os"
	"os/user"
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

var ErrNoAccount = errors.New("no Claude account is logged in")

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
		return nil, fmt.Errorf("%s has no oauthAccount.accountUuid: %w", path, ErrNoAccount)
	}

	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	id := &model.Identity{
		Source:      model.SourceClaude,
		AccountUUID: cfg.OAuthAccount.AccountUUID,
		Email:       cfg.OAuthAccount.EmailAddress,
		OrgUUID:     cfg.OAuthAccount.OrganizationUUID,
		OrgName:     cfg.OAuthAccount.OrganizationName,
		DisplayName: cfg.OAuthAccount.DisplayName,
		MachineID:   cfg.MachineID,
		Hostname:    hostname,
		OS:          runtime.GOOS,
		Arch:        runtime.GOARCH,
		OSUser:      osUser(),
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

// Local identifies the collector without requiring a Claude login.
func Local() *model.Identity {
	hostname, _ := os.Hostname()
	return &model.Identity{Hostname: hostname, OS: runtime.GOOS, Arch: runtime.GOARCH, OSUser: osUser()}
}

// Codex transcripts do not attest to an OpenAI account. Keep their usage in
// an explicitly unassigned pool rather than attributing it to a Claude login
// or today's Codex credentials (which may differ from historical sessions).
func Codex() *model.Identity {
	id := Local()
	id.Source = model.SourceCodex
	id.AccountUUID = "codex:local"
	id.DisplayName = "Codex (local usage)"
	return id
}

// ProjectsDir is where Claude Code writes transcripts.
func ProjectsDir(home string) string {
	return filepath.Join(home, ".claude", "projects")
}

// osUser is the OS login this agent runs as.
//
// It reports the login rather than the uid because the uid is not portable and
// not what anyone asks about; and it prefers the real account database over
// $USER, which an agent started by a service manager may not have at all.
//
// An unreadable user is left empty rather than guessed. "" is rendered as
// unknown; a wrong name would attribute one person's spend to another.
func osUser() string {
	if u, err := user.Current(); err == nil {
		if u.Username != "" {
			return u.Username
		}
	}
	return os.Getenv("USER")
}
