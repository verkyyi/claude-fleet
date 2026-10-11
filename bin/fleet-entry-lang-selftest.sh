#!/bin/bash
# fleet-entry-lang-selftest.sh — the entry door keeps the language the CLIENT
# brought, before it fills a locale in (issue #3326, EPIC #3178 第二轮 ③).
#
# bin/fleet-entry.sh runs here directly (no sshd): a terminal arrival under a pty,
# the 看台 a stand-in (FLEET_ENTRY_VIEW) that writes down the FLEET_CLIENT_LANG it
# was handed — attach --thin records exactly that as @view_lang
# (fleet-remote-view-thin-selftest.sh G) — and entry.ndjson's `client_lang`.
#   A. LANG=en_US.UTF-8          ⇒ en_US.UTF-8
#   B. no LANG / LC_*            ⇒ empty — not the en_US / C.UTF-8 the door fills in
#   C. LC_ALL wins over LANG; LC_MESSAGES over LANG; LC_CTYPE is no language
#   D. C / POSIX / C.UTF-8       ⇒ empty
#   E. a command (exec) arrival  ⇒ its ndjson line carries client_lang too
#   F. the door's welcome (issue #3329, L4), on the terminal before the 看台: no LANG
#      ⇒ 中文; en_US ⇒ English; the person chose zh (person-bundle.json ui_lang) ⇒
#      中文 whatever the client says; a command arrival prints none
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-entry-lang selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fel-st.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }

# the 看台 stand-in: what it was handed, one line
cat > "$WORK/view.sh" <<'EOF'
printf 'lang=[%s] set=%s LANG=%s LC_ALL=%s\n' "${FLEET_CLIENT_LANG-}" "${FLEET_CLIENT_LANG+1}" "${LANG-}" "${LC_ALL-}" \
  >> "$(dirname "$0")/view.out"
exit 0
EOF

# arrive [VAR=val …] — a terminal arrival, no command: the 看台 path
arrive() {
  : > "$WORK/view.out"
  rm -rf "$WORK/conf"
  [ -z "${PERSON:-}" ] || { mkdir -p "$WORK/conf"; printf '%s' "$PERSON" > "$WORK/conf/person-bundle.json"; }
  env -i HOME="$WORK" PATH="$PATH" SHELL=/bin/sh SSH_TTY=/dev/tty SSH_CONNECTION='10.0.0.9 5 10.0.0.1 22022' \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ENTRY_VIEW="$WORK/view.sh" "$@" \
    python3 -c '
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", sys.argv[1]])
got = b""
while True:
    try:
        b = os.read(fd, 4096)
        if not b: break
        got += b
    except OSError: break
_, st = os.waitpid(pid, 0)
open(sys.argv[2], "wb").write(got)
' "$BIN/fleet-entry.sh" "$WORK/tty.out"
}
seen() { sed -n 's/^lang=\[\(.*\)\] set=.*/\1/p' "$WORK/view.out"; }
logged() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1]).get("client_lang","<none>"))' "$WORK/conf/logs/entry.ndjson" 2>/dev/null; }

arrive LANG=en_US.UTF-8
eq "A: LANG=en_US.UTF-8 ⇒ handed to the 看台" "en_US.UTF-8" "$(seen)"
eq "A: … entry.ndjson's client_lang" "en_US.UTF-8" "$(logged)"

arrive
eq "B: no LANG ⇒ empty, not the door's fill" "" "$(seen)"
eq "B: … still set (the 看台 records none)" "1" "$(sed -n 's/.* set=\([^ ]*\) .*/\1/p' "$WORK/view.out")"
eq "B: … entry.ndjson's client_lang empty" "" "$(logged)"

arrive LANG=en_US.UTF-8 LC_ALL=zh_CN.UTF-8
eq "C: LC_ALL wins over LANG" "zh_CN.UTF-8" "$(seen)"
arrive LANG=en_US.UTF-8 LC_MESSAGES=ja_JP.UTF-8
eq "C: LC_MESSAGES wins over LANG" "ja_JP.UTF-8" "$(seen)"
arrive LC_CTYPE=UTF-8
eq "C: LC_CTYPE alone (macOS ssh's) says no language" "" "$(seen)"

for v in C POSIX C.UTF-8; do
  arrive LANG="$v"
  eq "D: LANG=$v ⇒ empty" "" "$(seen)"
done
arrive LANG=en_US.UTF-8 LC_ALL=C
eq "D: LC_ALL=C ⇒ empty (it is the one setlocale reads)" "" "$(seen)"

hello() { tr -d '\r' < "$WORK/tty.out" | sed -n 2p; }
arrive
eq "F: no LANG ⇒ the welcome in 中文" "欢迎回来。⌃空格 打开面板。" "$(hello)"
has_line() { tr -d '\r' < "$WORK/tty.out" | grep -qx "$1"; }
CHECKS=$((CHECKS + 1)); has_line "fleet · $(hostname -s) · $(id -un)" || fail "F: the welcome's first line" "$(cat "$WORK/tty.out")"
arrive LANG=en_US.UTF-8
eq "F: en_US ⇒ English" "Welcome back. ⌃Space opens the panel." "$(hello)"
PERSON='{"version": 3, "bundle": {"ui_lang": "zh"}}' arrive LANG=en_US.UTF-8
eq "F: the person chose 中文 ⇒ 中文, whatever the client says" "欢迎回来。⌃空格 打开面板。" "$(hello)"
PERSON='{"version": 4, "bundle": {"ui_lang": "en"}}' arrive
eq "F: the person chose English ⇒ English with no LANG" "Welcome back. ⌃Space opens the panel." "$(hello)"

rm -rf "$WORK/conf"
env -i HOME="$WORK" PATH="$PATH" SHELL=/bin/sh SSH_CONNECTION='10.0.0.9 5 10.0.0.1 22022' \
  FLEET_CONF_DIR="$WORK/conf" SSH_ORIGINAL_COMMAND=true LANG=de_DE.UTF-8 bash "$BIN/fleet-entry.sh" </dev/null >/dev/null 2>&1
eq "E: a command arrival logs client_lang" "de_DE.UTF-8" "$(logged)"
eq "E: a command arrival prints no welcome" "" "$(env -i HOME="$WORK" PATH="$PATH" SHELL=/bin/sh SSH_CONNECTION='10.0.0.9 5 10.0.0.1 22022' \
  FLEET_CONF_DIR="$WORK/conf2" SSH_ORIGINAL_COMMAND=true LANG=de_DE.UTF-8 bash "$BIN/fleet-entry.sh" </dev/null 2>&1)"
eq "E: … how=exec" "exec" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["how"])' "$WORK/conf/logs/entry.ndjson" 2>/dev/null)"

printf 'fleet-entry-lang selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
