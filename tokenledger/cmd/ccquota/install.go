package main

import (
	"fmt"
	"os"
	"os/user"
	"runtime"
)

// printServiceUnit emits a service definition for the running platform.
//
// It prints rather than installs. Writing to /etc or ~/Library on a machine
// the operator is only trying out is presumptuous, and printing makes the unit
// reviewable before it runs — including the fact that it carries a token.
func printServiceUnit(hub, stateDir string) error {
	exe, err := os.Executable()
	if err != nil {
		exe = "ccquota"
	}
	if hub == "" {
		hub = "https://your-hub.example.com"
	}
	uname := "YOUR_USER"
	if u, err := user.Current(); err == nil {
		uname = u.Username
	}

	switch runtime.GOOS {
	case "linux":
		fmt.Printf(`# Save as /etc/systemd/system/ccquota-agent.service, then:
#   sudo systemctl daemon-reload && sudo systemctl enable --now ccquota-agent
#
# The token goes in an environment file readable only by root, so it does not
# sit in the unit (which is world-readable) or in the process list.
#   sudo install -m 600 /dev/null /etc/ccquota.env
#   echo 'CCQUOTA_TOKEN=<token from ccquota enroll>' | sudo tee /etc/ccquota.env

[Unit]
Description=ccquota agent (Claude Code usage collector)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%s
Environment=CCQUOTA_HUB_URL=%s
EnvironmentFile=/etc/ccquota.env
ExecStart=%s agent --state %s
Restart=always
RestartSec=30

# The agent only ever reads: transcripts, ~/.claude.json, the credential file.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%s

[Install]
WantedBy=multi-user.target
`, uname, hub, exe, stateDir, stateDir)

	case "darwin":
		fmt.Printf(`<!-- Save as ~/Library/LaunchAgents/com.ccquota.agent.plist, then:
       launchctl load -w ~/Library/LaunchAgents/com.ccquota.agent.plist

     A LaunchAgent (not a Daemon) is right here: the agent must run as the
     logged-in user to reach that user's Keychain, where Claude Code stores
     its credentials. A root daemon would find no token and could only ever
     report token counts. -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.ccquota.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>agent</string>
    <string>--state</string>
    <string>%s</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CCQUOTA_HUB_URL</key><string>%s</string>
    <key>CCQUOTA_TOKEN</key><string>REPLACE_WITH_TOKEN</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>%s/agent.log</string>
</dict>
</plist>
`, exe, stateDir, hub, stateDir)

	case "windows":
		fmt.Printf(`# Run in an elevated PowerShell. A Scheduled Task rather than a Windows
# Service: the agent must run as the interactive user to read that user's
# %%USERPROFILE%%\.claude\.credentials.json.

$action  = New-ScheduledTaskAction -Execute "%s" -Argument "agent --state %s"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$set     = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

[Environment]::SetEnvironmentVariable("CCQUOTA_HUB_URL", "%s", "User")
[Environment]::SetEnvironmentVariable("CCQUOTA_TOKEN", "REPLACE_WITH_TOKEN", "User")

Register-ScheduledTask -TaskName "ccquota-agent" -Action $action -Trigger $trigger -Settings $set
`, exe, stateDir, hub)

	default:
		return fmt.Errorf("no service template for %s; run `ccquota agent` under your own supervisor, "+
			"or `ccquota agent --once` from cron", runtime.GOOS)
	}
	return nil
}
