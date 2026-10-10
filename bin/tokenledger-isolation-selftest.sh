#!/bin/bash
# tokenledger-isolation-selftest.sh — the tokenledger/ subtree is inert to the
# fleet (issue #1391).
#
# TokenLedger (Go: the ccquota hub + agent + web) was merged into this repo under
# tokenledger/ with its full history. The live install is a git checkout of this
# repo, so every login now carries a tokenledger/ directory — and that must change
# NOTHING about the fleet. "Degenerate case is sacred": a live install with the
# extra directory behaves byte for byte as one without it. Four rails:
#
#   1. install sync never builds Go — fleet-install-apply.sh and
#      fleet-sync-logins.sh invoke no `go`/`npm`/`docker` and never name
#      tokenledger/ (they may COPY it as plain files; they must not act on it);
#   2. no hook, daemon unit or tmux conf names tokenledger/ — so the extra
#      directory cannot alter any hook/daemon behaviour;
#   3. CI is split both ways: the selftests*.yml path filters never match
#      tokenledger/**, and tokenledger.yml triggers ONLY on tokenledger/** (plus
#      itself);
#   4. run-selftests.sh --changed, driven for real in a throwaway repo, picks
#      only the lint group for a change confined to tokenledger/ — even when a
#      test names a file whose basename matches one in there (hub.go, README.md).
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

# --- 1. install sync never builds Go ----------------------------------------
for s in fleet-install-apply.sh fleet-sync-logins.sh; do
  f="$BIN/$s"
  [ -f "$f" ] || { fail "$s missing"; continue; }
  # Code lines only: a comment may explain this very rule.
  hits=$(grep -nE '(^|[^A-Za-z0-9_./-])(go[[:space:]]+(build|install|test|run|generate|mod)|npm[[:space:]]|docker[[:space:]]|make[[:space:]]+-C)' "$f" \
           | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s runs no go/npm/docker build" \
    || { fail "$s invokes a build:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
  hits=$(grep -n 'tokenledger' "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s never names tokenledger/" \
    || { fail "$s acts on tokenledger:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
done

# --- 2. no hook / daemon / conf names it ------------------------------------
hits=''
for d in hooks launchd systemd conf; do
  [ -d "$ROOT/$d" ] || continue
  # a line that only keeps it OUT (conf/release-tree.list's `!tokenledger/`,
  # #2771) or a comment is not acting on it
  h=$(grep -rlE '^[^#!]*tokenledger/' "$ROOT/$d" 2>/dev/null)
  [ -n "$h" ] && hits="$hits$h
"
done
[ -z "$hits" ] && ok "no hook / daemon unit / conf names tokenledger/" \
  || { fail "a hook/daemon/conf names tokenledger/:"; printf '%s' "$hits" | sed 's/^/     /'; }

# --- 3. CI split both ways --------------------------------------------------
WF="$ROOT/.github/workflows"
# paths_of <file> — every `- '<glob>'` entry of the file's `paths:` lists.
paths_of() {
  awk '/^[[:space:]]*paths:[[:space:]]*$/ { inp = 1; next }
       inp && /^[[:space:]]*-[[:space:]]/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); gsub(/["'\'']/, "", s); print s; next }
       { inp = 0 }' "$1"
}
for w in selftests.yml selftests-macos.yml; do
  [ -f "$WF/$w" ] || { fail "$w missing"; continue; }
  p=$(paths_of "$WF/$w")
  [ -n "$p" ] || { fail "$w has no paths filter — it would run for tokenledger/**"; continue; }
  bad=''
  for g in $p; do
    case "$g" in
      tokenledger*|'**'|'**/*'|'*'|'**/'*) bad="$bad $g" ;;
    esac
  done
  [ -z "$bad" ] && ok "$w path filter never matches tokenledger/**" \
    || fail "$w path filter matches tokenledger/**:$bad"
done
T_WF="$WF/tokenledger.yml"
if [ -f "$T_WF" ]; then
  p=$(paths_of "$T_WF" | sort -u | tr '\n' ' ')
  [ "$p" = ".github/workflows/tokenledger.yml tokenledger/** " ] \
    && ok "tokenledger.yml triggers only on tokenledger/** (+ itself)" \
    || fail "tokenledger.yml paths = [$p]"
  n=$(grep -cE '^[[:space:]]*(push|pull_request):' "$T_WF")
  m=$(grep -cE '^[[:space:]]*paths:' "$T_WF")
  [ "$n" -ge 1 ] && [ "$n" = "$m" ] && ok "every tokenledger.yml trigger carries a paths filter" \
    || fail "tokenledger.yml: $n triggers, $m paths filters"
  grep -qE '^[[:space:]]*working-directory:[[:space:]]*tokenledger$' "$T_WF" \
    && ok "tokenledger.yml runs inside tokenledger/" || fail "tokenledger.yml has no working-directory: tokenledger"
else
  fail "tokenledger.yml missing"
fi

# --- 4. run-selftests.sh --changed ignores tokenledger/ ---------------------
if command -v git >/dev/null 2>&1; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-tokenledger.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
  R="$T/repo"
  mkdir -p "$R/bin" "$R/tokenledger/cmd/ccquota"
  cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$R/bin/"
  mk_test() { printf '#!/bin/sh\n# %s\nexit 0\n' "$2" > "$R/bin/$1-selftest.sh"; }
  mk_test portability 'lint: scans the whole tree'
  mk_test alpha       'reads hub.go and README.md and Makefile'
  mk_test beta        'drives tool-b.sh'
  printf '#!/bin/sh\n' > "$R/bin/tool-b.sh"
  echo 'package main' > "$R/tokenledger/cmd/ccquota/hub.go"
  echo '# tl' > "$R/tokenledger/README.md"
  echo 'all:' > "$R/tokenledger/Makefile"
  g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
  g init -q && g add -A && g commit -qm base && g tag base
  echo '// edit' >> "$R/tokenledger/cmd/ccquota/hub.go"
  echo more >> "$R/tokenledger/README.md"
  echo '	true' >> "$R/tokenledger/Makefile"
  g add -A && g commit -qm tl
  out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --changed base </dev/null 2>&1); rc=$?
  ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | sort | tr '\n' ' ')
  [ "$rc" -eq 0 ] && [ "$ran" = 'portability-selftest.sh ' ] \
    && ok "--changed: a tokenledger/-only change runs the lint group alone" \
    || { fail "--changed on tokenledger/: rc=$rc ran=[$ran]"; printf '%s\n' "$out" | grep '^select' | sed 's/^/     /'; }
else
  echo "SKIP: git not installed (rail 4)"
fi

[ "$FAILS" -eq 0 ] || { echo "tokenledger-isolation-selftest: $FAILS failure(s)"; exit 1; }
echo "tokenledger-isolation-selftest: all green"
