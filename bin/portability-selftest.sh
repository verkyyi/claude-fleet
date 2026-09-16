#!/bin/bash
# portability-selftest.sh — the machine check for issue #696: a GNU-only shell
# idiom that the BSD (macOS) toolchain quietly does something ELSE with.
#
# Why this exists
# ---------------
# Every workflow in this repo runs `runs-on: ubuntu-latest`, so until #696 NO CI
# ran on a BSD toolchain — while the operator's own gate runs (worker panes, the
# live install) are all macOS. A GNU-only idiom is therefore green in CI and
# broken on the only machine that matters.
#
# #689 was exactly that: run-selftests.sh scrubbed the environment with a single
# `sed -e 's/\(FLEET_[A-Za-z0-9_]*\)=.*\|^\(CCQUOTA_…\)=.*/\1/p'`. `\|`
# alternation inside a BRE is a GNU extension — BSD sed neither matches it nor
# complains — so on a Mac `$scrub` came out EMPTY and the whole env-isolation
# half was a SILENT no-op. CI scrubbed normally and showed nothing. It survived
# from #660 to #681, and was only found when a new knob made the two platforms
# disagree out loud.
#
# The damning part: `bin/dash-pin-selftest.sh:102` has carried the comment
# "(awk, not sed: BSD sed has no `\|` alternation.)" the whole time. The
# knowledge was in the repo and the bug landed anyway — which is the argument
# for a machine check rather than a convention.
#
# What it enforces, across bin/ hooks/ shell/ extras/
# ---------------------------------------------------
#   sed-bre   a GNU-only BRE metacharacter (`\|` `\+` `\?` `\d`) inside a sed
#             script that is not in -E/-r mode.
#   sed-i     `sed -i` with no ATTACHED suffix. GNU reads the suffix attached
#             (`-i.bak`); BSD reads it as the next argument (`-i ''`). The two
#             spellings are mutually exclusive, so only `-i.bak` is portable.
#   gnu-opt   a GNU-only option on a utility whose BSD build spells it
#             differently: `readlink -f`, `date -d`, `stat -c`, `base64 -w`,
#             `mktemp -p`.
#
# What it must NOT flag, and why that is the hard half
# ----------------------------------------------------
# The naive lint here — `grep -rn '\\|' bin/` — is worse than none: all 18 of
# this repo's `\|` sites are CORRECT. BSD **grep** does support `\|`
# (`/usr/bin/grep -c 'RUNSHELL\|KILL'` → 2 on macOS), awk's `/^\|---\|/` is an
# escaped literal pipe, and so is a `\|` inside `grep -E`. A lint that reds on
# those gets muted in a week, which is how you end up with no lint at all.
#
# So the scan is COMMAND-SCOPED, not line-scoped: the line is split into shell
# segments at unquoted `|` `;` `&` `(` `)` `{` `}` and backtick, comments are
# dropped at the first unquoted `#` at a word boundary, and only a segment whose
# command word is `sed` is checked for BRE metacharacters. Comment lines — the
# repo has several that discuss `\|` at length, including the one above — never
# reach a check, because their first word is `#`.
#
# The second false-positive source is real code, not comments: 10 sites call
# `stat -c` / `date -d` on purpose, inside the repo's portable idiom —
#
#     stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
#
# — where the GNU form is the FALLBACK and the BSD form runs first. Flagging
# those would mean 10 findings on a clean master. The exemption is mechanical
# and local: a GNU-only option is fine when the same logical line invokes the
# same utility at least twice AND contains `||`. That is precisely the shape of
# a both-ways fallback, it needs no non-local invariant to stay true, and a
# single bare `stat -c` with no partner is still flagged.
#
# Anything else deliberate marks its line `# portable-ok: <why>`.
#
# Three parts, because a lint that matches nothing is a green light for free:
#   PART 1 — the RULE: zero findings across bin/ hooks/ shell/ extras/.
#   PART 2 — the CLAIM: on a real BSD sed, `\|` does NOT alternate and the
#            portable two-expression form does. This is the premise PART 1 is
#            built on, and it is checked on the platform that has it — which,
#            since #696, is the nightly macOS matrix. SKIPs (exit 0) on GNU sed.
#   PART 3 — the LINT: fixtures prove it flags each unsafe shape, clears each of
#            the false-positive traps above, and honours the escape hatch.
#            Always runs.
#
# Hermetic: reads files, runs awk/sed on temp fixtures. No network, no tmux, no gh.
# Exit 0 = pass, non-zero = fail (prints every offending site).
set -uo pipefail

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/portability-selftest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- the lint ------------------------------------------------------------------
# Written out at run time rather than shipped beside this file so the test stays a
# single self-contained script, the way bash32-array-selftest.sh (issue #703) does.
# Plain POSIX awk only — no gawk-isms (`gensub`, 3-arg `match`): macOS ships the
# one-true-awk, and a lint for portability that is itself unportable is a joke.
cat > "$WORK/portlint.awk" <<'AWK'
# portlint.awk — flag GNU-only shell idioms. One finding per line:
#     <file>:<line>: <code>  <detail>
BEGIN {
  # GNU-only OPTIONS whose BSD build spells the same job differently. Each is
  # exempt inside a `gnu … || bsd …` fallback chain (see scan()).
  gflag["readlink"] = "-f"
  gwhy["readlink"]  = "readlink -f is GNU-only (BSD/macOS readlink had no -f before 12.3) - use `cd -- \"$(dirname -- \"$x\")\" && pwd`"
  gflag["date"]     = "-d"
  gwhy["date"]      = "date -d is GNU; on BSD -d is the DST flag and fails on \"@<epoch>\" - use `date -r`, or a `date -r ... || date -d ...` fallback"
  gflag["stat"]     = "-c"
  gwhy["stat"]      = "stat -c is GNU; BSD wants `stat -f` - use a `stat -f ... || stat -c ...` fallback"
  gflag["base64"]   = "-w"
  gwhy["base64"]    = "base64 -w is GNU; BSD base64 has no -w - pipe through `tr -d '\\n'`"
  gflag["mktemp"]   = "-p"
  gwhy["mktemp"]    = "mktemp -p is GNU; BSD wants a TEMPLATE argument - use `mktemp \"${TMPDIR:-/tmp}/name.XXXXXX\"`"

  # GNU-only BRE metacharacters, checked ONLY inside a sed script not in -E/-r mode.
  nbre = 4
  bre[1] = "\\|"
  brewhy[1] = "\\| alternation in a sed BRE is GNU-only - BSD sed matches it LITERALLY and says nothing (issue #689). Split into two -e expressions, or use awk."
  bre[2] = "\\+"
  brewhy[2] = "\\+ in a sed BRE is GNU-only - BSD sed reads it as a literal +. Write it as `xx*`, or use sed -E."
  bre[3] = "\\?"
  brewhy[3] = "\\? in a sed BRE is GNU-only - BSD sed reads it as a literal ?. Use sed -E."
  bre[4] = "\\d"
  brewhy[4] = "\\d is not a digit class in ANY sed, GNU or BSD - use [0-9] or [[:digit:]]."
}

# Logical lines: a trailing backslash continues, and the finding is reported at
# the line the command STARTS on. Without this, `sed -n -e '...' \` + a second
# `-e '...'` on the next line would be scanned as two commands, and the second
# one - the half that actually carries the script - would have no `sed` in it.
FNR == 1 { buf = ""; start = 0 }
{
  if (buf == "") start = FNR
  if ($0 ~ /\\$/) { buf = buf substr($0, 1, length($0) - 1) " "; next }
  scan(buf $0, start)
  buf = ""
}
END { if (buf != "") scan(buf, start) }

function report(ln, code, detail) {
  printf "%s:%s: %s  %s\n", FILENAME, ln, code, detail
}

# cmdword(seg) - the command a segment runs, or "" . Skips `VAR=val` prefixes and
# the wrappers/keywords that can sit in front of a command, and strips any path so
# /usr/bin/sed reads as sed.
function cmdword(seg,   k, t, j, w) {
  k = split(seg, t, /[ \t]+/)
  for (j = 1; j <= k; j++) {
    w = t[j]
    if (w == "") continue
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
    if (w == "command" || w == "builtin" || w == "exec" || w == "time" || \
        w == "nohup" || w == "!" || w == "then" || w == "else" || w == "elif" || \
        w == "do" || w == "if" || w == "while" || w == "until") continue
    sub(/^.*\//, "", w)
    return w
  }
  return ""
}

# scan(s, ln) - split one logical line into shell segments and check each.
function scan(s, ln,
              i, n, c, q, seg, segs, nseg, prev, hasor, j, k, t, w, cw, cnt, ere, p) {
  # The deliberate exception, read BEFORE comments are stripped.
  if (index(s, "portable-ok") > 0) return

  n = length(s); q = ""; seg = ""; nseg = 0; prev = ""; hasor = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    # Inside single quotes nothing escapes - which is exactly why `'a\|b'` must
    # survive intact to be checked (or cleared) by command.
    if (q == "'") { seg = seg c; if (c == "'") q = ""; prev = c; continue }
    if (q == "\"") {
      seg = seg c
      if (c == "\\" && i < n) { i++; seg = seg substr(s, i, 1); prev = "x"; continue }
      if (c == "\"") q = ""
      prev = c; continue
    }
    if (c == "\\") {
      seg = seg c
      if (i < n) { i++; seg = seg substr(s, i, 1) }
      prev = "x"; continue
    }
    if (c == "'" || c == "\"") { q = c; seg = seg c; prev = c; continue }
    # A `#` starts a comment only at a word boundary - never in `${x#y}` or `a#b`.
    if (c == "#" && (prev == "" || prev == " " || prev == "\t")) break
    if (c == "|" || c == ";" || c == "&" || c == "(" || c == ")" || \
        c == "{" || c == "}" || c == "`") {
      if (c == "|" && substr(s, i + 1, 1) == "|") hasor = 1
      nseg++; segs[nseg] = seg; seg = ""; prev = ""; continue
    }
    seg = seg c; prev = c
  }
  nseg++; segs[nseg] = seg

  for (i = 1; i <= nseg; i++) { cw[i] = cmdword(segs[i]); if (cw[i] != "") cnt[cw[i]]++ }

  for (i = 1; i <= nseg; i++) {
    w = cw[i]
    if (w == "") continue
    seg = segs[i]
    k = split(seg, t, /[ \t]+/)

    if (w == "sed") {
      # -E / -r switch the script to ERE, where `\|` `\+` `\?` are escaped
      # LITERALS and portable. Match a pure flag cluster so `-i.bak` cannot be
      # misread as one.
      ere = 0
      for (j = 1; j <= k; j++)
        if ((t[j] ~ /^-[A-Za-z]+$/ && t[j] ~ /[Er]/) || t[j] ~ /^--regexp-extended/) ere = 1
      if (! ere)
        for (p = 1; p <= nbre; p++)
          if (index(seg, bre[p]) > 0) report(ln, "sed-bre", brewhy[p])
      for (j = 1; j <= k; j++)
        if (t[j] ~ /^-[A-Za-z]*i$/)
          report(ln, "sed-i", "`sed -i` with no ATTACHED suffix is not portable: GNU reads the suffix attached (-i.bak), BSD reads it as the next argument (-i ''). Write a temp file and mv, or use -i.bak.")
    }

    if (w in gflag) {
      # The portable idiom: the same utility invoked twice around a `||`, one
      # spelling per platform. Local, mechanical, and true by inspection.
      if (cnt[w] >= 2 && hasor) continue
      p = gflag[w]
      for (j = 1; j <= k; j++) {
        if (t[j] == p || (index(t[j], p) == 1 && substr(t[j], length(p) + 1, 1) !~ /[A-Za-z]/)) {
          report(ln, "gnu-opt", gwhy[w])
          break
        }
      }
    }
  }
}
AWK

# lint <file>... — print every finding. Kept as a function so PART 1 and PART 3
# run the IDENTICAL program: a lint proven on fixtures but applied differently to
# the repo proves nothing.
lint() { awk -f "$WORK/portlint.awk" "$@" 2>/dev/null; }

# ============================================================================
# PART 1 — the rule holds across the shipped shell
# ============================================================================
# `find -L` because inside the hermetic shadow root (issue #660) bin/ is a real
# directory of SYMLINKS and hooks/ shell/ extras/ are themselves symlinks to the
# real tree; without -L, find reports the link and never descends.
#
# This file is excluded from its own scan: PART 3's fixtures are deliberately
# unsafe shapes written as heredocs, and a `# portable-ok` marker inside one
# would change the very text the lint is being tested against.
files=$(find -L "$ROOT/bin" "$ROOT/hooks" "$ROOT/shell" "$ROOT/extras" \
          -type f \( -name '*.sh' -o -name '*.zsh' \) 2>/dev/null \
        | grep -v '/portability-selftest\.sh$' | sort)
ok; [ -n "$files" ] || fail "found no shell scripts to scan under $ROOT — the scan target moved"

# shellcheck disable=SC2086  # intentional: $files is a newline-separated path list
hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk -f "$WORK/portlint.awk" 2>/dev/null)
ok; [ -z "$hits" ] || fail "GNU-only idiom(s) that the BSD/macOS toolchain does NOT do the same thing with:
$hits
(a deliberate one marks its line \`# portable-ok: <why>\`)"

# ============================================================================
# PART 2 — the claim, on a real BSD sed
# ============================================================================
# PART 1 is only worth running because `\|` really does mean different things to
# the two seds. Assert that where it is observable. On the nightly macOS matrix
# (issue #696) this is the part that runs; on the ubuntu shards it SKIPs.
if sed --version 2>/dev/null | head -1 | grep -q GNU; then
  printf 'portability-selftest: GNU sed on this host — PART 2 (BSD semantics) skipped\n' >&2
else
  ok; [ "$(printf 'foo\n' | sed 's/foo\|bar/X/' 2>/dev/null)" = "foo" ] \
    || fail "this sed ALTERNATED on \`\\|\` in a BRE — it is not the BSD sed this rule is about, and PART 1's premise needs re-checking"
  ok; [ "$(printf 'foo\n' | sed -e 's/foo/X/' -e 's/bar/X/' 2>/dev/null)" = "X" ] \
    || fail "the portable two-expression form did not substitute on this sed"
  ok; [ "$(printf 'foo\n' | sed -E 's/foo|bar/X/' 2>/dev/null)" = "X" ] \
    || fail "sed -E did not alternate on this sed — the ERE escape in the lint is wrong here"
fi

# ============================================================================
# PART 3 — the lint itself
# ============================================================================
# Each fixture is one claim. The GOOD half is the important half: every entry in
# it is a shape that really appears in this repo and must stay green.

cat > "$WORK/bad-sed-alt.sh" <<'SH'
#!/bin/sh
env | sed -n -e 's/^\(FLEET_[A-Za-z0-9_]*\)=.*\|^\(CCQUOTA_[A-Za-z0-9_]*\)=.*/\1/p'
SH
cat > "$WORK/bad-sed-plus.sh" <<'SH'
#!/bin/sh
printf '%s' "$1" | sed 's/[0-9]\+//'
SH
cat > "$WORK/bad-sed-opt.sh" <<'SH'
#!/bin/sh
printf '%s' "$1" | sed 's/colou\?r/color/'
SH
cat > "$WORK/bad-sed-digit.sh" <<'SH'
#!/bin/sh
printf '%s' "$1" | sed 's/\d//g'
SH
cat > "$WORK/bad-sed-i.sh" <<'SH'
#!/bin/sh
sed -i 's/a/b/' "$1"
SH
cat > "$WORK/bad-stat.sh" <<'SH'
#!/bin/sh
m=$(stat -c %Y "$1")
SH
cat > "$WORK/bad-date.sh" <<'SH'
#!/bin/sh
when=$(date -d "@$1" '+%H:%M')
SH
cat > "$WORK/bad-misc.sh" <<'SH'
#!/bin/sh
root=$(readlink -f "$1")
b=$(printf '%s' "$1" | base64 -w 0)
d=$(mktemp -p /tmp)
SH

# The false-positive traps. Every one of these is a real shape from this repo.
cat > "$WORK/good.sh" <<'SH'
#!/bin/sh
# A comment that talks about sed and `\|` at length, the way run-selftests.sh
# and dash-pin-selftest.sh both do, and mentions sed -i and stat -c too.
grep -q 'RUNSHELL\|KILL' "$1" && echo hit            # BSD grep DOES support \|
grep -Eq 'command -v fzf[^|]*\|\|' "$1" && echo hit  # escaped literal pipe in an ERE
awk -F'|' '$0 !~ /^\|---\|/ && NF != 6 { print NR }' "$1"
printf 'a\n' | sed -E 's/foo|bar/X/'
printf 'a\n' | sed -e 's/foo/X/' -e 's/bar/X/'
sed -i.bak 's/a/b/' "$1"
mt() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
ts() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null; }
m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo '')
for c in $(pgrep -P "$$" 2>/dev/null); do echo "$c"; done
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
SH

cat > "$WORK/opted-out.sh" <<'SH'
#!/bin/sh
m=$(stat -c %Y "$1")   # portable-ok: GNU-only path, guarded by a uname check above
SH

# Multi-line: the finding must land on the line the command STARTS on.
cat > "$WORK/bad-continued.sh" <<'SH'
#!/bin/sh
echo hi
env | sed -n \
  -e 's/^a.*\|^b.*/x/p'
SH

want() {  # want <fixture> <code> — exactly one finding, of this code
  out=$(lint "$WORK/$1")
  case "$out" in
    *" $2 "*) ;;
    *) fail "lint missed $2 in $1: ${out:-<no findings>}" ;;
  esac
}

ok; want bad-sed-alt.sh   sed-bre
ok; want bad-sed-plus.sh  sed-bre
ok; want bad-sed-opt.sh   sed-bre
ok; want bad-sed-digit.sh sed-bre
ok; want bad-sed-i.sh     sed-i
ok; want bad-stat.sh      gnu-opt
ok; want bad-date.sh      gnu-opt
ok; want bad-misc.sh      gnu-opt

# bad-misc carries three separate GNU-only options; a lint that stops at the
# first would let the other two land.
ok; [ "$(lint "$WORK/bad-misc.sh" | wc -l | tr -d ' ')" = 3 ] \
  || fail "expected 3 findings in bad-misc.sh, got: $(lint "$WORK/bad-misc.sh")"

ok; [ -z "$(lint "$WORK/good.sh")" ] \
  || fail "lint flagged a PORTABLE form — this is the failure mode that gets a lint muted:
$(lint "$WORK/good.sh")"
ok; [ -z "$(lint "$WORK/opted-out.sh")" ] \
  || fail "lint ignored the '# portable-ok:' escape hatch"

ok; [ "$(lint "$WORK/bad-continued.sh" | sed -n 's/.*:\([0-9]*\): .*/\1/p')" = 3 ] \
  || fail "a continued command must be reported at its FIRST line, got: $(lint "$WORK/bad-continued.sh")"

# The `||` exemption is ONE LOGICAL LINE, on purpose. A both-ways fallback spelled
# across two lines (`gnu … && return 0` / `bsd …`) is STILL flagged and marks itself
# `# portable-ok:` instead — the exemption stays local and mechanical rather than
# scanning a window, which is an invariant the next edit can break from a distance
# (the same argument bash32-array-selftest.sh makes for refusing credit to a nearby
# guard). fleet-lib.sh's fleet_epoch_from_iso is the one real site, and it carries
# the marker. Pinned here so this is a decision with a test, not an accident of the
# regex — and so widening it later has to be deliberate.
cat > "$WORK/split-fallback.sh" <<'SH'
#!/bin/sh
iso2epoch() {
  date -u -d "$1" +%s 2>/dev/null && return 0
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
SH
ok; want split-fallback.sh gnu-opt

printf 'portability-selftest: OK (%d checks, %d file(s) scanned)\n' \
  "$CHECKS" "$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
