#!/usr/bin/env bash
# fleet-session-cli-selftest.sh — `fleet ls | show | open | rename | close | reap |
# answer` (issue #2365, bin/fleet-session-cli.py): whatever the menu and ⌘P do,
# a command does, and a name that matches two sessions is refused, never guessed.
#
#   A  ls / ls --json        the rows: 名称 · 单号 · 机器 · Agent · 剩余 · 模型 ·
#                            Effort · 状态 · PR · 回收方式 — the bus columns (#2431)
#                            off the hub's session cache (fields 21-25): 剩余 with
#                            「(N 分钟前)」 past 5 minutes, — from an older node;
#                            coloured only on a terminal (green / amber / red / grey)
#   B  the ONE resolver      key · #单号 / 单号 · whole name · part of a name;
#                            none → exit 3, two → the candidates and exit 4
#   C  show                  every field of one row
#   D  rename / reap / answer  the hub write by worker_id (FLEET_SESSION_CLI_WRITE
#                            records it): worker_rename · worker_reap_policy (the
#                            policy canonical, a bad one refused before any write) ·
#                            worker_answer (no session named = the first waiting;
#                            y → yes); a refused write → exit 1 with why
#   E  close                 worker_reap through fleet_hub_reap (FLEET_HUB_WRITE_CMD
#                            fakes the hub): --yes, and no terminal without it → 2;
#                            E3 door 3 — only a `fleet login` certificate: a fake
#                            hub on 127.0.0.1 gets a worker_reap whose signature
#                            checks (issue #2506)
#   F  open                  `jump=<key>` on the client list's queue (an isolated
#                            server, TMUX naming it) — the list's own jump
#   G  the old roads         `fleet open <url|:port|file>` / `fleet show <file>`
#                            still pick fleet-open.sh / fleet-show.sh
#   H  bin/fleet → fleet-shell.sh cli   with no FLEET_SHELL the verb re-runs inside
#                            the client server's environment (an isolated `-L`
#                            server); no client → exit 1 with why
#
# tmux only on isolated sockets. Drives: bin/fleet, bin/fleet-session-cli.py,
# bin/fleet-shell.sh, bin/fleet-quickopen.py, bin/fleet-hub-write.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0 FAIL=0
eq() { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n  got  [%s]\n  want [%s]\n' "$1" "$3" "$2" >&2; fi; }
has() { CHECKS=$((CHECKS + 1)); case "$3" in *"$2"*) printf 'ok   %s\n' "$1" ;; *) FAIL=$((FAIL + 1)); printf 'FAIL %s\n  [%s] not in\n  [%s]\n' "$1" "$2" "$3" >&2 ;; esac; }

W=$(mktemp -d "${TMPDIR:-/tmp}/fsess-cli.XXXXXX") || exit 1
L="fsess-cli-$$"
cleanup() { tmux -S "$W/s" kill-server >/dev/null 2>&1; tmux -L "$L" kill-server >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_SWITCH_STATE="$W/state" FLEET_UI_LANG=zh
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$FLEET_SWITCH_STATE"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_SESSION

# three rows as the list writes them (switch-rows.tsv, fleet-quickopen.py rows_text)
T=$'\t'
{
  printf '%s\n' "wid:F/issue-12${T}needs${T}!${T}登录页重做${T}m4${T}acme/web (2)${T}${T}#12${T}#75✓${T}merged${T}登录页重做${T}acme/web"
  printf '%s\n' "wid:F/issue-13${T}working${T}●${T}登录页样式${T}m5${T}acme/web (2)${T}${T}#13${T}—${T}done:2h${T}${T}acme/web"
  printf '%s\n' "wid:F/scratch-3${T}idle${T}○${T}随便聊聊${T}m4${T}无仓库 (1)${T}${T}—${T}—${T}keep${T}${T}none"
} > "$W/rows.tsv"
cat > "$W/write" <<EOF
#!/bin/bash
printf '%s %s\n' "\$1" "\$2" >> "$W/writes"
case "\${FAKE_REFUSE:-}" in
  1) echo '{"operation_id":"op1","status":"failed","result":{"error":{"code":"no_window","message":"the session is gone"}}}' ;;
  *) echo '{"operation_id":"op1","status":"succeeded","result":{}}' ;;
esac
EOF
chmod +x "$W/write"
# the hub's session cache (fleet-hub-sessions.sh): fields 21-25 are the bus
# (#2431) — issue-12 fresh on Opus, issue-13 a Codex reading 8 minutes old,
# scratch-3 from a node too old to say (no 21-25)
NOW=1800000000
U=$(printf '\037')
{
  printf '#ts%s%s\n' "$U" "$NOW"
  printf '%s\n' "wid:F/issue-12${U}m4${U}online${U}12${U}acme/web${U}needs${U}claude${U}登录页重做${U}${U}${U}0${U}${U}hub${U}${U}${U}ok${U}${U}merged${U}${U}${U}62${U}ok${U}$((NOW - 20))${U}Opus 5.5${U}high"
  printf '%s\n' "wid:F/issue-13${U}m5${U}online${U}13${U}acme/web${U}working${U}codex:7_x${U}登录页样式${U}${U}${U}0${U}${U}hub${U}${U}${U}ok${U}${U}done:2h${U}${U}${U}47${U}watch${U}$((NOW - 485))${U}gpt-6-astra${U}medium"
  printf '%s\n' "wid:F/scratch-3${U}m4${U}online${U}${U}${U}idle${U}claude${U}随便聊聊${U}${U}${U}0${U}${U}hub${U}${U}${U}ok"
} > "$W/remote"
cli() { FLEET_SESSION_CLI_ROWS="$W/rows.tsv" FLEET_SESSION_CLI_WRITE="$W/write" FLEET_SESSION_CLI_CACHE="$W/remote" \
        FLEET_SESSION_CLI_NOW="$NOW" python3 "$BIN/fleet-session-cli.py" "$@"; }

# --- A. ls -----------------------------------------------------------------------
out=$(cli ls); rc=$?
eq "A ls exits 0" 0 "$rc"
eq "A ls: a header and three rows" 4 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
has "A ls header" "名称        单号  机器  Agent   剩余            模型         Effort  状态    PR    回收方式" "$out"
has "A ls row: 单号 · 机器 · Agent · 剩余 · 模型 · Effort · 状态 · PR · 回收方式" "登录页重做  #12   m4    Claude  62%             Opus 5.5     high    在问你  #75✓  merged" "$out"
has "A ls row: a stale Codex reading says how old; no PR (—) is blank" "登录页样式  #13   m5    Codex   47% (8 分钟前)  gpt-6-astra  medium  在干活        done:2h" "$out"
has "A ls row: an older node's session — for the bus" "随便聊聊          m4    Claude  —               —            —       空闲          keep" "$out"
case "$out" in *$'\033'*) eq "A ls: no colour off a terminal" none colour ;; *) eq "A ls: no colour off a terminal" none none ;; esac
# on a terminal: 剩余 coloured — green >50, amber 20–50, red <20 or handoff, grey stale
eq "A colours" "32 90 31 33 31" "$(FLEET_SESSION_CLI_NOW=$NOW python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cli", sys.argv[1] + "/fleet-session-cli.py")
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
ts = str(1800000000 - 10)
rows = [dict(left="62", band="ok", ts=ts), dict(left="47", band="watch", ts=str(1800000000 - 400)),
        dict(left="19", band="watch", ts=ts), dict(left="20", band="watch", ts=ts), dict(left="35", band="handoff", ts=ts)]
print(" ".join(cli.left_cell(r, True)[2:4] for r in rows))
PY
)"
eq "A ls --json" "wid:F/issue-12|12|#75✓|merged;wid:F/issue-13|13||done:2h;wid:F/scratch-3|||keep;" \
  "$(cli ls --json | python3 -c 'import json,sys; print("".join("%s|%s|%s|%s;" % (r["key"], r["issue"], r["pr"], r["reap"]) for r in json.load(sys.stdin)))')"
eq "A ls --json: the bus" "Claude|62|ok|Opus 5.5|high;Codex|47|watch|gpt-6-astra|medium;Claude||||;" \
  "$(cli ls --json | python3 -c 'import json,sys; print("".join("%s|%s|%s|%s|%s;" % (r["agent"], r["ctx_left"], r["ctx_band"], r["model"], r["effort"]) for r in json.load(sys.stdin)))')"
eq "A no cache at all: every row still listed, the bus —" 3 "$(FLEET_SESSION_CLI_ROWS="$W/rows.tsv" FLEET_SESSION_CLI_CACHE="" python3 "$BIN/fleet-session-cli.py" ls | grep -c '—')"

# --- B. the resolver -----------------------------------------------------------------
eq "B by key" "名称      随便聊聊" "$(cli show wid:F/scratch-3 | head -1)"
eq "B by #单号" "名称      登录页样式" "$(cli show '#13' | head -1)"
eq "B by 单号" "名称      登录页样式" "$(cli show 13 | head -1)"
eq "B by whole name (exact beats part)" "名称      登录页重做" "$(cli show 登录页重做 | head -1)"
eq "B by part of a name" "名称      随便聊聊" "$(cli show 聊聊 | head -1)"
err=$(cli show 登录页 2>&1 >/dev/null); rc=$?
eq "B two match → exit 4" 4 "$rc"
has "B …the candidates, never a guess" "登录页重做" "$err"
has "B …both of them" "登录页样式" "$err"
cli show 没有这个 >/dev/null 2>&1; eq "B none → exit 3" 3 "$?"
cli show '#99' >/dev/null 2>&1; eq "B an issue nobody holds → exit 3" 3 "$?"
cli show >/dev/null 2>&1; eq "B show with no session → usage, exit 2" 2 "$?"

# --- C. show -------------------------------------------------------------------------
out=$(cli show '#12')
has "C show: 机器" "机器      m4" "$out"
has "C show: PR" "PR        #75✓" "$out"
has "C show: 回收方式" "回收方式  merged" "$out"
has "C show: the key" "key       wid:F/issue-12" "$out"
has "C show: 剩余" "剩余      62%" "$out"
has "C show: 模型" "模型      Opus 5.5" "$out"

# --- D. rename / reap / answer ----------------------------------------------------------
: > "$W/writes"
out=$(cli rename 13 新 名字); rc=$?
eq "D rename exits 0" 0 "$rc"
eq "D rename → worker_rename by worker_id" 'worker_rename {"worker_id": "F/issue-13", "name": "新 名字"}' "$(tail -1 "$W/writes")"
has "D rename says so" "改名 登录页样式 → 新 名字：已完成" "$out"
cli reap 聊聊 done:1h >/dev/null; eq "D reap exits 0" 0 "$?"
eq "D reap → worker_reap_policy, canonical" 'worker_reap_policy {"worker_id": "F/scratch-3", "policy": "done:1h"}' "$(tail -1 "$W/writes")"
n=$(wc -l < "$W/writes")
cli reap 聊聊 sometimes >/dev/null 2>&1; eq "D a bad policy → exit 2" 2 "$?"
eq "D …and nothing was written" "$n" "$(wc -l < "$W/writes")"
cli answer '' 2 >/dev/null 2>&1; eq "D answer '' → no such session" 3 "$?"
cli answer </dev/null >/dev/null 2>&1; eq "D answer with no terminal and no answer → 2" 2 "$?"
cli answer '#12' y >/dev/null; eq "D answer exits 0" 0 "$?"
eq "D answer → worker_answer, y → yes" 'worker_answer {"worker_id": "F/issue-12", "answer": "yes"}' "$(tail -1 "$W/writes")"
err=$(FAKE_REFUSE=1 cli rename 13 x 2>&1 >/dev/null); rc=$?
eq "D a refused write → exit 1" 1 "$rc"
has "D …with the node's reason" "the session is gone" "$err"

# --- E. close -----------------------------------------------------------------------
cli close 聊聊 </dev/null >/dev/null 2>&1; eq "E close with no terminal and no --yes → 2" 2 "$?"
out=$(FLEET_HUB_WRITE_CMD='printf "%s\n" "$1" >> '"$W/reaps"'; echo "{\"operation_id\":\"op9\",\"status\":\"succeeded\",\"result\":{\"token\":\"reaped:full\"}}"' \
  cli close 聊聊 --yes 2>&1); rc=$?
eq "E close --yes exits 0" 0 "$rc"
has "E close says the token" "已回收 随便聊聊（reaped:full）" "$out"
eq "E …through worker_reap" worker_reap "$(cat "$W/reaps" 2>/dev/null)"
out=$(FLEET_HUB_WRITE_CMD='echo "{\"operation_id\":\"op9\",\"status\":\"failed\",\"result\":{\"error\":{\"token\":\"skip:live\",\"message\":\"it is working\"}}}"' \
  cli close 聊聊 --yes 2>&1); rc=$?
eq "E a reap the node skipped → exit 1" 1 "$rc"
has "E …and says which" "skip:live" "$out"

# E3: door 3 — no FLEET_HUB_WRITE_CMD, no viewer token, only a fleet login
# certificate: fleet-hub-write.sh signs the worker_reap itself (issue #2506 — its
# post_cert read $CERT_KEY that only a $(cert_state) subshell had set, so under
# set -u every certificate write died «CERT_KEY: unbound variable»). A fake hub on
# 127.0.0.1 records the request; the signature must check against the message.
if command -v ssh-keygen >/dev/null 2>&1; then
  mkdir -p "$W/cert"
  ssh-keygen -q -t ed25519 -N '' -C ca -f "$W/cert/ca" >/dev/null 2>&1
  ssh-keygen -q -t ed25519 -N '' -C me -f "$W/cert/key" >/dev/null 2>&1
  ssh-keygen -q -s "$W/cert/ca" -I me -n me -V -5m:+10m "$W/cert/key.pub" >/dev/null 2>&1
  python3 - "$W/hub" <<'PY2' &
import http.server, json, os, signal, sys
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
signal.alarm(60)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(os.path.join(d, "req"), "wb") as f: f.write(body)
        out = json.dumps({"operation_id": "op3", "status": "succeeded",
                          "result": {"token": "reaped:full"}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY2
  HUBPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$W/hub/port" ] && break; sleep 0.2; done
  out=$(CCQUOTA_HUB_URL="http://127.0.0.1:$(cat "$W/hub/port" 2>/dev/null)" FLEET_CERT="$W/cert/key" \
    cli close 聊聊 --yes 2>&1); rc=$?
  kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null
  eq "E3 close by certificate exits 0" 0 "$rc"
  has "E3 …says the token" "已回收 随便聊聊（reaped:full）" "$out"
  case "$out" in *unbound*) eq "E3 …no unbound variable" "" "$out" ;; esac
  eq "E3 the hub got a signed worker_reap for that worker" "worker_reap F/scratch-3 cert-ok" "$(python3 - "$W/hub/req" "$W/cert" <<'PY2'
import hashlib, json, subprocess, sys
try:
    r = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("no request"); sys.exit(0)
d = sys.argv[2]
open(d + "/sig", "w").write(r["sig"])
msg = "fleet-write %s %s %s" % (r["ts"], r["tool"], hashlib.sha256(r["args_json"].encode()).hexdigest())
ok = subprocess.run(["ssh-keygen", "-Y", "check-novalidate", "-n", "fleet-write@claude-fleet", "-s", d + "/sig"],
                    input=msg.encode(), capture_output=True).returncode == 0
cert = open(d + "/key-cert.pub").readline().strip() == r["cert"].strip()
print(r["tool"], json.loads(r["args_json"]).get("worker_id"), "cert-ok" if ok and cert else "cert-BAD")
PY2
)"
fi

# --- F. open --------------------------------------------------------------------------
if command -v tmux >/dev/null 2>&1; then
  tmux -S "$W/s" -f /dev/null new-session -d -s c -x 100 -y 20 'cat' && tmux -S "$W/s" split-window -d -t c: 'cat'
  LIST=$(tmux -S "$W/s" list-panes -t c: -F '#{pane_id}' | head -1)
  tmux -S "$W/s" set-option -p -t "$LIST" @sidebar 1
  pid=$(tmux -S "$W/s" display-message -p '#{pid}')
  out=$(TMUX="$W/s,$pid,0" cli open '#13'); rc=$?
  eq "F open exits 0" 0 "$rc"
  eq "F open → jump=<key> on the list's queue" "jump=wid:F/issue-13" "$(tmux -S "$W/s" show-options -pqv -t "$LIST" @sidebar_do | tr -d ' ')"
  tmux -S "$W/s" set-option -p -t "$LIST" @sidebar 0
  TMUX="$W/s,$pid,0" cli open '#13' >/dev/null 2>&1; eq "F no list on screen → exit 1" 1 "$?"
fi

# --- G. the old roads ----------------------------------------------------------------
: > "$W/afile"
eq "G the old roads" "fleet-open.sh fleet-open.sh fleet-open.sh fleet-show.sh None None" "$(cd "$W" && python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cli", sys.argv[1] + "/fleet-session-cli.py")
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)
print(cli.passthrough("open", ["https://x.example/a"]), cli.passthrough("open", [":5173/x"]),
      cli.passthrough("open", ["afile"]), cli.passthrough("show", ["afile"]),
      cli.passthrough("open", ["#12"]), cli.passthrough("show", ["登录页"]))
PY
)"

# --- H. through bin/fleet and the client server's environment ---------------------------
err=$(FLEET_SHELL_SESSION="$L" bash "$BIN/fleet" ls 2>&1 >/dev/null); rc=$?
eq "H no client running → exit 1" 1 "$rc"
has "H …and why" "客户端没在运行" "$err"
if command -v tmux >/dev/null 2>&1; then
  tmux -L "$L" -f /dev/null new-session -d -s "$L" 'cat'
  tmux -L "$L" set-environment -g FLEET_SESSION_CLI_ROWS "$W/rows.tsv"
  out=$(FLEET_SHELL_SESSION="$L" bash "$BIN/fleet" ls 2>&1); rc=$?
  eq "H bin/fleet ls → fleet-shell.sh cli → the rows, exit 0" 0 "$rc"
  has "H …read in the server's environment" "随便聊聊" "$out"
  has "H …with its state" "空闲" "$out"
  FLEET_SHELL_SESSION="$L" bash "$BIN/fleet" show 登录页 >/dev/null 2>&1
  eq "H …and its exit code (ambiguous → 4)" 4 "$?"
fi

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-session-cli selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'fleet-session-cli selftest: PASS (%d checks)\n' "$CHECKS"
