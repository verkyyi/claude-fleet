#!/bin/bash
# fleet-repo-anyaddr-selftest.sh — a repo is any git address (issue #3600, EPIC #3570 C7).
#
#   A. names — fleet_repo_name_of / fleet_forge_of over every address shape:
#      GitHub (bare, https, git@, ssh://) answers owner/name + github; any other
#      host the path's last two parts + none; a one-part or home (`~`) path takes
#      the host's first label (`ssh://macmini/~/repos/demo.git` → macmini/demo),
#      a local one `local`.
#   B. five addresses, each added once through fleet-repo.sh add (fleet_repo_register):
#      GitHub https, GitHub ssh, GitLab https, an ssh bare repo, file:// — the remote
#      ones rewritten onto local bare repos by git's own `url.<x>.insteadOf`, so
#      nothing leaves the box. The three not on GitHub: cloned with git, their base
#      read off the remote (`ls-remote --symref`), the conf saying FLEET_REMOTE ·
#      FLEET_FORGE="none" · FLEET_LAND="fleet" — and the recording gh stand-in
#      called 0 times for any of it. fleet_repo_forge reads each conf back.
#   C. degenerate — a bare owner/name add writes the conf exactly as before (no
#      FLEET_REMOTE / FORGE / LAND line), and a repo hosted before the adds keeps
#      its conf and key byte for byte. (n): every add leaves the other repos' confs
#      and the .order prefix untouched.
#   D. a taken name is refused with the --as hint; --as adds it under its own name.
#   E. fleet-doctor.sh with only non-GitHub repos prints no gh / github / labels
#      row, and its per-repo main + base rows pass off FLEET_REMOTE.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-repo-anyaddr.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/shim" "$WORK/home" "$WORK/srv/acme" "$WORK/srv/repos" "$WORK/srv/gh/o" "$WORK/tmp"
# gh records every call and always fails; tmux / launchctl / systemctl do nothing
printf '#!/bin/sh\necho "gh $*" >> "%s/gh.calls"\nexit 1\n' "$WORK" > "$WORK/shim/gh"
for t in tmux launchctl systemctl; do printf '#!/bin/sh\nexit 0\n' > "$WORK/shim/$t"; done
chmod +x "$WORK/shim/"*
export PATH="$WORK/shim:$PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 _FLEET_REGISTER_NO_KICK=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset TMUX TMUX_PANE FLEET_SESSION FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH
. "$BIN/fleet-lib.sh"

FAILS=0; CHECKS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { CHECKS=$((CHECKS+1)); printf '%s' "$2" | grep -qF -- "$3" || fail "$1: no [$3] in: $(printf '%s' "$2" | tail -3 | tr '\n' ' ')"; }
hasnt() { CHECKS=$((CHECKS+1)); printf '%s' "$2" | grep -qE -- "$3" && fail "$1: [$3] should be absent"; return 0; }

# bare <dir> <head-branch> — a bare repo with one commit on <head-branch>, HEAD on it
bare() {
  git init -q --bare "$1" && git -C "$1" symbolic-ref HEAD "refs/heads/$2"
  git clone -q "$1" "$WORK/seed.$$" 2>/dev/null
  git -C "$WORK/seed.$$" -c user.email=t@x -c user.name=t commit -q --allow-empty -m seed
  git -C "$WORK/seed.$$" push -q origin "HEAD:$2" 2>/dev/null
  rm -rf "$WORK/seed.$$"
}
bare "$WORK/srv/acme/widgets.git" develop      # GitLab https
bare "$WORK/srv/repos/demo.git"   trunk        # an ssh bare repo on "macmini"
bare "$WORK/srv/local.git"        main         # file://
bare "$WORK/srv/gh/o/hs.git"      master       # GitHub https
bare "$WORK/srv/gh/o/ss.git"      master       # GitHub ssh
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[init]
	defaultBranch = master
[url "file://$WORK/srv/acme/"]
	insteadOf = https://gitlab.com/acme/
[url "file://$WORK/srv/repos/"]
	insteadOf = ssh://macmini/~/repos/
[url "file://$WORK/srv/gh/o/"]
	insteadOf = https://github.com/o/
	insteadOf = git@github.com:o/
EOF

# ---- A. names ------------------------------------------------------------------
while IFS='|' read -r addr forge name; do
  [ -n "$addr" ] || continue
  eq "A: forge of $addr" "$(fleet_forge_of "$addr")" "$forge"
  eq "A: name of $addr" "$(fleet_repo_name_of "$addr")" "$name"
done <<'EOF'
o/n|github|o/n
https://github.com/o/n.git|github|o/n
https://github.com/o/n/|github|o/n
git@github.com:o/n.git|github|o/n
ssh://git@github.com/o/n.git|github|o/n
https://gitlab.com/acme/widgets.git|none|acme/widgets
https://gitlab.com/g/sub/p.git|none|sub/p
git@gitlab.com:g/p.git|none|g/p
https://gitee.com/demo.git|none|gitee/demo
ssh://macmini/~/repos/demo.git|none|macmini/demo
macmini.tail.ts.net:~/demo.git|none|macmini/demo
ssh://git@host:2222/a/b.git|none|a/b
file:///srv/git/demo.git|none|git/demo
file:///demo.git|none|local/demo
/srv/git/demo.git|none|git/demo
EOF

# ---- B/C. five addresses + the degenerate --------------------------------------
S=fa
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
printf 'FLEET_SESSION=%s\n' "$S" > "$FLEET_CONF_DIR/fleets/$S/conf"
# a repo hosted before #3600 — its conf and key must not move
git init -q "$WORK/old" && git -C "$WORK/old" remote add origin https://github.com/o/old.git
OLDCONF="$FLEET_CONF_DIR/fleets/$S/repos/o-old.conf"
printf 'FLEET_REPO="o/old"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_MODEL="opus"\n' "$WORK/old" > "$OLDCONF"
printf 'o-old\n' > "$FLEET_CONF_DIR/fleets/$S/repos/.order"
old_sum=$(cksum < "$OLDCONF"); old_key=$(fleet_slug "$(fleet_repo_name_of o/old)")

# snap — every conf but <slug>'s, and the order file, as they stand
snap() { ( cd "$FLEET_CONF_DIR/fleets/$S/repos" && for f in *.conf; do [ "$f" = "$1.conf" ] || { echo "== $f"; cat "$f"; }; done ); }
add() {   # add <address> [args…] → the token; gh calls counted around it
  : > "$WORK/gh.calls"
  bash "$BIN/fleet-repo.sh" add --session "$S" "$@" 2>"$WORK/add.err"
}
conf_of() { cat "$FLEET_CONF_DIR/fleets/$S/repos/$(fleet_slug "$1").conf" 2>/dev/null; }

for row in "https://gitlab.com/acme/widgets.git|acme/widgets|develop" \
           "ssh://macmini/~/repos/demo.git|macmini/demo|trunk" \
           "file://$WORK/srv/local.git|srv/local|main"; do
  addr=${row%%|*}; rest=${row#*|}; name=${rest%%|*}; base=${rest#*|}
  before=$(snap "$(fleet_slug "$name")"); order0=$(cat "$FLEET_CONF_DIR/fleets/$S/repos/.order")
  tok=$(add "$addr")
  eq "B: add $addr" "$tok" "added:$(fleet_slug "$name")"
  [ "$tok" = "added:$(fleet_slug "$name")" ] || sed 's/^/    /' "$WORK/add.err" >&2
  eq "B: gh calls adding $addr" "$(grep -c . "$WORK/gh.calls")" 0
  c=$(conf_of "$name")
  has "B: $name FLEET_REMOTE" "$c" "FLEET_REMOTE=\"$addr\""
  has "B: $name FLEET_FORGE" "$c" 'FLEET_FORGE="none"'
  has "B: $name FLEET_LAND" "$c" 'FLEET_LAND="fleet"'
  has "B: $name base off the remote" "$c" "FLEET_BASE_BRANCH=\"$base\""
  eq "B: $name cloned from its address" "$(git -C "$HOME/projects/${name##*/}" config --get remote.origin.url)" "$addr"
  eq "B: fleet_repo_forge $name" "$(fleet_repo_forge "$name" "$S")" none
  eq "C(n): adding $name leaves the other confs alone" "$(snap "$(fleet_slug "$name")")" "$before"
  case "$(cat "$FLEET_CONF_DIR/fleets/$S/repos/.order")" in
    "$order0"*) CHECKS=$((CHECKS+1)) ;; *) fail "C(n): adding $name reordered .order" ;;
  esac
done

# GitHub by its https and ssh addresses: GitHub's (gh may be asked; git clones the address when it cannot)
for row in "https://github.com/o/hs.git|o/hs" "git@github.com:o/ss.git|o/ss"; do
  addr=${row%%|*}; name=${row#*|}
  tok=$(add "$addr")
  eq "B: add $addr" "$tok" "added:$(fleet_slug "$name")"
  c=$(conf_of "$name")
  hasnt "B: $name is GitHub's — no FLEET_FORGE line" "$c" 'FLEET_(REMOTE|FORGE|LAND)='
  eq "B: fleet_repo_forge $name" "$(fleet_repo_forge "$name" "$S")" github
  eq "B: $name cloned without a GitHub login" "$(git -C "$HOME/projects/${name##*/}" rev-parse --is-inside-work-tree 2>/dev/null)" true
done

# C. a bare owner/name add: the conf is exactly the pre-#3600 lines
git init -q "$WORK/plain" && git -C "$WORK/plain" remote add origin https://github.com/p/plain.git
tok=$(add p/plain "$WORK/plain")
eq "C: bare owner/name add" "$tok" "added:p-plain"
eq "C: its conf is the pre-#3600 shape" "$(conf_of p/plain | grep -v '^#')" "$(printf 'FLEET_REPO="p/plain"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"' "$WORK/plain")"
eq "C: the old repo's conf byte for byte" "$(cksum < "$OLDCONF")" "$old_sum"
eq "C: the old repo's key" "$(fleet_slug "$(fleet_norm_repo o/old)")" "$old_key"
eq "C: an old conf reads github" "$(fleet_repo_forge o/old "$S")" github
eq "C: fleet_repos lists every repo, old first" "$(fleet_repos "$S" | tr '\n' ' ')" "o/old acme/widgets macmini/demo srv/local o/hs o/ss p/plain "

# ---- D. a taken name -----------------------------------------------------------
mkdir -p "$WORK/other/srv"; bare "$WORK/other/srv/local.git" main
tok=$(add "file://$WORK/other/srv/local.git" "$WORK/home/projects/local2")
eq "D: a taken name is refused" "$tok" "refused:hosted"
has "D: the refusal names --as" "$(cat "$WORK/add.err")" "--as <ns/name>"
tok=$(add "file://$WORK/other/srv/local.git" "$WORK/home/projects/local2" --as other/local)
eq "D: --as adds it under its own name" "$tok" "added:other-local"
has "D: --as keeps the address" "$(conf_of other/local)" "FLEET_REMOTE=\"file://$WORK/other/srv/local.git\""
eq "D: gh calls" "$(grep -c . "$WORK/gh.calls")" 0

# ---- E. the doctor with only non-GitHub repos ----------------------------------
S2=fe
export FLEET_CONF_DIR="$WORK/conf2"
mkdir -p "$FLEET_CONF_DIR/fleets/$S2"
printf 'FLEET_SESSION=%s\n' "$S2" > "$FLEET_CONF_DIR/fleets/$S2/conf"
tok=$(bash "$BIN/fleet-repo.sh" add --session "$S2" "ssh://macmini/~/repos/demo.git" "$WORK/home/projects/demo-e" 2>/dev/null)
eq "E: add for the doctor" "$tok" "added:macmini-demo"
: > "$WORK/gh.calls"
doc=$(FLEET_DOCTOR_FAST=1 sh "$BIN/fleet-doctor.sh" 2>&1)
hasnt "E: no gh row" "$doc" '^[[:space:]]*[A-Z]+[[:space:]]+gh[[:space:]]'
hasnt "E: no github row" "$doc" '^[[:space:]]*[A-Z]+[[:space:]]+github[[:space:]]'
hasnt "E: no labels row" "$doc" '^[[:space:]]*[A-Z]+[[:space:]]+labels[[:space:]]'
has "E: main passes off FLEET_REMOTE" "$doc" "macmini/demo: $WORK/home/projects/demo-e (origin matches)"
has "E: base is the remote's HEAD" "$doc" 'macmini/demo: base "trunk" is the repo default'
hasnt "E: the repo block asked gh nothing" "$(cat "$WORK/gh.calls")" 'repo view|label list'

if [ "$FAILS" -gt 0 ]; then printf 'selftest FAIL: %d of %d checks\n' "$FAILS" "$CHECKS" >&2; exit 1; fi
printf 'selftest PASS: a repo is any git address — %d checks held (issue #3600)\n' "$CHECKS"
