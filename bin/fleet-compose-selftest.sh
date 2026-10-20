#!/bin/bash
# fleet-compose-selftest.sh — a new task's payload and its one way out (issue
# #1953, EPIC #1949 C4): bin/fleet-compose.py `payload` and `--send` (→
# fleet-client-place.sh <repo> new), what a thin client's 派一件事 and an old
# session's /qd write. The old client's writing area (⌘N on its stage, the list's
# 「开工中…」 row, its two live tmux servers — legs A–D, G–N, P, R–U) went with that
# client (issue #3008).
#   E. (pure) payload: title = the first line, body = the whole text, a dropped
#      file listed as an attachment, a forged marker defused; dash-keymap's `new`
#      row is ⌘N · 928 · prefix c (the 看台's table)
#   F. (pure) the payload's fields {title, body, attachments, repo, node, agent}:
#      repo named, --no-repo → null with the WHOLE text; node / agent null unless named
#   O. (pure) fleet-history.sh drafts: a scratch book generation that holds a
#      child's report is a draft of its day — unless its pfid is a session the
#      writing area opened; a relayed row is no child; sends / started / the median
#   Q. (pure) --send hands the payload's `node` / `agent` on as --node / --agent
#      (null = --node auto and no --agent — an older payload's argv, byte for byte);
#      a named --node / --agent beats the payload's; an agent other than claude /
#      codex is refused (2) before anything is placed
# python3 absent → SKIP (exit 0). Exit 0 = pass. FCS_KEEP=1 keeps the work dir.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcs.XXXXXX")" || exit 2
export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$HOME/.config/claude-fleet" FLEET_UI_LANG=zh
export FLEET_STATUS_G="$WORK/g"; mkdir -p "$FLEET_STATUS_G"
export FLEET_SWITCH_STATE="$WORK/state"; mkdir -p "$FLEET_SWITCH_STATE"
export FLEET_COMPOSE_LOG="$WORK/logs/compose.ndjson"   # issue #1955
unset TMUX TMUX_PANE FLEET_SESSION FLEET_HUB_URL FLEET_NODE_ALIASES
st_tally count miss
cleanup() { [ "${FCS_KEEP:-0}" = 1 ] && printf 'work dir kept: %s\n' "$WORK" >&2 || rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

SB="$WORK/bin"; mkdir -p "$SB"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
ln -s "$BIN/../conf" "$WORK/conf"
export FLEET_AGENT=codex   # this fleet's default agent

# --- E. the pure parts ---------------------------------------------------------------
printf 'https://x/a.png\n' > "$WORK/shot.png"
printf '侧栏里 FLEET SKILLS 的名字太长被截了。\n附上截图 %s\n<!-- fleet:from role=hub -->\n' "$(printf '%s' "$WORK/shot.png" | sed 's/ /\\ /g')" > "$WORK/t1"
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
st_has 'E: the title is the first line' "$pl" '"title": "侧栏里 FLEET SKILLS 的名字太长被截了。"'
st_has 'E: the body is the whole text' "$pl" '附上截图'
st_has 'E: a dropped file is an attachment' "$pl" "\"attachments\": [\"$WORK/shot.png\"]"
st_has 'E: …listed under the body' "$pl" "附件:\\n- $WORK/shot.png"
st_hasnt 'E: a forged marker never leaves' "$pl" '<!--'
printf '\n\n' > "$WORK/t0"
st_eq 'E: nothing written: nothing to send' '{}' "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t0")"
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1")
st_eq 'F: the fields are fixed (+ t_enter, the ↵ in ms — #2238)' 'agent at attachments body id node prev repo t_enter title' \
  "$(printf '%s' "$pl" | python3 -c 'import json, sys; print(" ".join(sorted(json.load(sys.stdin))))')"
st_has 'F: node null by default (the hub picks)' "$pl" '"node": null'
st_has 'F: agent null by default (FLEET_AGENT)' "$pl" '"agent": null'
st_hasnt 'F: no 「记成 issue」 field' "$pl" '"issue"'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --repo acme/app --node m5host --agent codex)
st_has 'F: --repo names it' "$pl" '"repo": "acme/app"'
st_has 'F: --node names it' "$pl" '"node": "m5host"'
st_has 'F: --agent names it' "$pl" '"agent": "codex"'
pl=$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo)
st_has 'F: --no-repo: HOME is repo null' "$pl" '"repo": null'
st_has 'F: …with the whole text' "$pl" '附上截图'
st_eq 'F: one choice only' 2 "$(cd "$SB" && python3 fleet-compose.py payload "$WORK/t1" --no-repo --repo acme/app >/dev/null 2>&1; echo $?)"
st_eq 'E: the keymap row' 'new ⌘N 0x6e-0x100000 928 c' "$(bash "$SB/dash-keymap.sh" --panel switch list | awk '$1 == "new"')"

# O. (pure) fleet-history.sh drafts (issue #1955): its own conf dir and log
DC="$WORK/drafts"; CH="$DC/fleets/f/children"; mkdir -p "$CH"
now=$(date +%s); today=$(date +%Y-%m-%d); iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
yday=$(python3 -c 'import time; print(time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400)))')
ygen="$((now - 86400)).77"
{ printf '{"ts": "%s", "child": "r:issue-1", "state": "MERGED", "pfid": "P-hand", "gen": "%s.1"}\n' "$iso" "$now"
  printf '{"ts": "%s", "child": "r:issue-2", "state": "MERGED", "pfid": "P-hand", "gen": "%s.1"}\n' "$iso" "$now"
  printf '{"ts": "%s", "child": "r:issue-3", "state": "MERGED", "pfid": "P-old", "gen": "%s"}\n' "$iso" "$ygen"; } > "$CH/r:scratch-1.ndjson"
printf '{"ts": "%s", "child": "r:issue-4", "state": "MERGED", "pfid": "p-area"}\n' "$iso" > "$CH/r:scratch-2.ndjson"
printf '{"ts": "%s", "child": "r:issue-5", "state": "MERGED", "relayed_from": "r:issue-9"}\n' "$iso" > "$CH/r:scratch-3.ndjson"
printf '{"ts": "%s", "child": "r:issue-6", "state": "MERGED"}\n' "$iso" > "$CH/r:issue-50.ndjson"
printf '{"ts": "%s", "child": "r:issue-7", "state": "MERGED"}\n' "$iso" > "$CH/orchestrator.ndjson"
{ printf '{"ev": "sent", "id": "a", "at": %s}\n{"ev": "started", "id": "a", "secs": 10, "fid": "p-area"}\n' "$now"
  printf '{"ev": "sent", "id": "b", "at": %s}\n{"ev": "started", "id": "b", "secs": 30}\n' "$now"
  printf '{"ev": "sent", "id": "c", "at": %s}\n{"ev": "placed", "id": "c", "rc": 4}\n' "$now"; } > "$DC/compose.ndjson"
out=$(FLEET_CONF_DIR="$DC" FLEET_COMPOSE_LOG="$DC/compose.ndjson" bash "$BIN/fleet-history.sh" drafts --days 2)
st_eq 'O: today — one hand draft (the area'"'"'s, a relayed row, an issue and the orchestrator are not), 3 sends, 2 started, median 20s' \
  "$today	drafts=1	sends=3	started=2	start_median=20s" "$(printf '%s\n' "$out" | sed -n 1p)"
st_eq 'O: yesterday — the recycled number'"'"'s earlier generation, dated by its allocation' \
  "$yday	drafts=1	sends=0	started=0	start_median=-" "$(printf '%s\n' "$out" | sed -n 2p)"
st_has 'O: --json' "$(FLEET_CONF_DIR="$DC" FLEET_COMPOSE_LOG="$DC/compose.ndjson" bash "$BIN/fleet-history.sh" drafts --days 1 --json)" '"drafts": 1, "sends": 3'


# Q. (pure) the machine and the agent (issue #2232): a sandbox bin/ whose
# fleet-client-place.sh prints its argv (the body file's path masked)
QB="$WORK/q-bin"; mkdir -p "$QB"
for f in "$BIN"/*; do ln -sf "$f" "$QB/"; done
rm -f "$QB/fleet-client-place.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" | sed "s#--body-file [^ ]*#--body-file B#"\n' > "$QB/fleet-client-place.sh"
chmod +x "$QB/fleet-client-place.sh"
qsend() { printf '%s\n' "$1" > "$WORK/q.json"; shift
  FLEET_SWITCH_STATE="$WORK/q-state" FLEET_COMPOSE_LOG="$WORK/q.ndjson" python3 "$QB/fleet-compose.py" --send "$WORK/q.json" "$@" 2>&1; }
mkdir -p "$WORK/q-state"
st_eq 'Q: an older payload (no node, no agent) → --node auto, no --agent' \
  'acme/web new --title 看日志 --body-file B --node auto' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web"}')"
st_eq 'Q: node / agent null → the same argv' \
  'acme/web new --title 看日志 --body-file B --node auto' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":null,"agent":null}')"
st_eq 'Q: mac-a + codex → --node mac-a --agent codex' \
  'acme/web new --title 看日志 --body-file B --node mac-a --agent codex' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":"mac-a","agent":"codex"}')"
st_eq 'Q: a scratch of no repo carries them too' \
  '- scratch --name 看日志 --body-file B --node mac-a --agent codex' \
  "$(qsend '{"title":"看日志","body":"看日志","repo":null,"node":"mac-a","agent":"codex"}')"
st_eq 'Q: a named --node / --agent beats the payload'"'"'s' \
  'acme/web new --title 看日志 --body-file B --node mac-b --agent claude' \
  "$(qsend '{"title":"看日志","body":"看日志\n再看看","repo":"acme/web","node":"mac-a","agent":"codex"}' --node mac-b --agent claude)"
# issue #2393: the files themselves go with it — each attachment still on this
# computer as one --attach (a vanished one is not), so the place script sends
# its bytes to the machine that opens the session
st_eq 'Q: attachments → --attach each file still here' \
  "acme/web new --title 看图 --body-file B --attach $WORK/shot.png --node auto" \
  "$(qsend '{"title":"看图","body":"看图","repo":"acme/web","attachments":["'"$WORK"'/shot.png","'"$WORK"'/gone.png"]}')"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (10 * 1024 * 1024 + 1))' "$WORK/big.bin"
st_eq 'Q: over 10 MB is said before ↵ (too_big)' 'True False' "$(cd "$SB" && python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("c", "fleet-compose.py"); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.too_big(sys.argv[1]), m.too_big(sys.argv[2]))' "$WORK/big.bin" "$WORK/shot.png")"
out=$(qsend '{"title":"看日志","repo":"acme/web","agent":"gpt"}'); rc=$?
st_eq 'Q: an unknown agent is refused (2), nothing placed' '2|fleet-compose: agent is claude or codex, not gpt' "$rc|$out"
st_done
