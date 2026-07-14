# Linux systemd user units

Parity with `launchd/` for Linux. Two always-on services (spinner + the optional
webhook daemon) plus the `.timer` + `.service` pairs matching the launchd
`StartInterval`s:

| Unit | Cadence | launchd equivalent | Optional? |
|---|---|---|---|
| `claude-fleet-spinner.service` | always-on (`Restart=always`) | `com.claude-fleet.spinner` (KeepAlive) | required |
| `claude-fleet-webhook.service` | always-on (`Restart=always`) | `com.claude-fleet.webhook` (KeepAlive) | optional (fresh ~1s PR/issue/CI status via `gh webhook forward`, no public endpoint; needs FLEET_WEBHOOK=1 per fleet + the `cli/gh-webhook` extension) |
| `claude-fleet-collect.timer` | every 60s, +10s after start | `com.claude-fleet.collect` | required |
| `claude-fleet-diskguard.timer` | every 60s, +10s after start | `com.claude-fleet.diskguard` | recommended |
| `claude-fleet-pr-refresh.timer` | every 15s, +5s after start | `com.claude-fleet.pr-refresh` | recommended (fast PR/CI status) |
| `claude-fleet-issue-bridge.timer` | every 15s, +5s after start | `com.claude-fleet.issue-bridge` | optional (issue→worker relay; LLM tokens) |
| `claude-fleet-watch.timer` | every 45s, +5s after start | `com.claude-fleet.watch` | optional (zero-token steward wake; wakes spend steward tokens) |
| `claude-fleet-cleanup.timer` | every 60s, +25s after start | `com.claude-fleet.cleanup` | recommended (reap worktrees after merges; the fleet never merges) |
| `claude-fleet-ledger-watch.timer` | every 60s, +30s after start | `com.claude-fleet.ledger-watch` | recommended (index every closed worker session for `/fleet-history` resume) |
| `claude-fleet-base-sync.timer` | every 60s, +35s after start | `com.claude-fleet.base-sync` | recommended (keep the local base fast-forwarded to the remote, merge-independent; ON per fleet unless `FLEET_BASE_SYNC=0`) |
| `claude-fleet-worktree-autoclean.timer` | hourly, no run at start | `com.claude-fleet.worktree-autoclean` | optional |

Every file is `__HOME__`-templated exactly like the plists — substitute the
real home dir at install time.

## Install

```sh
# 1. Substitute __HOME__ and drop the units into the user unit dir.
mkdir -p ~/.config/systemd/user ~/.claude/fleet/logs
for f in systemd/*.service systemd/*.timer; do
  sed "s|__HOME__|$HOME|g" "$f" > ~/.config/systemd/user/"$(basename "$f")"
done

# 2. Reload, then enable. Enable the .timer (not the .service) for the
#    interval units; enable the spinner .service directly.
systemctl --user daemon-reload
systemctl --user enable --now claude-fleet-spinner.service
systemctl --user enable --now claude-fleet-collect.timer
systemctl --user enable --now claude-fleet-diskguard.timer   # recommended: crash-guard
systemctl --user enable --now claude-fleet-pr-refresh.timer  # recommended: fast ~15s PR/CI status
systemctl --user enable --now claude-fleet-cleanup.timer    # recommended: reap worktrees after merges (the fleet never merges); ON per fleet unless FLEET_CLEANUP=0
systemctl --user enable --now claude-fleet-ledger-watch.timer # recommended: index every closed worker session for resume; ON per fleet unless FLEET_LEDGER_WATCH=0
systemctl --user enable --now claude-fleet-base-sync.timer  # recommended: keep the local base fast-forwarded to the remote (merge-independent); ON per fleet unless FLEET_BASE_SYNC=0
# optional:
systemctl --user enable --now claude-fleet-issue-bridge.timer # issue→worker relay — needs FLEET_ISSUE_BRIDGE=1 per fleet
systemctl --user enable --now claude-fleet-watch.timer      # steward wake — needs FLEET_WATCH=1 + FLEET_STEWARD_ISSUE per fleet
systemctl --user enable --now claude-fleet-webhook.service  # fresh ~1s PR/issue/CI status — needs FLEET_WEBHOOK=1 per fleet + `gh extension install cli/gh-webhook`
systemctl --user enable --now claude-fleet-worktree-autoclean.timer

# 3. Keep the units running when you are not logged in (detached fleets).
loginctl enable-linger "$USER"
```

## Verify / inspect

```sh
systemctl --user list-timers 'claude-fleet-*'
systemctl --user status claude-fleet-spinner.service
journalctl --user -u claude-fleet-collect.service --since '5 min ago'
```

## Uninstall

```sh
for u in spinner.service webhook.service collect.timer diskguard.timer pr-refresh.timer \
         issue-bridge.timer watch.timer cleanup.timer ledger-watch.timer \
         base-sync.timer worktree-autoclean.timer; do
  systemctl --user disable --now "claude-fleet-$u" 2>/dev/null
done
rm -f ~/.config/systemd/user/claude-fleet-*.{service,timer}
systemctl --user daemon-reload
# loginctl disable-linger "$USER"   # if nothing else needs lingering
```
