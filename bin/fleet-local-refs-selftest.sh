#!/bin/bash
# fleet-local-refs-selftest.sh — the local files a task's words name travel with
# it (T793): bin/fleet_local_refs.py, as fleet-task-record.sh dispatch and
# fleet-epic-tick.py call it.
#   A. a ~/… text file is carried once, verbatim, under its marker; `$HOME/…`
#      and the absolute /Users-style spelling too
#   B. what is never carried: a script, a dot path (~/.ssh …), a file inside a
#      git checkout, a directory — left alone, nothing said
#   C. a named text file not here / too big is listed (`uncarried … · why`) and
#      the body says so in one line
#   D. a body naming nothing passes byte for byte; FLEET_CARRY_LOCAL=0 is off
#   E. --from: a block another text carried is taken as read (the driver on
#      another machine than the plan); an already-carried path is not re-carried
#   F. fleet-task-record.sh dispatch carries before it posts (stub hub)
# Hermetic: a sandbox HOME (files only — nothing here signals or starts a service).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/local-refs.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT
WORK=$(cd "$WORK" && pwd -P)
N=0 BAD=0
ok()  { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$3] should not be in [$2]" ;; *) ok ;; esac; }

H="$WORK/home"
mkdir -p "$H/fleet-drafts/t696/members" "$H/.ssh" "$H/projects/repo/.git" "$H/projects/repo/docs"
printf '共同约定：不改 conf 格式。\n' > "$H/fleet-drafts/t696/sections.md"
printf 'C3 的细节：改 fleet-lib.sh。\n' > "$H/fleet-drafts/t696/members/C3.md"
printf 'secret\n' > "$H/.ssh/notes.md"
printf 'repo doc\n' > "$H/projects/repo/docs/x.md"
printf '#!/bin/sh\n' > "$H/fleet-drafts/run.sh"
python3 -c 'print("长" * 6000)' > "$H/fleet-drafts/big.md"
carry() { HOME="$H" python3 "$BIN/fleet_local_refs.py" carry "$@" 2>"$WORK/err"; }

# --- A. carried ----------------------------------------------------------------
out=$(printf '细节（必读）~/fleet-drafts/t696/members/C3.md。共同约定见 ~/fleet-drafts/t696/sections.md，再看一次 ~/fleet-drafts/t696/sections.md\n' | carry)
has "A: the member file is carried" "$out" "C3 的细节：改 fleet-lib.sh。"
has "A: the shared file is carried" "$out" "共同约定：不改 conf 格式。"
has "A: under its marker" "$out" "<!-- fleet:carried ~/fleet-drafts/t696/sections.md -->"
eq "A: once, though named twice" 1 "$(printf '%s' "$out" | grep -c 'fleet:carried ~/fleet-drafts/t696/sections.md')"
eq "A: nothing said" "" "$(cat "$WORK/err")"
out=$(printf 'see $HOME/fleet-drafts/t696/sections.md and %s/fleet-drafts/t696/members/C3.md\n' "$H" | carry)
has "A: \$HOME/… is carried" "$out" "<!-- fleet:carried \$HOME/fleet-drafts/t696/sections.md -->"
case "$H" in
  /Users/*|/home/*) has "A: the absolute spelling is carried" "$out" "C3 的细节" ;;
  *) ok ;;   # a sandbox outside /Users|/home: the ~ spellings above are the leg
esac

# --- B. never carried ------------------------------------------------------------
in='跑 ~/fleet-drafts/run.sh；~/.ssh/notes.md；~/projects/repo/docs/x.md；目录 ~/fleet-drafts/t696/members/'
out=$(printf '%s\n' "$in" | carry)
eq "B: untouched" "$in" "$out"
eq "B: nothing said" "" "$(cat "$WORK/err")"
hasnt "B: a dot path is never read" "$out" "secret"

# --- C. not here / too big --------------------------------------------------------
out=$(printf '细节 ~/fleet-drafts/t696/members/C9.md，大的 ~/fleet-drafts/big.md\n' | carry)
has "C: the missing file is said" "$(cat "$WORK/err")" "uncarried ~/fleet-drafts/t696/members/C9.md · 不在这台机器"
has "C: the big file is said" "$(cat "$WORK/err")" "uncarried ~/fleet-drafts/big.md · 放不下"
has "C: the body says so" "$out" "没能随单带上"
hasnt "C: the big file is not half-carried" "$out" "fleet:carried ~/fleet-drafts/big.md"
out=$(printf 'x /Users/someoneelse/fleet-drafts/a.md\n' | carry)
has "C: another home's file is not here" "$(cat "$WORK/err")" "不在这台机器"

# --- D. pass-through ---------------------------------------------------------------
in=$'没有路径的一段话。\n第二行'
eq "D: byte for byte" "$in" "$(printf '%s' "$in" | carry)"
out=$(printf '~/fleet-drafts/t696/sections.md\n' | FLEET_CARRY_LOCAL=0 carry)
eq "D: off is off" "~/fleet-drafts/t696/sections.md" "$out"

# --- E. --from + re-carry ------------------------------------------------------------
printf '章程 ~/fleet-drafts/t696/sections.md\n' | carry > "$WORK/charter"
mv "$H/fleet-drafts" "$WORK/gone"
out=$(printf '共同约定见 ~/fleet-drafts/t696/sections.md\n' | carry --from "$WORK/charter")
has "E: taken off the charter's copy" "$out" "共同约定：不改 conf 格式。"
eq "E: nothing said" "" "$(cat "$WORK/err")"
again=$(printf '%s\n' "$out" | carry)
eq "E: a carried path is not carried again" "$out" "$again"
mv "$WORK/gone" "$H/fleet-drafts"

# --- F. dispatch carries ---------------------------------------------------------------
mkdir -p "$WORK/conf"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n' > "$WORK/conf/node.env"
cat > "$WORK/hub" <<'PY'
#!/usr/bin/env python3
import json, os, sys
sys.stdin.read()
args = sys.argv[1:]
body = args[args.index("--data-binary") + 1] if "--data-binary" in args else ""
if body:
    open(os.environ["POSTED"], "w").write(body)
    req = json.loads(body)
    print(json.dumps(dict(id="T1", authority_version=1, generation=1, attempt_id="a", title=req["title"],
                          requested_agent=req["requested_agent"], resolved_agent=req["resolved_agent"])))
    print(200)
else:
    print("{}"); print(404)
PY
chmod +x "$WORK/hub"
printf '细节（必读）~/fleet-drafts/t696/members/C3.md 和 ~/fleet-drafts/t696/members/C8.md\n' > "$WORK/body"
HOME="$H" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_HUB_CURL="$WORK/hub" POSTED="$WORK/posted" \
  FLEET_AGENT=claude TMUX='' TMUX_PANE='' \
  bash "$BIN/fleet-task-record.sh" dispatch --title "C3 · 演示" --body-file "$WORK/body" >/dev/null 2>"$WORK/derr"
posted=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_payload"]["body"])' "$WORK/posted" 2>/dev/null)
has "F: the posted body carries the file" "$posted" "C3 的细节：改 fleet-lib.sh。"
has "F: the missing one is said on stderr" "$(cat "$WORK/derr")" "~/fleet-drafts/t696/members/C8.md · 不在这台机器"

printf 'fleet-local-refs-selftest: %d checks, %d failed\n' "$N" "$BAD"
[ "$BAD" = 0 ]
