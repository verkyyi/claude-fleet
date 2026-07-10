#!/bin/bash
# tmux-conf-reload-selftest.sh — hermetic guard for tmux-conf-reload.sh (issue #139).
#
# tmux-conf-reload.sh must unbind exactly the binds REMOVED from the conf between
# two revs, across every table form, then re-source — so /fleet-sync-install stops
# leaving a deleted `bind` live (the #135 `bind j` resurrection). This test feeds
# it a hand-built before/after conf pair and asserts:
#
#   1. --print emits exactly the removed (table, key) set — and NOT a bind whose
#      action merely changed, nor one only present in `after`.
#   2. A full run (against a fake `tmux` on PATH) issues one `unbind-key -T
#      <table> <key>` per removed bind AND a final `source-file`.
#   3. A missing/absent `before` conf removes nothing (new conf → no false unbinds).
#
# All tables/keys are covered: prefix (`bind K`), root (`bind -n K`), an explicit
# `-T <tbl>`, and the `-r` repeat flag. No real tmux, no network.
#
# Exit 0 = pass. Non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/tmux-conf-reload.sh"
[ -f "$SUT" ] || { printf 'selftest: missing %s\n' "$SUT" >&2; exit 2; }

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- scratch dir (hermetic) ---------------------------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/conf-reload-selftest.XXXXXX")" \
  || fail "mktemp failed"
trap 'rm -rf "$work"' EXIT

before="$work/before.conf"
after="$work/after.conf"

# before: a bind per table form, plus two that will SURVIVE (`a` changes action,
# `?` is untouched) so we can prove they are NOT reported as removed.
cat > "$before" <<'EOF'
bind a run-shell "attention"
bind j run-shell "standalone-dash"
bind ? display-popup "keys"
bind -n F1 run-shell "root-one"
bind -T copy-mode-vi v send -X begin-selection
bind -r H resize-pane -L
EOF

# after: drop j / F1 / copy-mode-vi v / H; keep ? ; change a's action; add a NEW
# bind (must not count as removed).
cat > "$after" <<'EOF'
bind a run-shell "attention CHANGED"
bind ? display-popup "keys"
bind N run-shell "brand-new"
EOF

# expected removed set, sorted (table<TAB>key)
expected="$(printf '%s\n' \
  "copy-mode-vi	v" \
  "prefix	H" \
  "root	F1" \
  "prefix	j" | sort)"

# --- 1. --print emits exactly the removed set ---------------------------------
got="$(bash "$SUT" --print "$before" "$after" | sort)" \
  || fail "--print exited non-zero"
[ "$got" = "$expected" ] || fail "--print removed set mismatch
--- expected ---
$expected
--- got ---
$got"

# a survivor must never appear
printf '%s\n' "$got" | grep -q 'prefix	a' && fail "'bind a' (action-only change) wrongly reported removed"
printf '%s\n' "$got" | grep -q 'prefix	N' && fail "'bind N' (new bind) wrongly reported removed"

# --- 2. full run drives a fake tmux -------------------------------------------
fakebin="$work/bin"
mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<EOF
#!/bin/sh
echo "\$*" >> "$work/tmux.log"
EOF
chmod +x "$fakebin/tmux"
: > "$work/tmux.log"

out="$(PATH="$fakebin:$PATH" bash "$SUT" "$before" "$after" "$work/fake.tmux.conf")" \
  || fail "full run exited non-zero"
printf '%s\n' "$out" | grep -q 'unbound 4 removed' \
  || fail "report line wrong (expected 'unbound 4 removed …'): $out"

# one unbind-key per removed bind, right table+key
for call in "unbind-key -T copy-mode-vi v" "unbind-key -T prefix H" \
            "unbind-key -T root F1" "unbind-key -T prefix j"; do
  grep -Fxq "$call" "$work/tmux.log" \
    || fail "missing '$call' in tmux calls:
$(cat "$work/tmux.log")"
done
# exactly 4 unbinds — no over-unbinding of survivors
uc="$(grep -c '^unbind-key ' "$work/tmux.log")"
[ "$uc" -eq 4 ] || fail "expected 4 unbind-key calls, got $uc:
$(cat "$work/tmux.log")"
# and the re-source happened, after the unbinds
grep -Fxq "source-file $work/fake.tmux.conf" "$work/tmux.log" \
  || fail "no 'source-file' call after unbinding:
$(cat "$work/tmux.log")"

# --- 3. absent `before` conf → nothing removed --------------------------------
: > "$work/tmux.log"
out="$(PATH="$fakebin:$PATH" bash "$SUT" "$work/nonexistent.conf" "$after" "$work/fake.tmux.conf")" \
  || fail "run with missing before-conf exited non-zero"
printf '%s\n' "$out" | grep -q 'unbound 0 removed' \
  || fail "missing before-conf should remove nothing: $out"
grep -q '^unbind-key ' "$work/tmux.log" \
  && fail "missing before-conf triggered an unbind (should not)"

printf 'selftest OK: removed-bind unbinding correct across all table forms\n'
