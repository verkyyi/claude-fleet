#!/bin/bash
# dash-repo-add-selftest.sh — the add-a-repo popup (issue #1103, EPIC #1096 C7).
#
# Pins, on a throwaway one-repo fleet (no repos/ dir — the degenerate case):
#   A. the scriptable form: `dash-repo-add.sh --session <s> <owner/name>` prints ONE
#      token on stdout and nothing else there — added:<slug> when $HOME/projects/<name>
#      already is that repo (a URL form normalises to the same), refused:hosted for the
#      conf's own repo, refused:invalid-repo for a non owner/name (no fleet-repo.sh
#      run), refused:origin-mismatch when the default dir is another repo,
#      refused:no-fleet with no session to resolve; exit 0 only on added.
#   B. degenerate first: adding through the popup path writes ONLY the overlay — the
#      fleet conf is byte-identical before and after, and a one-repo fleet lists the
#      key and the menu item (they are how the second repo gets in).
#   C. the wiring, three ways (#556): `repo-add` is in dash-keymap.sh's dash table on
#      ctrl-z (⌥z under a C-z prefix), tmux-dashboard.sh binds $DASH_KEY_REPO_ADD to
#      an execute() of dash-popup.sh → dash-repo-add.sh, the dash sheet has its ⌃z
#      row; the sidebar's row menu carries a `g` item on the same popup + script
#      (EPIC #894 convention 1), and its `?` rows list the letter.
#   E. what a person reads (issue #3375): --shape takes owner/name, https / ssh /
#      git@ links (with a /tree/… or ?tab= tail); --explain gives every result token
#      a sentence in zh and en, never the token itself, and failed:clone says
#      网络不通 / 找不到 / 没登录 off the clone's own output (end to end too); ⌘P's
#      「添加仓库…」 line opens this popup; the skill and the default CLAUDE/AGENTS
#      block send Claude down the same road.
#   D. the interactive form, on a real PTY: esc cancels (`cancelled`, exit 130, no
#      fleet-repo.sh run); a typed owner/name + ↵ adds it, the verdict screen holds
#      until ↵, stdout is the token alone. Needs fzf + python3; SKIPped without.
#
# Hermetic: HOME, FLEET_CONF_DIR and TMPDIR are sandboxed; tmux goes to a private
# socket via a PATH shim; gh is shimmed to fail (no network — a clone is never
# attempted, the "added" legs reuse a prepared checkout); the register's collector
# kick is off (_FLEET_REGISTER_NO_KICK=1). Exit 0 = pass; non-zero = the failures.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ADD="$BIN/dash-repo-add.sh"
[ -f "$ADD" ] || { printf 'selftest: %s missing\n' "$ADD" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-repo-add-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/home/projects" "$WORK/conf" "$WORK/tmp"
if [ -n "$REAL_TMUX" ]; then
  printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$WORK/bin/tmux"
else
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/tmux"
fi
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export _FLEET_REGISTER_NO_KICK=1
# The sheet + menu are localized since #1188 (bin/fleet-ui-lang.sh: FLEET_UI_LANG,
# else the login locale) — pin the English the rows below assert.
export FLEET_UI_LANG=en
unset TMUX TMUX_PANE FLEET_SESSION FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) : ;; *) fail "$1: [$3] not in [$2]" ;; esac; }

mkrepo() {   # $1=dir $2=owner/name — a checkout whose origin IS that repo
  git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"
}
S=ft
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
mkrepo "$WORK/mainA" o/a
cat > "$FLEET_CONF_DIR/fleets/$S/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
EOF
conf_before=$(cat "$FLEET_CONF_DIR/fleets/$S/conf")

# run <args…> → stdout on $OUT, stderr on $ERR, exit code on $RC
run() { OUT=$(bash "$ADD" "$@" 2>"$WORK/err"); RC=$?; ERR=$(cat "$WORK/err"); }

# --- A. the scriptable form: one token, right exit -----------------------------------
run --session "$S" 'bad repo'
eq "A: a non owner/name → refused:invalid-repo" "$OUT" "refused:invalid-repo"; eq "A: … rc 1" "$RC" 1
run --session "$S" o/a
eq "A: the conf's own repo → refused:hosted" "$OUT" "refused:hosted"; eq "A: … rc 1" "$RC" 1
has "A: … the human line names it" "$ERR" "already hosts o/a"
[ -d "$FLEET_CONF_DIR/fleets/$S/repos" ] && fail "A: a refusal created repos/"
mkrepo "$HOME/projects/b" o/b
run --session "$S" o/b
eq "A: a prepared ~/projects/<name> → added" "$OUT" "added:o-b"; eq "A: … rc 0" "$RC" 0
[ -f "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf" ] || fail "A: added, but no overlay at repos/o-b.conf"
has "A: … the overlay points at the default dir" "$(cat "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf")" "FLEET_MAIN=\"$HOME/projects/b\""
has "A: … the human lines say reused" "$ERR" "reusing existing checkout"
eq "A: … fleet_repos lists both" "$(fleet_repos "$S" | tr '\n' ' ')" "o/a o/b "
run --session "$S" o/b
eq "A: adding it again → refused:hosted" "$OUT" "refused:hosted"
mkrepo "$HOME/projects/c" o/c
run --session "$S" 'https://github.com/o/c.git'
eq "A: a GitHub URL normalises to owner/name" "$OUT" "added:o-c"; eq "A: … rc 0" "$RC" 0
mkrepo "$HOME/projects/d" o/x
run --session "$S" o/d
eq "A: the default dir is another repo → refused:origin-mismatch" "$OUT" "refused:origin-mismatch"; eq "A: … rc 1" "$RC" 1
[ -e "$FLEET_CONF_DIR/fleets/$S/repos/o-d.conf" ] && fail "A: a refused add wrote o-d.conf"
mkdir -p "$HOME/projects/e"
run --session "$S" o/e
eq "A: the default dir is not a checkout → refused:not-a-checkout" "$OUT" "refused:not-a-checkout"
# no session to resolve, but the login has ONE fleet — that one is meant (#3375);
# o/f has no checkout and the gh shim fails, so it gets as far as the clone
run o/f
eq "A: no session, one fleet on the login → that fleet (the clone runs)" "$OUT" "failed:clone"; eq "A: … rc 1" "$RC" 1
run --session nosuch o/f
eq "A: a session that is no fleet, one fleet on the login → that fleet" "$OUT" "failed:clone"
OUT=$(FLEET_CONF_DIR="$WORK/noconf" bash "$ADD" o/f 2>"$WORK/err"); RC=$?
eq "A: no fleet on the login at all → refused:no-fleet" "$OUT" "refused:no-fleet"; eq "A: … rc 1" "$RC" 1
has "A: … said in words" "$(cat "$WORK/err")" "no fleet on this computer"
mkrepo "$HOME/projects/g" o/g
OUT=$(FLEET_SESSION="$S" bash "$ADD" o/g 2>/dev/null); eq "A: \$FLEET_SESSION names the fleet (the popup openers export it)" "$OUT" "added:o-g"
run --session "$S"; eq "A: no repo and no terminal → usage (2), no token" "$RC:$OUT" "2:"
run --session "$S" o/h extra; eq "A: an extra arg → usage" "$RC" 2
run --session "$S" --bogus; eq "A: an unknown flag → usage" "$RC" 2

# --- B. degenerate first: the fleet conf is never touched; the entries exist anyway ----
eq "B: the fleet conf is byte-identical after three adds" "$(cat "$FLEET_CONF_DIR/fleets/$S/conf")" "$conf_before"
# a fresh one-repo fleet (no repos/ dir) still lists the key and the menu item —
# neither depends on how many repos the fleet hosts, which is the whole point
S1=one; mkdir -p "$FLEET_CONF_DIR/fleets/$S1"; cp "$FLEET_CONF_DIR/fleets/$S/conf" "$FLEET_CONF_DIR/fleets/$S1/conf"
eq "B: the one-repo fixture hosts one repo" "$(fleet_repos "$S1" | grep -c .)" 1
eq "B: a one-repo fleet's dash keymap has repo-add on ctrl-z" \
   "$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' bash "$BIN/dash-keymap.sh" key repo-add)" "ctrl-z"
has "B: a one-repo fleet's row menu lists the item" "$(bash "$BIN/fleet-sidebar-menu.sh" --keys | cut -f1 | tr '\n' ' ')" " g "
mkrepo "$HOME/projects/two" o/two
OUT=$(bash "$ADD" --session "$S1" o/two 2>/dev/null); eq "B: the first add on a one-repo fleet" "$OUT" "added:o-two"
eq "B: … and it is a two-repo fleet now" "$(fleet_repos "$S1" | tr '\n' ' ')" "o/a o/two "

# --- C. the wiring: keymap ⇄ dash bind ⇄ sheet ⇄ sidebar menu --------------------------
KM="$BIN/dash-keymap.sh"; DASH="$BIN/tmux-dashboard.sh"; KEYS="$BIN/fleet-keys.sh"; MENU="$BIN/fleet-sidebar-menu.sh"
eq "C: repo-add resolves to ⌃z under C-b" "$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' bash "$KM" glyph repo-add)" "⌃z"
eq "C: … and dodges a C-z prefix to alt-z" "$(FLEET_TMUX_PREFIX=C-z FLEET_TMUX_PREFIX2='' bash "$KM" key repo-add)" "alt-z"
has "C: env spells the action REPO_ADD" "$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' bash "$KM" env)" "DASH_KEY_REPO_ADD='ctrl-z'"
grep -Eq -- '--bind "\$DASH_KEY_REPO_ADD:execute\(bash \$BIN/dash-popup\.sh [^)]*-- bash \$BIN/dash-repo-add\.sh\)\+reload\(' "$DASH" \
  || fail "C: tmux-dashboard.sh does not bind \$DASH_KEY_REPO_ADD to execute(dash-popup.sh … dash-repo-add.sh)+reload"
grep -Eq '^ *DASH_KEY_[A-Z_ =a-z-]*DASH_KEY_REPO_ADD=ctrl-z' "$DASH" \
  || fail "C: tmux-dashboard.sh lacks the DASH_KEY_REPO_ADD=ctrl-z launch floor"
SHEET=$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain --context dash)
printf '%s\n' "$SHEET" | grep -q '^  ⌃z .*add a repo to this fleet' || fail "C: the dash sheet has no ⌃z add-a-repo row"
printf '%s\n' "$SHEET" | grep '^  ⌃z ' | grep -q 'fleet-repo.sh add' || fail "C: the ⌃z row does not name the shell form"
RSHEET=$(FLEET_TMUX_PREFIX=C-z FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain --context dash)
printf '%s\n' "$RSHEET" | grep -q '^  ⌥z .*⌃z is your tmux prefix C-z' || fail "C: under a C-z prefix the sheet must list ⌥z and say why"
eq "C: the row menu's letter for repo is g" "$(printf '%s\n' "$(bash "$MENU" --keys)" | awk -F '\t' '$1=="g"{print $2}' | grep -c 'add a repo')" 1
grep -Eq 'adda "\$\(t menu_repo\)" "\$\(mk repo\)" "\$\(ask repo\)"' "$MENU" \
  || fail "C: fleet-sidebar-menu.sh has no menu_repo item asking on the sidebar line (ask repo) via \$(mk repo) (#1620)"
grep -q '"--session", session, text\], env, repo_added)' "$BIN/fleet-sidebar.py" \
  || fail "C: the sidebar's repo question does not hand the typed owner/name to dash-repo-add.sh --session (#1620)"
# the label lives in THE table since #1535 (fleet-ui-lang.sh), both UI languages
[ "$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" t menu_repo)" = '＋ 仓库…' ] && [ "$(FLEET_UI_LANG=en sh "$BIN/fleet-ui-lang.sh" t menu_repo)" = 'Add repo…' ] \
  || fail "C: the repo item must be named in both UI languages (＋ 仓库… / Add repo…, #1188)"
grep -qE 'dash-repo-add\.sh' "$BIN/../README.md" || fail "C: README does not mention the popup"
FULL=$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain)
printf '%s\n' "$FULL" | awk '/^row menu /{f=1;next} f && NF && /^[^ ]/{f=0} f' | grep -q '^  g  .*add a repo' \
  || fail "C: the full sheet's row menu group lacks the g row"

# --- D. the interactive form on a PTY: esc cancels; typed + ↵ adds; the verdict holds ---
if command -v fzf >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  mkrepo "$HOME/projects/pty" o/pty
  python3 - "$ADD" "$S" "$WORK" <<'PY' || FAILS=$((FAILS+1))
import os, pty, select, struct, subprocess, sys, termios, fcntl, time
add, sess, work = sys.argv[1:4]
env = dict(os.environ, TERM='xterm-256color', FLEET_SESSION=sess, FLEET_UI_LANG='zh')
fails = 0
def fail(msg):
    global fails; fails += 1; print('FAIL: D: ' + msg, file=sys.stderr)

def drive(steps, timeout=20):
    """Run the popup on a PTY; each step is (marker, keys): once <marker> has
    been painted, send <keys>. Returns (stdout, exit code, screen)."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
    def ctty():
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    p = subprocess.Popen(['bash', add], env=env, stdin=slave, stdout=subprocess.PIPE, stderr=slave,
                         start_new_session=True, preexec_fn=ctty)
    os.close(slave)
    screen = bytearray(); pending = list(steps); deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r, _, _ = select.select([master], [], [], 0.1)
        if r:
            try: chunk = os.read(master, 65536)
            except OSError: chunk = b''
            if not chunk: break
            screen.extend(chunk)
        if pending and pending[0][0].encode() in screen:
            marker, keys = pending.pop(0)
            time.sleep(0.15)                      # fzf has painted; let it settle
            os.write(master, keys.encode())
            screen = bytearray(screen[-4096:])   # the next marker must be painted after this
        if p.poll() is not None and not pending:
            break
    try: out, _ = p.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); out, _ = p.communicate(); fail('popup did not exit (steps left: %r)' % pending)
    try: os.close(master)
    except OSError: pass
    return out.decode(errors='replace'), p.returncode, bytes(screen).decode(errors='replace')

out, rc, screen = drive([('owner/name', '\x1b')])
if out.strip() != 'cancelled' or rc != 130:
    fail('esc must print `cancelled` and exit 130, got %r / %r' % (out, rc))
if os.path.exists(os.path.join(work, 'conf/fleets', sess, 'repos', 'o-pty.conf')):
    fail('esc still ran the add')

out, rc, screen = drive([('owner/name', 'o/pty\r'), ('关闭', '\r')])
if out.strip() != 'added:o-pty' or rc != 0:
    fail('typed o/pty + enter must print `added:o-pty` alone and exit 0, got %r / %r' % (out, rc))
if not os.path.exists(os.path.join(work, 'conf/fleets', sess, 'repos', 'o-pty.conf')):
    fail('the interactive add wrote no overlay')
if '已加入 o/pty' not in screen:
    fail('the verdict screen did not say 已加入 o/pty')

out, rc, screen = drive([('owner/name', 'o/pty\r'), ('关闭', '\x1b')])
if out.strip() != 'added:o-pty' and out.strip() != 'refused:hosted':
    fail('second interactive add of o/pty: unexpected token %r' % out)
if out.strip() != 'refused:hosted' or rc != 1:
    fail('a hosted repo must print `refused:hosted` and exit 1, got %r / %r' % (out, rc))
if '已在本 fleet' not in screen:
    fail('the verdict screen did not say 已在本 fleet')

# a wrong shape re-asks with the reason, then esc cancels
out, rc, screen = drive([('owner/name', 'nope\r'), ('再试一次', '\x1b')])
if out.strip() != 'cancelled' or rc != 130:
    fail('a bad shape must re-ask (then esc → cancelled/130), got %r / %r' % (out, rc))
sys.exit(1 if fails else 0)
PY
else
  printf 'SKIP D (fzf or python3 missing) — the interactive PTY legs\n'
fi

# --- E. what a person reads (issue #3375): links parse; no token is shown bare -----
for pair in 'o/r=o/r' 'https://github.com/o/r=o/r' 'https://github.com/o/r.git=o/r' \
            'http://github.com/o/r/=o/r' 'https://github.com/o/r/tree/main=o/r' \
            'https://github.com/o/r?tab=readme=o/r' 'https://github.com/o/r#readme=o/r' \
            'github.com/o/r=o/r' 'git@github.com:o/r.git=o/r' 'ssh://git@github.com/o/r.git=o/r' \
            ' octocat/Hello-World =octocat/Hello-World'; do
  inp=${pair%=*}; want=${pair##*=}
  eq "E: --shape [$inp]" "$(bash "$ADD" --shape "$inp")" "$want"
done
for bad in 'bad repo' 'https://github.com/o' 'o/r/x' 'o/' '/r' ''; do
  bash "$ADD" --shape "$bad" >/dev/null 2>&1 && fail "E: --shape [$bad] must be refused (rc 1)"
done
mkerr() { printf '%s\n' "$2" > "$WORK/clone.$1"; }
mkerr net 'error connecting to api.github.com'
mkerr dns "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com"
mkerr nf "GraphQL: Could not resolve to a Repository with the name 'o/r'. (repository)"
mkerr nf2 'remote: Repository not found.'
mkerr auth 'To get started with GitHub CLI, please run:  gh auth login'
mkerr other 'fatal: something else entirely'
ex() { FLEET_UI_LANG="$1" bash "$ADD" --explain "$2" o/r ${3:+"$WORK/clone.$3"}; }
eq "E: zh failed:clone + network → 网络不通" "$(ex zh failed:clone net)" "$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" t repo_add_net)"
has "E: zh … 「拉不到 GitHub，网络不通」" "$(ex zh failed:clone dns)" "拉不到 GitHub，网络不通"
has "E: en … network" "$(ex en failed:clone dns)" "Cannot reach GitHub"
has "E: not found (gh's wording is not DNS)" "$(ex zh failed:clone nf)" "GitHub 上找不到 o/r"
has "E: not found (git's wording)" "$(ex en failed:clone nf2)" "GitHub has no o/r"
has "E: not signed in" "$(ex zh failed:clone auth)" "gh auth login"
has "E: any other clone failure points at git's lines" "$(ex zh failed:clone other)" "git 的输出"
has "E: hosted is friendly and says where" "$(ex zh refused:hosted)" "已在本 fleet 里，代码在 $HOME/projects/r"
has "E: added says where and that it is hosted" "$(ex en added:o-r)" "the code is in $HOME/projects/r"
for tok in added:o-r refused:hosted refused:origin-mismatch refused:not-a-checkout refused:invalid-repo \
           refused:no-fleet failed:clone failed:write failed:no-result refused:whatever failed:whatever; do
  for lang in zh en; do
    v=$(ex "$lang" "$tok" other)
    [ -n "$v" ] || fail "E: $lang $tok has no sentence"
    case "$v" in *refused:*|*failed:*|*added:*|*repo_add_*) fail "E: $lang $tok shows a token / key bare: [$v]" ;; esac
  done
done
# end to end: a gh that cannot reach GitHub → the popup's last word is the network one
printf '#!/bin/sh\necho "error connecting to api.github.com" >&2\nexit 1\n' > "$WORK/bin/gh"
OUT=$(FLEET_UI_LANG=zh bash "$ADD" --session "$S" o/net 2>"$WORK/err"); RC=$?
eq "E: offline clone → failed:clone" "$OUT:$RC" "failed:clone:1"
has "E: … and the person reads 网络不通" "$(tail -n 1 "$WORK/err")" "拉不到 GitHub，网络不通"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
# ⌘P (fleet-quickopen.py): the 添加仓库… line, and ↵ on it opens this popup with the fleet
QO="$BIN/fleet-quickopen.py"
printf '%s\n' "$(python3 "$QO" panel-cmds 2>/dev/null)" | grep -q "^repo-add	添加仓库…	!repo-add$" \
  || fail "E: ⌘P's panel lines have no 「添加仓库…」 → !repo-add"
[ "$(FLEET_UI_LANG=en sh "$BIN/fleet-ui-lang.sh" t panel_repo_add)" = 'Add a repo…' ] || fail "E: panel_repo_add has no English"
grep -q '"bash", str(BIN / "dash-repo-add.sh")\]) + (\["--session", session\]' "$QO" \
  || fail "E: switch_act repo-add does not open dash-repo-add.sh --session <fleet> in a popup"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/switch.args"\n' "$WORK" > "$WORK/bin/switch-seam"; chmod +x "$WORK/bin/switch-seam"
FLEET_SWITCH_REPO_ADD_CMD="$WORK/bin/switch-seam" python3 "$QO" switch-run repo-add "$S" >/dev/null 2>&1 \
  || fail "E: switch-run repo-add refused"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/switch.args" ] && break; sleep 0.2; done
eq "E: … with the fleet named" "$(cat "$WORK/switch.args" 2>/dev/null)" "--session $S"
# the Claude road (skills/fleet-add-repo) names this same script, never a bare clone
SK="$BIN/../skills/fleet-add-repo/SKILL.md"
grep -q 'dash-repo-add.sh' "$SK" 2>/dev/null || fail "E: skills/fleet-add-repo does not send Claude through dash-repo-add.sh"
for f in conf/agent-defaults/claude/CLAUDE.default.md conf/agent-defaults/codex/AGENTS.default.md; do
  grep -q 'fleet-repo.sh add' "$BIN/../$f" || fail "E: $f does not say a repo comes in through fleet-repo.sh add"
done

if [ "$FAILS" -gt 0 ]; then printf 'selftest FAIL: %s failure(s)\n' "$FAILS" >&2; exit 1; fi
printf 'selftest OK: dash-repo-add.sh — tokens, degenerate-first, ⌃z / menu g wiring, PTY prompt, words + ⌘P\n'
