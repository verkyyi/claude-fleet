#!/bin/bash
# gh-blackhole-selftest.sh — the GitHub black-hole drill, sandbox half (issue
# #4840, EPIC #4839 C1). GitHub has gone down a few times and each time all we
# knew was «a lot of things spin». This drill cuts GitHub off three ways and runs
# every row of conf/gh-blackhole.rows (the EPIC's 演练清单 1–12 + G1–G3) in a
# sandbox fleet, and prints, per row and way: what it did, how long it took and
# how many times it went looking for GitHub — the EPIC's first reading.
#
#   bin/gh-blackhole-selftest.sh [--mode dns|hang|limit]… [--rows 1,4,G2]
#                                [--cap S] [--jobs N] [--tsv <file>] [--record]
#
# The three ways (each a local stand-in, nothing leaves the machine):
#   dns    域名解析失败 — every connection to GitHub fails at once (the proxy answers
#          502, which is what a failed lookup / a refused connection is to a caller)
#   hang   连上不回 — a proxy that takes the connection and never answers
#   limit  额度用尽 — FLEET_GH_FAKE_LIMIT=all, and gh says the rate limit is spent
# Every row runs with HTTPS_PROXY / HTTP_PROXY / ALL_PROXY at bin/gh_blackhole.py's
# proxy (NO_PROXY lets 127.0.0.1 and localhost — a hub — through), on its own
# ports: one for gh, one for the rest (git, curl), so a row's tries are its own.
# `gh` is a stand-in that counts each call and then runs the REAL gh against the
# black hole (GH_TOKEN a dummy, its own config dir) — gh's own behaviour is the
# thing measured; with no gh installed it plays what gh 2.101 was measured doing
# (one request: 60 s then «context deadline exceeded» under hang, at once
# otherwise). Under limit it answers gh's rate-limit refusal itself.
#
# Each row is cut at --cap seconds (20; the whole process group goes) and judged
#   ok exit 0 · fail exit ≠ 0 · hang cut at the cap · skip not runnable here
# against its 期望 in conf/gh-blackhole.rows: anything else is red — a fix flips
# the row's 期望 (hang → ok), so the count of rows that work only goes up. Time is
# measured, not matched (a busy runner must not turn a row red): a row done after
# 15 s says `>15s` in its note and does not count as working in the metric.
# --record prints the 期望 field each row would need instead of judging.
#
# Output: the table (TSV, fixed columns `row mode result secs gh_tries note`,
# gh_tries = gh calls + other GitHub connections, note = `cli=N net=M rc=R` and
# the row's first stderr line), then the EPIC's metric line:
#   核心照常 X/12 · G 行不卡 Y/3 · 卡住 Z 格 · GitHub 尝试 T 次
#
# Hermetic: a sandbox HOME / FLEET_CONF_DIR / TMPDIR per row, a fake tmux (no
# server), no hub, every listener on 127.0.0.1, all leftovers killed with their row.
#
# Drives: bin/gh_blackhole.py, conf/gh-blackhole.rows, bin/fleet-install-sync.sh,
# bin/fleet-claim-brief.sh, bin/fleet-gh.sh, bin/fleet-report-parent.sh,
# bin/fleet-comment.sh, bin/session-end-hook.sh, bin/tmux-issue-preview.sh,
# bin/fleet-history.sh, bin/fleet-codex.sh, bin/fleet-pr-verdict.sh,
# bin/fleet-issue-file.sh, bin/fleet-gh-lib.sh, bin/fleet-lib.sh,
# tokenledger/internal/api/fleet_join.go (the join line's script URL).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
ROWS="${GHBH_ROWS:-$ROOT/conf/gh-blackhole.rows}"
MODES='' PICK='' CAP=20 BUDGET=15 JOBS=6 TSV='' RECORD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODES="$MODES ${2:-}"; shift 2 ;;
    --rows) PICK=",${2:-},"; shift 2 ;;
    --cap) CAP=${2:-20}; shift 2 ;;
    --jobs) JOBS=${2:-6}; shift 2 ;;
    --tsv) TSV=${2:-}; shift 2 ;;
    --record) RECORD=1; shift ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'gh-blackhole: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$MODES" ] || MODES='dns hang limit'
for m in $MODES; do case "$m" in dns|hang|limit) ;; *) printf 'gh-blackhole: no mode %s\n' "$m" >&2; exit 2 ;; esac; done
[ -f "$ROWS" ] || { printf 'gh-blackhole: %s missing\n' "$ROWS" >&2; exit 2; }
for c in git python3 curl; do
  command -v "$c" >/dev/null 2>&1 || { printf 'gh-blackhole: %s not installed — SKIP\n' "$c"; exit 0; }
done

# Nothing of the caller's fleet comes along (a pane's binding, a hub URL, a token).
for v in $(compgen -e | grep -E '^(FLEET_|CCQUOTA_|GH_|GITHUB_)'); do unset "$v"; done
unset TMUX TMUX_PANE HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy NO_PROXY no_proxy
REAL_GH=''
for g in $(type -ap gh 2>/dev/null); do REAL_GH=$g; break; done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-blackhole.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
PROXIES=''
cleanup() {
  local p
  for p in $PROXIES; do kill "$p" 2>/dev/null; done
  [ -n "${GHBH_KEEP:-}" ] && { printf 'gh-blackhole: kept %s\n' "$WORK" >&2; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

SESS=drill REPO=fleet-drill/blackhole ISSUE=7 PR=8
JOIN_URL=$(sed -n 's/^const DefaultJoinScriptURL = "\(.*\)"$/\1/p' "$ROOT/tokenledger/internal/api/fleet_join.go" 2>/dev/null | head -1)
[ -n "$JOIN_URL" ] || JOIN_URL='https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-node-join.sh'

# ---- the stand-ins, shared by every row (they read the row's env) -------------
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
# the drill's gh: count the call, then the real gh behind the black hole
c=${GHBH_CELL:?}
case "${1:-} ${2:-}" in
  '--version '*|'version '*) echo 'gh version 2.101.0 (drill)'; exit 0 ;;
  'auth token') echo 'gho_drill'; exit 0 ;;          # local: gh reads its own config
esac
printf '%s\n' "$*" >> "$c/gh.calls"
if [ "$GHBH_MODE" = limit ]; then
  case "${1:-}" in
    api) echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2 ;;
    *)   echo 'GraphQL: API rate limit already exceeded for user ID 1.' >&2 ;;
  esac
  exit 1
fi
if [ -n "${GHBH_REAL_GH:-}" ]; then
  mkdir -p "$c/ghcfg"
  exec env -u GITHUB_TOKEN GH_TOKEN=gho_drill GH_CONFIG_DIR="$c/ghcfg" GH_NO_UPDATE_NOTIFIER=1 \
    GH_PROMPT_DISABLED=1 HTTPS_PROXY="http://127.0.0.1:$GHBH_GH_PORT" HTTP_PROXY="http://127.0.0.1:$GHBH_GH_PORT" \
    "$GHBH_REAL_GH" "$@"
fi
if [ "$GHBH_MODE" = hang ]; then sleep 60; echo 'Get "https://api.github.com/": context deadline exceeded' >&2; exit 1; fi
echo 'Post "https://api.github.com/graphql": Bad Gateway' >&2; exit 1
EOF
cat > "$STUB/tmux" <<'EOF'
#!/bin/bash
# no tmux server: a display-message answers this pane's binding (every #{…} it
# does not know is empty), everything else does nothing
while [ $# -gt 0 ]; do case "$1" in -L|-S) shift 2 ;; *) break ;; esac; done
case "${1:-}" in
  display-message|display) eval "f=\${$#}"
    exec python3 -I -c 'import os, re, sys
v = {"@issue": os.environ["GHBH_ISSUE"], "@repo": os.environ["GHBH_REPO"],
     "pane_current_path": os.environ["GHBH_CELL"] + "/blackhole-issue-" + os.environ["GHBH_ISSUE"], "session_name": os.environ["GHBH_SESS"],
     "session_group": "", "window_id": "@1", "pane_id": "%1", "window_name": "issue-" + os.environ["GHBH_ISSUE"],
     "@origin": "1b4e28ba-2fa1-41d2-883f-0016d3cca427", "@fleet_role": "worker", "@worktree": os.environ["GHBH_CELL"] + "/blackhole-issue-" + os.environ["GHBH_ISSUE"]}
f = sys.argv[1]
f = re.sub(r"#\{\?#\{session_group\},#\{session_group\},#\{session_name\}\}", v["session_name"], f)
print(re.sub(r"#\{([^}]*)\}", lambda m: v.get(m.group(1), ""), f))' "$f" ;;
esac
exit 0
EOF
cat > "$STUB/codex" <<'EOF'
#!/bin/bash
# Codex's own start: unless plugins are off it syncs its plugin marketplace from GitHub
case " $* " in *features.plugins=false*) exit 0 ;; esac
git ls-remote https://github.com/openai/plugins.git HEAD >/dev/null 2>&1
exit 0
EOF
chmod +x "$STUB/gh" "$STUB/tmux" "$STUB/codex"

# ---- one row's sandbox: a fleet conf, a checkout + worktree issue-7 -----------
mkcell() {  # mkcell <dir>
  local c=$1 gargs=(-c user.email=drill@example.invalid -c user.name=drill -c init.defaultBranch=master)
  mkdir -p "$c/home" "$c/conf/fleets/$SESS" "$c/tmp" "$c/nodestate"
  git "${gargs[@]}" init -q "$c/main" && git -C "$c/main" "${gargs[@]}" commit -q --allow-empty -m base &&
    git -C "$c/main" remote add origin "https://github.com/$REPO.git" &&
    git -C "$c/main" worktree add -q -b "issue-$ISSUE" "$c/blackhole-issue-$ISSUE" &&
    git -C "$c/blackhole-issue-$ISSUE" "${gargs[@]}" commit -q --allow-empty -m "drill: work" || return 1
  # the install a no-hub login follows: a checkout of the public repo
  git "${gargs[@]}" init -q "$c/install" && git -C "$c/install" "${gargs[@]}" commit -q --allow-empty -m install &&
    git -C "$c/install" remote add origin "https://github.com/$REPO.git" || return 1
  cat > "$c/conf/fleets/$SESS/conf" <<CONF
FLEET_REPO=$REPO
FLEET_MAIN=$c/main
FLEET_BASE_BRANCH=master
FLEET_FORGE=github
CONF
}

# ---- the rows ------------------------------------------------------------------
IDS=() NAMES=() CMDS=() EXPS=()
while IFS=$'\t' read -r id name cmd exp; do
  case "$id" in ''|'#'*) continue ;; esac
  [ -n "$exp" ] || { printf 'gh-blackhole: row %s has no 期望 (want 4 TAB fields)\n' "$id" >&2; exit 2; }
  [ -z "$PICK" ] || case "$PICK" in *",$id,"*) ;; *) continue ;; esac
  IDS+=("$id"); NAMES+=("$name"); CMDS+=("$cmd"); EXPS+=("$exp")
done < "$ROWS"
N=${#IDS[@]}
[ "$N" -gt 0 ] || { printf 'gh-blackhole: no rows picked\n' >&2; exit 2; }

START=$(date +%s)
for m in $MODES; do
  mkdir -p "$WORK/$m"
  python3 -I "$BIN/gh_blackhole.py" proxy --mode "$( [ "$m" = dns ] && echo refuse || echo "$m")" \
    --ports $((N * 2)) --portfile "$WORK/$m/ports" --log "$WORK/$m/proxy.log" &
  PROXIES="$PROXIES $!"
done
for m in $MODES; do
  i=0; while [ ! -s "$WORK/$m/ports" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$WORK/$m/ports" ] || { printf 'gh-blackhole: the %s proxy never bound\n' "$m" >&2; exit 2; }
done

runcell() {  # runcell <mode> <index>
  local m=$1 i=$2 c="$WORK/$1/${IDS[$2]}" gp np cmd
  gp=$(sed -n "$((i * 2 + 1))p" "$WORK/$m/ports"); np=$(sed -n "$((i * 2 + 2))p" "$WORK/$m/ports")
  cmd=${CMDS[$i]}
  case "$cmd" in '- '*|-) printf 'skip\t0.0\t-\n' > "$c/verdict"; return ;; esac
  (
    cd "$c/blackhole-issue-$ISSUE" || exit 1
    export HOME="$c/home" FLEET_CONF_DIR="$c/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$c/tmp"
    export XDG_CONFIG_HOME="$c/home/.config" XDG_CACHE_HOME="$c/home/.cache"
    export PATH="$STUB:$PATH" TMUX_PANE=%1 TMUX="$c/tmux.sock,1,0" FLEET_SESSION="$SESS"
    export GHBH_CELL="$c" GHBH_MODE="$m" GHBH_GH_PORT="$gp" GHBH_REAL_GH="$REAL_GH"
    export GHBH_ISSUE="$ISSUE" GHBH_REPO="$REPO" GHBH_SESS="$SESS"
    export HTTPS_PROXY="http://127.0.0.1:$np" HTTP_PROXY="http://127.0.0.1:$np" ALL_PROXY="http://127.0.0.1:$np"
    export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY" all_proxy="$ALL_PROXY"
    export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost GIT_TERMINAL_PROMPT=0
    export FLEET_GH_WRITE_GAP=0 FLEET_NODE_STATE="$c/nodestate" BIN REPO ISSUE PR CELL="$c" SESS JOIN_URL
    [ "$m" = limit ] && export FLEET_GH_FAKE_LIMIT=all
    exec python3 -I "$BIN/gh_blackhole.py" cell --cap "$CAP" --out "$c/verdict" \
      -- bash -c "$cmd" > "$c/out" 2> "$c/err"
  )
}

# build every cell, then run them JOBS at a time (bash 3.2 has no `wait -n`)
for m in $MODES; do
  i=0; while [ "$i" -lt "$N" ]; do
    mkcell "$WORK/$m/${IDS[$i]}" || { printf 'gh-blackhole: could not build the %s/%s sandbox\n' "$m" "${IDS[$i]}" >&2; exit 2; }
    i=$((i + 1))
  done
done
for m in $MODES; do
  i=0; while [ "$i" -lt "$N" ]; do
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$((JOBS + $(printf "%s\n" $MODES | wc -l)))" ]; do sleep 0.2; done
    runcell "$m" "$i" &
    i=$((i + 1))
  done
done
# wait for the cells, not the proxies (they run until killed)
for p in $(jobs -rp); do case " $PROXIES " in *" $p "*) ;; *) wait "$p" ;; esac; done

# A row its 期望 says finishes, cut at the cap: a busy runner, or real? Once more,
# alone, in a fresh sandbox — what it does then is its reading (note: retried).
RETRIED=' '
i=0; while [ "$i" -lt "$N" ]; do
  for m in $MODES; do
    c="$WORK/$m/${IDS[$i]}"
    [ "$(cut -f1 "$c/verdict" 2>/dev/null)" = hang ] || continue
    case " ${EXPS[$i]} " in *" $m=hang "*|*" $m=skip "*) continue ;; esac
    rm -rf "$c"; mkcell "$c" || continue
    python3 -I "$BIN/gh_blackhole.py" count --log "$WORK/$m/proxy.log" \
      --port "$(sed -n "$((i * 2 + 2))p" "$WORK/$m/ports")" > "$c/netbase"
    runcell "$m" "$i"
    RETRIED="$RETRIED$m/${IDS[$i]} "
  done
  i=$((i + 1))
done

# ---- the table -----------------------------------------------------------------
OUT="$WORK/table.tsv"
printf 'row\tmode\tresult\tsecs\tgh_tries\tnote\n' > "$OUT"
BAD=0 HANGS=0 TRIES=0
i=0; while [ "$i" -lt "$N" ]; do
  want=''
  for m in $MODES; do
    c="$WORK/$m/${IDS[$i]}"
    IFS=$'\t' read -r res secs rc < "$c/verdict" 2>/dev/null || { res=error secs=0 rc=-; }
    cli=0; [ -f "$c/gh.calls" ] && cli=$(wc -l < "$c/gh.calls" | tr -d ' ')
    np=$(sed -n "$((i * 2 + 2))p" "$WORK/$m/ports")
    net=$(python3 -I "$BIN/gh_blackhole.py" count --log "$WORK/$m/proxy.log" --port "$np")
    [ -s "$c/netbase" ] && net=$((net - $(cat "$c/netbase")))
    tries=$((cli + net)); TRIES=$((TRIES + tries))
    [ "$res" = hang ] && HANGS=$((HANGS + 1))
    first=$(grep -v '^[[:space:]]*$' "$c/err" 2>/dev/null | head -1 | tr '\t' ' ' | cut -c1-120)
    rt=''; case "$RETRIED" in *" $m/${IDS[$i]} "*) rt=' retried' ;; esac
    late=''; [ "$res" != hang ] && awk -v s="$secs" -v b="$BUDGET" 'BEGIN { exit !(s > b) }' && late=' >15s'
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${IDS[$i]}" "$m" "$res" "$secs" "$tries" "cli=$cli net=$net rc=$rc$late$rt${first:+ · $first}" >> "$OUT"
    want="$want $m=$res"
    printf '%s %s\n' "${IDS[$i]}" "$m=$res${late:+-late}" >> "$WORK/results"
    exp=" ${EXPS[$i]} "
    case "$exp" in
      *" $m="*) case "$exp" in *" $m=$res "*) ;; *) BAD=$((BAD + 1)); printf 'MISMATCH %s %s: 期望 %s, got %s\n' "${IDS[$i]}" "$m" \
                   "$(printf '%s' "$exp" | tr ' ' '\n' | sed -n "s/^$m=//p")" "$res" >> "$WORK/mismatch" ;; esac ;;
      *) BAD=$((BAD + 1)); printf 'MISMATCH %s %s: no 期望 for this way\n' "${IDS[$i]}" "$m" >> "$WORK/mismatch" ;;
    esac
  done
  [ "$RECORD" = 1 ] && printf 'record\t%s\t%s\n' "${IDS[$i]}" "${want# }" >> "$WORK/record"
  i=$((i + 1))
done

if command -v column >/dev/null 2>&1; then column -t -s $'\t' < "$OUT"; else cat "$OUT"; fi
[ -n "$TSV" ] && cp "$OUT" "$TSV"

# the metric: a core row passes only in every way; a G row only by never hanging
core=0 corerun=0 g=0 grun=0
i=0; while [ "$i" -lt "$N" ]; do
  r=$(sed -n "s/^${IDS[$i]} //p" "$WORK/results" | tr '\n' ' ')
  case "${IDS[$i]}" in
    G*) grun=$((grun + 1)); case "$r" in *=hang*|*-late*|*=skip*|*=error*) ;; *) g=$((g + 1)) ;; esac ;;
    *)  corerun=$((corerun + 1)); case "$r" in *=fail*|*=hang*|*-late*|*=skip*|*=error*) ;; *) core=$((core + 1)) ;; esac ;;
  esac
  i=$((i + 1))
done
printf '\n核心照常 %s/%s · G 行不卡 %s/%s · 卡住 %s 格 · GitHub 尝试 %s 次 · 挡法 %s · %ss\n' \
  "$core" "$corerun" "$g" "$grun" "$HANGS" "$TRIES" "$(printf "%s," $MODES | sed "s/,$//")" "$(( $(date +%s) - START ))"

# 写丢的认领 / 评论 / 证据 (the EPIC's metric): row 7's writes, made while GitHub
# is cut off. Nothing reaches GitHub during the drill, so a write is kept only if
# it waits in the retry queue ($FLEET_CONF_DIR/gh-outbox, EPIC #4839 C5); the
# rest are lost — `报了成功` counts the ones whose command still exited 0.
for m in $MODES; do
  c="$WORK/$m/7"; [ -s "$c/writes" ] || continue
  w=$(wc -l < "$c/writes" | tr -d ' ')
  said=0; [ -f "$c/writes.lost" ] && said=$(wc -l < "$c/writes.lost" | tr -d ' ')
  q=0; [ -d "$c/conf/gh-outbox" ] && q=$(find "$c/conf/gh-outbox" -type f | wc -l | tr -d ' ')
  [ "$q" -gt "$w" ] && q=$w
  silent=$((w - said - q)); [ "$silent" -lt 0 ] && silent=0
  note=''
  [ "$(cut -f1 "$c/verdict" 2>/dev/null)" = hang ] && { silent=0; note=' (cut at the cap: the write in flight and the rest never ran)'; }
  printf '写丢（%s）%s/%s · 记下待补 %s · 报了成功却没写上 %s%s\n' "$m" "$((w - q))" "$w" "$q" "$silent" "$note"
done

case " $PICK ${IDS[*]-} " in *" 3 "*|*,3,*) printf '登不进入口的人：入口侧（row 3），沙箱读不了 — 现场版读入口库里只挂 GitHub 一种登录的人数\n' ;; esac

if [ "$RECORD" = 1 ]; then
  printf '\n期望 to write in %s:\n' "$ROWS"; cut -f2- "$WORK/record"
  exit 0
fi
if [ "$BAD" -gt 0 ]; then
  printf '\nFAIL %s cell(s) differ from conf/gh-blackhole.rows — a row that now works: flip its 期望 there;\n' "$BAD"
  printf 'a row that got worse is a regression.\n'
  cat "$WORK/mismatch"
  i=0; while [ "$i" -lt "$N" ]; do
    for m in $MODES; do
      grep -q "^MISMATCH ${IDS[$i]} $m:" "$WORK/mismatch" || continue
      printf -- '--- %s %s stderr (last 8)\n' "${IDS[$i]}" "$m"; tail -n 8 "$WORK/$m/${IDS[$i]}/err" 2>/dev/null
    done
    i=$((i + 1))
  done
  exit 1
fi
printf 'PASS every cell as conf/gh-blackhole.rows says\n'
