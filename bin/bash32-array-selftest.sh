#!/bin/bash
# bash32-array-selftest.sh — the regression net for issue #703: on macOS's stock
# bash, expanding an EMPTY array BARE is a fatal error, not an empty expansion.
#
#   $ bash --version | head -1
#   GNU bash, version 3.2.57(1)-release
#   $ set -u; a=(); for x in "${a[@]}"; do :; done
#   bash: a[@]: unbound variable
#
# bash 4+ expands it to nothing, so this never shows up in CI (ubuntu ships bash 5)
# or in any `bash -n` parse check — it fires only on the operator's own machine,
# only on the code path where the array happens to be empty, and it fires FATALLY.
# #703 was exactly that: `fleet-account.sh whoami` with no window id walked an
# empty WIDS and died, while `quota` and `migrate --dry-run` (which always had
# candidates) looked fine. A silent mine, and there is no reason to think one
# script is the only place it is buried.
#
# The rule this test enforces, repo-wide: AN ARRAY A FILE CAN LEAVE EMPTY IS NEVER
# EXPANDED BARE. Write `${a[@]+"${a[@]}"}` (or `"${a[*]-}"` inside a string) — both
# are no-ops when the array is populated, and both are already the idiom here
# (fleet-model-switch.sh, dash-popup.sh, dash-issue-session.sh).
#
# Deliberately a ZERO-TOLERANCE rule, with no credit for a nearby
# `[ "${#a[@]}" -gt 0 ]` guard: a guard is a NON-LOCAL invariant that the next edit
# can break without touching the expansion, and the failure it lets through is
# fatal and platform-specific. The safe form costs nothing and needs no invariant.
# A site that genuinely wants the bare form marks its line `# bash32-ok: <why>`.
#
# Three parts, because a lint that matches nothing is a green light for free:
#   PART 1 — the RULE: no bare expansion of an empty-able array anywhere in bin/.
#   PART 2 — the CLAIM: on a real bash 3.2, the bare form dies and the safe form
#            does not — plus a `bash -n` PARSE sweep of bin/ on that same 3.2,
#            which nets the rest of the family. (Writing this test tripped one:
#            bash 3.2's `$(...)` scanner mis-reads a `case` pattern's unbalanced
#            `)` and dies on the `;;`, where bash 4+ parses it fine. `bash -n`
#            catches that whole class in one pass, but only on a 3.x host — which
#            is precisely the host CI does not have.) SKIPs (still exit 0) where
#            no bash 3.x exists.
#   PART 3 — the LINT: fixtures prove it flags each unsafe shape, clears each safe
#            one, and honours the escape hatch. Always runs.
#
# Hermetic: reads files, runs bash on temp fixtures. No network, no tmux, no gh.
# Exit 0 = pass, non-zero = fail (prints every offending site).
set -uo pipefail

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bash32-array-selftest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- the lint ------------------------------------------------------------------
# empty_arrays <file> — array names the file can leave empty: initialised `NAME=()`,
# or filled from a stream (`read -a NAME`, `mapfile -t NAME`), where no input means
# no elements.
empty_arrays() {
  {
    grep -oE '[A-Za-z_][A-Za-z0-9_]*=\([[:space:]]*\)' "$1" | sed 's/=(.*//'
    grep -E '(^|[^A-Za-z0-9_])(read|mapfile|readarray)([^A-Za-z0-9_]|$)' "$1" \
      | grep -oE '\-a[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/^-a[[:space:]]+//'
    grep -oE '(mapfile|readarray)([[:space:]]+-[A-Za-z][^[:space:]]*)*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$1" \
      | sed -E 's/.*[[:space:]]//'
  } 2>/dev/null | sort -u
}

# lint_file <file> — print "<file>:<line>: <NAME>" per bare expansion of such an
# array. One sed + one grep per FILE, never per name: the sed deletes every SAFE
# form in place (and blanks comment lines and opted-out lines), so any surviving
# `${NAME[@]}` is bare by construction — and sed preserves the line count, so
# `grep -n` still reports the true line number.
lint_file() {
  local f="$1" names ln body nm
  names=$(empty_arrays "$f")
  [ -n "$names" ] || return 0
  sed -E \
    -e '/bash32-ok/s/.*//' \
    -e 's/^[[:space:]]*#.*$//' \
    -e 's/\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]:?\+"?\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"?\}//g' \
    -e 's/\$\{#[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}//g' \
    -e 's/\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]:?[-+][^}]*\}//g' \
    "$f" 2>/dev/null \
  | grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}' 2>/dev/null \
  | while IFS=: read -r ln body; do
      for nm in $(printf '%s' "$body" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}' \
                  | sed -E 's/^\$\{//; s/\[[@*]\]\}$//' | sort -u); do
        case "
$names
" in *"
$nm
"*) printf '%s:%s: %s\n' "$f" "$ln" "$nm" ;; esac
      done
    done
}

# lint_utf8 <file> — issue #2727: print "<file>:<line>" per `$name` that a non-ASCII
# byte follows directly (`$x，` `$x）` `$x→`). bash 3.2 in a UTF-8 locale reads those
# bytes as part of the NAME: under `set -u` it dies (`x\357: unbound variable`),
# without it the value silently expands to nothing. Write `${x}，`. Comment lines,
# an escaped `\$x` and a `# bash32-ok:` line are skipped; LC_ALL=C so the bytes
# are bytes on every host.
lint_utf8() {
  LC_ALL=C sed -E \
    -e '/bash32-ok/s/.*//' \
    -e 's/^[[:space:]]*#.*$//' \
    -e 's/\\\$//g' \
    "$1" 2>/dev/null \
  | LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' 2>/dev/null \
  | LC_ALL=C sed -E "s|^([0-9]+):.*|$1:\\1|"
}

# bash_scripts — every bash/sh script in bin/: the *.sh files plus an extensionless
# one whose shebang names a shell (bin/fleet).
bash_scripts() {
  local f
  for f in "$BIN"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      *.sh) printf '%s\n' "$f" ;;
      *.*) ;;
      *) head -1 "$f" 2>/dev/null | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' && printf '%s\n' "$f" ;;
    esac
  done
}

# --- PART 1: the rule holds across bin/ ----------------------------------------
# This file is excluded from its own scan: PART 3's fixtures are deliberately
# unsafe shapes, written as heredocs, and a `# bash32-ok` marker inside one would
# change the very text the lint is being tested against.
hits=$(for f in "$BIN"/*.sh; do
  [ "${f##*/}" = bash32-array-selftest.sh ] && continue
  lint_file "$f"
done)
ok; [ -z "$hits" ] || fail "bare expansion of an empty-able array (fatal on bash 3.2) — use \${a[@]+\"\${a[@]}\"}:
$hits"

# PART 1b — issue #2727: no `$name` glued to a non-ASCII byte anywhere in bin/.
hits=$(bash_scripts | while read -r f; do
  [ "${f##*/}" = bash32-array-selftest.sh ] && continue
  lint_utf8 "$f"
done)
ok; [ -z "$hits" ] || fail "\$name followed directly by a non-ASCII byte (bash 3.2 + UTF-8 reads it into the name) — write \${name}:
$hits"

# --- PART 2: the claim, on a real bash 3.2 -------------------------------------
B32=""
for c in /bin/bash bash3.2 bash; do
  command -v "$c" >/dev/null 2>&1 || continue
  case "$("$c" --version 2>/dev/null | head -1)" in *"version 3."*) B32="$c"; break ;; esac
done
if [ -n "$B32" ]; then
  ok; "$B32" -c 'set -u; a=(); for x in "${a[@]}"; do :; done' 2>/dev/null \
    && fail "bash 3.2 ($B32) accepted a bare empty-array expansion — the premise of this test is gone"
  ok; "$B32" -c 'set -u; a=(); printf "%s" "${a[*]}"' 2>/dev/null \
    && fail "bash 3.2 ($B32) accepted a bare empty \${a[*]} — the string-context half of the rule is gone"
  ok; "$B32" -c 'set -u; a=(); for x in ${a[@]+"${a[@]}"}; do :; done; [ "${#a[@]}" = 0 ]; printf "%s" "${a[*]-}"' \
    || fail "bash 3.2 ($B32) rejected a form this rule calls safe"
  # the safe form must still be faithful when the array is POPULATED, spaces and all
  ok; [ "$("$B32" -c 'set -u; a=(p "q r"); printf "[%s]" ${a[@]+"${a[@]}"}')" = '[p][q r]' ] \
    || fail "\${a[@]+\"\${a[@]}\"} lost the element split/quoting on bash 3.2"

  # issue #2727 — `$x，` under a UTF-8 locale: the full-width comma's bytes join the
  # name. Only where such a locale exists (a C-only box cannot show it).
  U8=""
  for l in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    [ "$(LC_ALL=$l "$B32" -c 'printf %s "${#1}"' _ '，' 2>/dev/null)" = 1 ] && { U8=$l; break; }
  done
  if [ -n "$U8" ]; then
    ok; LC_ALL=$U8 "$B32" -c 'set -u; x=1; printf "%s" "$x，"' >/dev/null 2>&1 \
      && fail "bash 3.2 ($B32, $U8) read \$x， as \$x — the premise of the #2727 lint is gone"
    ok; [ "$(LC_ALL=$U8 "$B32" -c 'set -u; x=1; printf "%s" "${x}，"')" = '1，' ] \
      || fail "bash 3.2 ($B32, $U8) mangled \${x}， — the form the #2727 lint asks for"
  fi

  # PART 2b — every script in bin/ must PARSE on 3.2. Cheap (~1s), and it nets the
  # bash-3.2 landmines that are syntax rather than semantics; `bash -n` on the CI's
  # bash 5 sees none of them.
  bad=$(for f in "$BIN"/*.sh; do "$B32" -n "$f" 2>/dev/null || printf '%s\n' "${f##*/}"; done)
  ok; [ -z "$bad" ] || fail "does not parse under bash 3.2 ($B32) — the operator's shell:
$bad
(re-run \`$B32 -n bin/<name>\` for the message; a \`case\` inside \`\$(...)\` needs its
pattern written \`(pat)\` so the 3.2 scanner sees balanced parens)"
else
  printf 'bash32-array-selftest: no bash 3.x on this host — PART 2 (semantics) skipped\n' >&2
fi

# --- PART 3: the lint itself ---------------------------------------------------
cat > "$WORK/bad-loop.sh" <<'SH'
#!/bin/bash
a=()
for x in "${a[@]}"; do :; done
SH
cat > "$WORK/bad-string.sh" <<'SH'
#!/bin/bash
KEYS=()
printf 'got: %s\n' "${KEYS[*]}"
SH
cat > "$WORK/bad-read.sh" <<'SH'
#!/bin/bash
read -r -a idxs <<< "$1"
printf '%s\n' "${idxs[@]}"
SH
cat > "$WORK/good.sh" <<'SH'
#!/bin/bash
a=(); b=()
for x in ${a[@]+"${a[@]}"}; do :; done
[ "${#a[@]}" -gt 0 ] && printf '%s' "${b[@]:+"${b[@]}"}"
printf 'joined: %s\n' "${a[*]-}"
SH
cat > "$WORK/never-empty.sh" <<'SH'
#!/bin/bash
cmd=(tmux -L sock)
"${cmd[@]}" list-windows
SH
cat > "$WORK/opted-out.sh" <<'SH'
#!/bin/bash
a=()
a+=(x)
for x in "${a[@]}"; do :; done   # bash32-ok: a is unconditionally appended to above
SH

printf '#!/bin/bash\n# a comment: $x，\necho "$y，"\necho "\\$z，"\necho "${w}，"\necho "$v，"  # bash32-ok: fixture\necho "$u ，" "$t→"\n' > "$WORK/utf8.sh"
ok; [ "$(lint_utf8 "$WORK/utf8.sh" | tr '\n' ' ')" = "$WORK/utf8.sh:3 $WORK/utf8.sh:7 " ] \
  || fail "lint_utf8 got: $(lint_utf8 "$WORK/utf8.sh" | tr '\n' ' ') (want lines 3 and 7)"
ok; [ "$(lint_file "$WORK/bad-loop.sh")"   = "$WORK/bad-loop.sh:3: a" ]      || fail "lint missed a bare \${a[@]} loop"
ok; [ "$(lint_file "$WORK/bad-string.sh")" = "$WORK/bad-string.sh:3: KEYS" ] || fail "lint missed a bare \${KEYS[*]} in a string"
ok; [ "$(lint_file "$WORK/bad-read.sh")"   = "$WORK/bad-read.sh:3: idxs" ]   || fail "lint missed a bare expansion of a \`read -a\` array"
ok; [ -z "$(lint_file "$WORK/good.sh")" ]        || fail "lint flagged a SAFE form: $(lint_file "$WORK/good.sh")"
ok; [ -z "$(lint_file "$WORK/never-empty.sh")" ] || fail "lint flagged an array that is never empty-initialised"
ok; [ -z "$(lint_file "$WORK/opted-out.sh")" ]   || fail "lint ignored the '# bash32-ok:' escape hatch"

# --- the zsh sibling (issue #1633) ------------------------------------------------
# The other shell bin/ code runs under that CI never sees: a skill's `source
# fleet-lib.sh` in Claude Code's Bash tool runs in zsh, where a `local path` empties
# PATH. zsh-local-selftest.sh lints that repo-wide; it rides along HERE because this
# test is in SELFTEST_ALWAYS (a whole-tree lint no filename rule can select).
out=$(bash "$BIN/zsh-local-selftest.sh" 2>&1) || fail "zsh-local-selftest.sh: $out"
ok

# --- the python 3.9 sibling (issue #2024) -----------------------------------------
# macOS's own /usr/bin/python3 is 3.9, whose fromisoformat cannot read the hub's
# nanosecond `…Z`: iso-time-selftest.sh lints bin/ for a bare fromisoformat( and runs
# bin/fleet_iso.py's cases on every python3 here. Same reason to ride along here.
out=$(bash "$BIN/iso-time-selftest.sh" 2>&1) || fail "iso-time-selftest.sh: $out"
ok

printf 'bash32-array-selftest: OK (%d checks)\n' "$CHECKS"
