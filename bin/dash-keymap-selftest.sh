#!/bin/bash
# dash-keymap-selftest.sh — the dash key resolver (issue #556).
#
# tmux never delivers its prefix to a pane, so the dash's ⌃-keys are resolved
# against the live prefix/prefix2 by bin/dash-keymap.sh: the default unless it IS
# a prefix, else the ⌥ twin (alt-<same letter>), else — both are prefixes — the
# default, marked unreachable. Under test:
#   • the table: the agent flip is ctrl-v (NOT ctrl-a — the operator's prefix,
#     which is how #556 happened) and no ⌥ fallback is an fzf default (alt-b/d/f);
#   • collision → ⌥ fallback; prefix2 counts; both → UNREACHABLE; a fallback's
#     own collision is irrelevant while the default is free;
#   • tmux key-name parsing: C-x · M-x · C-M-x / M-C-x · C-Space · ^X · None · case;
#   • the prefix sources, in order: the env pin (FLEET_TMUX_PREFIX[2]) · the live
#     server (`tmux show -gv`) · the conf tmux reads (~/.tmux.conf, then the XDG
#     path; last `set` wins, quotes stripped) · tmux's C-b;
#   • the consumers read the SAME resolution: fleet-keys.sh shows the real glyph
#     + a note and names the prefix in its header; fleet-doctor.sh WARNs per
#     collision and PASSes clean; tmux-dashboard.sh binds every table action via
#     $DASH_KEY_<ACTION> and nothing by a literal chord; the toggle toast asks the
#     resolver for its glyph.
# Hermetic: a fake tmux on PATH answers `show -gv`; HOME is sandboxed for the
# conf fallback. No network, no server, no fzf. Exit 0 = pass; non-zero = the
# failing assert. (The end-to-end "tmux eats the prefix, ⌥ still lands" tail runs
# in bin/dash-agent-toggle-selftest.sh, which owns the fzf sandbox.)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
KM="$BIN/dash-keymap.sh"; KEYS="$BIN/fleet-keys.sh"; DOCTOR="$BIN/fleet-doctor.sh"
DASH="$BIN/tmux-dashboard.sh"; TOGGLE="$BIN/dash-agent-toggle.sh"
for f in "$KM" "$KEYS" "$DOCTOR" "$DASH" "$TOGGLE"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-keymap-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

# km <prefix> <prefix2> <cmd…> — the resolver pinned through the env seam.
km() { local p="$1" p2="$2"; shift 2; FLEET_TMUX_PREFIX="$p" FLEET_TMUX_PREFIX2="$p2" bash "$KM" "$@"; }
# field <rows> <action> <n> — column n of the row for <action> in a `list`.
field() { printf '%s\n' "$1" | awk -v a="$2" -v n="$3" '$1==a {print $n}'; }

# --- A. the table under the stock prefix: defaults, ctrl-v flip, clean ------------
rows=$(km C-b '' list) || fail "A: list exited non-zero" "$rows"
[ "$(printf '%s\n' "$rows" | grep -c .)" -eq 13 ] || fail "A: expected 13 dash actions" "$rows"
printf '%s\n' "$rows" | awk '$6!="ok"{bad=1} END{exit bad}' || fail "A: under C-b every action must resolve to its default (state ok)" "$rows"
printf '%s\n' "$rows" | awk '$2!=$4{bad=1} END{exit bad}' || fail "A: under C-b key == default for every row" "$rows"
[ "$(field "$rows" agent 2)" = ctrl-v ] || fail "A: the agent flip must default to ctrl-v (#556: ctrl-a is the operator's prefix)" "$rows"
printf '%s\n' "$rows" | awk '{print $4}' | grep -qx 'ctrl-a' && fail "A: no dash default may be ctrl-a — it is a common tmux prefix (screen users)" "$rows"
printf '%s\n' "$rows" | awk '{print $4}' | grep -qx 'ctrl-b' && fail "A: no dash default may be ctrl-b — tmux's stock prefix" "$rows"
[ "$(km C-b '' key agent)" = ctrl-v ]   || fail "A: key agent → ctrl-v"
[ "$(km C-b '' glyph agent)" = '⌃v' ]  || fail "A: glyph agent → ⌃v"
[ -z "$(km C-b '' collisions)" ]        || fail "A: no collisions under C-b" "$(km C-b '' collisions)"
[ "$(km C-b '' prefixes)" = 'C-b -' ]   || fail "A: prefixes echoes 'C-b -'" "$(km C-b '' prefixes)"
[ "$(km C-b '' actions | grep -c .)" -eq 13 ] || fail "A: actions lists 13 names"
env_out=$(km C-b '' env) || fail "A: env exited non-zero" "$env_out"
( eval "$env_out"; [ "${DASH_KEY_AGENT:-}" = ctrl-v ] && [ "${DASH_GLYPH_AGENT:-}" = '⌃v' ] && [ -z "${DASH_REMAP_AGENT-x}" ] \
  && [ "${DASH_KEYSTATE_AGENT:-}" = ok ] && [ "${DASH_KEYMAP_PREFIX:-}" = C-b ] && [ -z "${DASH_KEYMAP_PREFIX2-x}" ] ) \
  || fail "A: env must eval to DASH_KEY_AGENT=ctrl-v / glyph ⌃v / no remap / state ok / prefix C-b" "$env_out"
km C-b '' key nosuch >/dev/null 2>&1 && fail "A: an unknown action must exit non-zero"
ok "A stock C-b: 13 actions at their defaults, agent = ctrl-v/⌃v, clean, env evals"

# #558: each panel resolves its own action names, including the secondary
# preview shortcut in config. The dash's default table remains unchanged.
[ "$(km C-n '' --panel backlog key new)" = alt-n ] || fail "panels: backlog new must dodge C-n"
[ "$(km C-b C-o --panel backlog key open)" = alt-o ] || fail "panels: backlog open must dodge prefix2 C-o"
[ "$(km C-s '' --panel config key scope)" = alt-s ] || fail "panels: config scope must dodge C-s"
[ "$(km C-p '' --panel config key preview)" = alt-p ] || fail "panels: config preview must dodge C-p"
[ "$(km C-r M-r --panel config collisions)" = 'reload ⌃r C-r UNREACHABLE' ] || fail "panels: both prefixes must be reported"
km C-b '' --panel typo list >/dev/null 2>&1 && fail "panels: unknown panel must fail"
ok "panels: separate backlog/config tables honour prefix and prefix2"

# --- B. the fallbacks stay off fzf's own alt keys ------------------------------------
# fzf 0.74 binds alt-b/alt-f (word motion), alt-d (kill-word), alt-bs, alt-/ by
# default; a fallback landing on one would fight the input line.
for fb in $(printf '%s\n' "$rows" | awk '{print $2}' | sed 's/^ctrl-/alt-/'); do
  case "$fb" in alt-b|alt-f|alt-d|alt-bs|alt-/) fail "B: fallback $fb is an fzf default binding" ;; esac
done
ok "B no ⌥ fallback collides with an fzf default (alt-b/d/f/bs//)"

# --- C. the operator's case and the general one: a prefix on a default → its ⌥ twin --
rows=$(km C-v '' list)
[ "$(field "$rows" agent 2)" = alt-v ]     || fail "C: prefix C-v must move the agent flip to alt-v" "$rows"
[ "$(field "$rows" agent 3)" = '⌥v' ]     || fail "C: … glyph ⌥v" "$rows"
[ "$(field "$rows" agent 5)" = C-v ]       || fail "C: … remap names the prefix it dodged" "$rows"
[ "$(field "$rows" agent 6)" = remapped ]  || fail "C: … state remapped" "$rows"
[ "$(printf '%s\n' "$rows" | awk '$6=="ok"' | grep -c .)" -eq 12 ] || fail "C: the other 12 actions stay put" "$rows"
[ "$(km C-v '' collisions)" = 'agent ⌃v C-v ⌥v' ] || fail "C: collisions → 'agent ⌃v C-v ⌥v'" "$(km C-v '' collisions)"
( eval "$(km C-v '' env)"; [ "${DASH_KEY_AGENT:-}" = alt-v ] && [ "${DASH_REMAP_AGENT:-}" = C-v ] && [ "${DASH_KEYSTATE_AGENT:-}" = remapped ] ) \
  || fail "C: env carries the remap" "$(km C-v '' env)"
# a screen-style C-a prefix (the operator's) collides with NOTHING now
[ -z "$(km C-a '' collisions)" ] || fail "C: prefix C-a must collide with no dash key any more" "$(km C-a '' collisions)"
# C-s / C-t / C-o (real-world prefixes) each dodge exactly their own action
[ "$(km C-s '' collisions)" = 'scratch ⌃s C-s ⌥s' ] || fail "C: C-s → scratch ⌥s" "$(km C-s '' collisions)"
[ "$(km C-o '' key restore)" = alt-o ] || fail "C: C-o → restore alt-o"
ok "C a colliding default moves to its ⌥ twin; C-a is now harmless"

# --- D. prefix2 counts; both prefixes → UNREACHABLE, default kept ------------------
[ "$(km C-b C-s collisions)" = 'scratch ⌃s C-s ⌥s' ] || fail "D: prefix2 C-s must remap scratch" "$(km C-b C-s collisions)"
[ -z "$(km C-b None collisions)" ] || fail "D: prefix2 None is no prefix" "$(km C-b None collisions)"
rows=$(km C-s M-s list)
[ "$(field "$rows" scratch 2)" = ctrl-s ]      || fail "D: both prefixes → the default is kept" "$rows"
[ "$(field "$rows" scratch 6)" = unreachable ] || fail "D: … marked unreachable" "$rows"
[ "$(km C-s M-s collisions)" = 'scratch ⌃s C-s UNREACHABLE' ] || fail "D: collisions says UNREACHABLE" "$(km C-s M-s collisions)"
( eval "$(km C-s M-s env)"; [ "${DASH_KEYSTATE_SCRATCH:-}" = unreachable ] ) || fail "D: env state unreachable"
ok "D prefix2 collides too; default + ⌥ twin both prefixes → UNREACHABLE"

# --- E. tmux key-name parsing ------------------------------------------------------------
[ "$(km '^V' '' key agent)" = alt-v ]     || fail "E: legacy ^V must parse as C-v"
[ "$(km c-r '' key reload)" = alt-r ]     || fail "E: lowercase c-r must parse as C-r"
[ -z "$(km C-Space '' collisions)" ]      || fail "E: C-Space collides with nothing" "$(km C-Space '' collisions)"
[ "$(km M-v '' key agent)" = ctrl-v ]     || fail "E: a prefix on the FALLBACK (M-v) is irrelevant while ctrl-v is free"
[ -z "$(km M-C-r '' collisions)" ]        || fail "E: M-C-r (ctrl-alt-r) ≠ ctrl-r" "$(km M-C-r '' collisions)"
[ -z "$(km C-M-r '' collisions)" ]        || fail "E: C-M-r (ctrl-alt-r) ≠ ctrl-r" "$(km C-M-r '' collisions)"
[ "$(km 'C-a;rm' '' prefixes)" = 'C-arm -' ] || fail "E: a prefix name is sanitised before it reaches eval" "$(km 'C-a;rm' '' prefixes)"
ok "E parses ^V, case, C-Space, M-x, C-M-x/M-C-x; sanitises the name"

# --- F. the live server is the source when nothing is pinned -----------------------------
mkdir -p "$WORK/fakebin" "$WORK/home"
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
[ -n "${FAKE_FAIL:-}" ] && exit 1
case "$*" in
  *"show -gv prefix2"*) printf '%s\n' "${FAKE_PREFIX2:-None}" ;;
  *"show -gv prefix"*)  printf '%s\n' "${FAKE_PREFIX:-}" ;;
  *) exit 1 ;;
esac
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"
live() { env -u FLEET_TMUX_PREFIX -u FLEET_TMUX_PREFIX2 -u TMUX_CONF -u XDG_CONFIG_HOME \
             PATH="$WORK/fakebin:$PATH" HOME="$WORK/home" "$@" bash "$KM" "${CMD[@]}"; }
CMD=(prefixes); [ "$(live FAKE_PREFIX=C-r)" = 'C-r -' ] || fail "F: the live server's prefix is read (tmux show -gv prefix)" "$(live FAKE_PREFIX=C-r)"
CMD=(key reload); [ "$(live FAKE_PREFIX=C-r)" = alt-r ] || fail "F: … and applied (reload → alt-r)"
CMD=(collisions); [ "$(live FAKE_PREFIX=C-b FAKE_PREFIX2=C-x)" = 'reap ⌃x C-x ⌥x' ] || fail "F: the live prefix2 is read too" "$(live FAKE_PREFIX=C-b FAKE_PREFIX2=C-x)"
# the env pin beats the server
CMD=(collisions); out=$(FAKE_PREFIX=C-r FLEET_TMUX_PREFIX=C-b PATH="$WORK/fakebin:$PATH" bash "$KM" collisions)
[ -z "$out" ] || fail "F: FLEET_TMUX_PREFIX must override the live server" "$out"
ok "F live server: prefix + prefix2 via tmux show -gv; the env pin wins over it"

# --- G. no server → the conf tmux would read; no conf → C-b ----------------------------------
printf 'set-option -g prefix C-t\nset -g prefix "C-o"\nset -g prefix2 '"'"'M-x'"'"'\n' > "$WORK/home/.tmux.conf"
CMD=(prefixes); [ "$(live FAKE_FAIL=1)" = 'C-o M-x' ] || fail "G: ~/.tmux.conf parsed — last set wins, quotes stripped" "$(live FAKE_FAIL=1)"
CMD=(key restore); [ "$(live FAKE_FAIL=1)" = alt-o ] || fail "G: … and applied (restore → alt-o)"
CMD=(key view); [ "$(live FAKE_FAIL=1)" = ctrl-t ] || fail "G: the overridden earlier prefix (C-t) does not count"
rm -f "$WORK/home/.tmux.conf"; mkdir -p "$WORK/home/.config/tmux"
printf 'set -g prefix C-n\n' > "$WORK/home/.config/tmux/tmux.conf"
CMD=(key new); [ "$(live FAKE_FAIL=1)" = alt-n ] || fail "G: the XDG conf path is read when ~/.tmux.conf is absent"
rm -f "$WORK/home/.config/tmux/tmux.conf"
CMD=(prefixes); [ "$(live FAKE_FAIL=1)" = 'C-b -' ] || fail "G: no server + no conf → tmux's C-b" "$(live FAKE_FAIL=1)"
CMD=(collisions); [ -z "$(live FAKE_FAIL=1)" ] || fail "G: … which collides with nothing"
ok "G conf fallback (~/.tmux.conf, then XDG; last set wins), then C-b"

# --- H. fleet-keys.sh renders the resolution, never the default it dodged -------------
sheet=$(FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain --context dash) || fail "H: fleet-keys.sh exited non-zero" "$sheet"
printf '%s\n' "$sheet" | grep -q '^  ⌃v  *flip this fleet' || fail "H: under C-b the flip row is ⌃v" "$sheet"
printf '%s\n' "$sheet" | grep -q '⌥' && fail "H: under C-b no ⌥ key may appear" "$sheet"
sheet=$(FLEET_TMUX_PREFIX=C-s FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain --context dash)
printf '%s\n' "$sheet" | grep -q '^  ⌥s  *raw scratch session.*⌃s is your tmux prefix C-s' || fail "H: under C-s the scratch row is ⌥s with the why" "$sheet"
printf '%s\n' "$sheet" | grep -q '^  ⌃s ' && fail "H: under C-s the sheet must NOT still list ⌃s" "$sheet"
sheet=$(FLEET_TMUX_PREFIX=C-s FLEET_TMUX_PREFIX2='' NO_COLOR=1 bash "$KEYS" --plain)
printf '%s\n' "$sheet" | head -1 | grep -q 'C-s here' || fail "H: the full sheet's header names the live prefix" "$(printf '%s\n' "$sheet" | head -1)"
sheet=$(FLEET_TMUX_PREFIX=C-s FLEET_TMUX_PREFIX2=M-s NO_COLOR=1 bash "$KEYS" --plain --context dash)
printf '%s\n' "$sheet" | grep -q '^  ⌃s  *raw scratch session.*UNREACHABLE' || fail "H: both prefixes → the row says UNREACHABLE" "$sheet"
grep -q 'key "\$(dg agent)"' "$KEYS" || fail "H: the flip row must come from dg agent (not a literal glyph)"
ok "H ? sheet: real glyph + why under a collision, prefix in the header, UNREACHABLE spelled out"

# --- I. fleet-doctor.sh: one WARN per collision, PASS when clean ---------------------------
doc() { FLEET_TMUX_PREFIX="$1" FLEET_TMUX_PREFIX2="$2" HOME="$WORK/home" PATH="$WORK/fakebin:/usr/bin:/bin" FAKE_FAIL=1 sh "$DOCTOR" 2>&1; }
out=$(doc C-s '')
printf '%s\n' "$out" | grep -q 'WARN  keys  *dash ⌃s (scratch) is your tmux prefix C-s — the dash binds ⌥s instead' \
  || fail "I: doctor must WARN on the C-s collision, naming the ⌥ key it bound" "$out"
[ "$(printf '%s\n' "$out" | grep -c 'WARN  keys')" -eq 2 ] || fail "I: C-s must warn for dash scratch and config scope" "$out"
printf '%s\n' "$out" | grep -q 'WARN  keys  *config ⌃s (scope).*binds ⌥s instead' \
  || fail "I: doctor must report the config scope remap" "$out"
out=$(doc C-s M-s)
printf '%s\n' "$out" | grep -q 'WARN  keys  *dash ⌃s (scratch) is your tmux prefix C-s and its ⌥ twin is one too — unreachable' \
  || fail "I: doctor must shout when even the fallback is a prefix" "$out"
printf '%s\n' "$out" | grep -q 'WARN  keys  *config ⌃s (scope).*unreachable' \
  || fail "I: config must also report an unreachable fallback" "$out"
out=$(doc C-b C-o)
printf '%s\n' "$out" | grep -q 'WARN  keys  *backlog ⌃o (open).*prefix C-o.*binds ⌥o instead' \
  || fail "I: doctor must report backlog prefix2 collisions" "$out"
out=$(doc C-a '')
printf '%s\n' "$out" | grep -q 'PASS  keys  *no dash key collides with the tmux prefix (C-a)' || fail "I: clean → PASS naming the prefix" "$out"
printf '%s\n' "$out" | grep -q 'WARN  keys' && fail "I: clean → no keys WARN" "$out"
ok "I doctor: WARN per collision (⌥ or UNREACHABLE), PASS when clean"

# --- J. wiring: the dash binds the table, only the table, never a literal chord ----------
for a in $(bash "$KM" actions); do
  up=$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')
  grep -q -- "--bind \"\$DASH_KEY_$up:" "$DASH" || fail "J: tmux-dashboard.sh has no --bind \"\$DASH_KEY_$up:…\" for action '$a'"
  grep -q "key \"\$(dg $a)" "$KEYS" || fail "J: fleet-keys.sh has no \$(dg $a) row for action '$a'"
done
grep -Eq -- '--bind "(ctrl|alt)-' "$DASH" && fail "J: tmux-dashboard.sh binds a literal ctrl/alt chord — route it through dash-keymap.sh"
grep -Eq -- '--bind "\$DASH_KEY_AGENT:transform\(bash \$BIN/dash-agent-toggle\.sh\)"' "$DASH" || fail "J: the agent flip must be bound via \$DASH_KEY_AGENT"
grep -q 'eval "$(bash "$KEYMAP" env' "$DASH" || fail "J: the dash must eval dash-keymap.sh env at launch"
grep -q 'dash-keymap.sh" glyph agent' "$TOGGLE" || fail "J: the toggle toast must ask the resolver for its glyph"
grep -q 'dash-keymap.sh' "$DOCTOR" || fail "J: fleet-doctor.sh must consult dash-keymap.sh"
ok "J wiring: every table action bound via \$DASH_KEY_*, no literal chord, toast + doctor on the resolver"

# --- K. shellcheck (when present) ----------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -x "$KM" 2>&1)" || fail "K: dash-keymap.sh not shellcheck-clean" "$sc"
  ok "K dash-keymap.sh is shellcheck-clean"
fi

printf 'dash-keymap-selftest: %d checks passed\n' "$pass"
exit 0
