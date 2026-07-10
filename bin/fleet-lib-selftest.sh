#!/bin/bash
# fleet-lib-selftest.sh — hermetic unit tests for bin/fleet-lib.sh, the shared
# helper library every fleet skill and daemon sources.
#
# Focus is on the BRANCHING logic (not trivial wrappers):
#
#   A. fleet_seat() — the seat guard that gates every /fleet-* skill. Covered
#      across all four outcomes, with an explicit REGRESSION GUARD for issue #118
#      (fix 5105325): cw.zsh names worktrees `<repo>-issue-<N>`, so `issue-<N>`
#      is preceded by `-`, not `/`. The old glob `*/issue-[0-9]*` never matched
#      those, so every cw.zsh worker reported seat=unknown and the role guard
#      silently disabled. The `claude-fleet-issue-118 + @issue → worker` case
#      below fails loudly if that glob ever narrows again.
#
#   B. fleet_reap_ok() — the clean+merged reap gate. The git-dependent branches
#      (dirty / ancestor) are exercised against a real throwaway repo; the pure
#      branches (exact-line merged-PR match, unmerged fallthrough, precedence)
#      are exercised directly. (dash-reap-selftest.sh drives the same gate
#      through the UI; this pins the function's own contract.)
#
#   C. fleet_slug_cached / fleet_repo_cached / fleet_cache — the cheap sessmap
#      lookups and the .ts-keyed cache-file routing (slug'd file iff its fetch
#      completed, else the flat fallback).
#
# Fully hermetic: fakes `tmux` (feeds @issue via $FAKE_ISSUE), drives cwd with
# real temp dirs, and points FLEET_C/FLEET_MAIN at a scratch tree. No network,
# no live tmux. Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-lib-selftest.XXXXXX")" || exit 2
# The fleet_seat "empty" cases require the temp path to have NO `issue-<N>`
# segment anywhere (the worker glob `*/*issue-[0-9]*` matches any ancestor). If
# the ambient TMPDIR is itself inside an issue worktree (a claude-fleet dev
# working in .../claude-fleet-issue-N/), relocate under /tmp (conventionally
# clean) so the test stays deterministic instead of spuriously reporting worker.
case "$WORK" in
  */*issue-[0-9]*)
    rm -rf "$WORK"
    WORK="$(mktemp -d /tmp/fleet-lib-selftest.XXXXXX)" || exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}

# --- fake tmux ----------------------------------------------------------------
# Answers the '#{@issue}' query fleet_seat makes, plus the per-fleet-socket
# machinery (issue #159): a leading `-L <label>` global option (captured, then
# stripped like real tmux), `has-session` (down iff the label is in $FAKE_DOWN),
# and `list-windows -a` (each fleet socket emits a 'plan' hub + one worker window).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'TMUXFAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session)
    for d in ${FAKE_DOWN:-}; do [ "$d" = "$label" ] && exit 1; done
    exit 0 ;;
  list-windows)
    # fleet_hub_sessions / fleet_session_count use the '<session> <window>' fmt.
    case "$*" in *window_name*) printf '%s plan\n%s work1\n' "$label" "$label" ;; esac
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *'@issue'*) printf '%s\n' "${FAKE_ISSUE:-}"; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

# shellcheck source=/dev/null
. "$LIB"

# ============================================================================
# A. fleet_seat — the seat guard
# ============================================================================
# Real dirs whose basenames drive the cwd glob. `pwd -P` inside fleet_seat and
# in our FLEET_MAIN resolution both dereference symlinks, so the comparison is
# consistent even on macOS (/tmp → /private/tmp).
mkdir -p "$WORK/claude-fleet-issue-118" \
         "$WORK/issue-111" \
         "$WORK/base" \
         "$WORK/random-elsewhere"

# 1. #118 REGRESSION GUARD: `<repo>-issue-<N>` worktree + @issue set → worker.
eq "seat: cw.zsh <repo>-issue-<N> worktree with @issue" worker \
  "$( cd "$WORK/claude-fleet-issue-118" && FAKE_ISSUE=118 fleet_seat )"

# 2. Bare `issue-<N>` worktree + @issue set → worker (the pre-#118 shape).
eq "seat: bare issue-<N> worktree with @issue" worker \
  "$( cd "$WORK/issue-111" && FAKE_ISSUE=111 fleet_seat )"

# 3. Base checkout (== FLEET_MAIN) + NO @issue → steward.
eq "seat: base checkout, no @issue" steward \
  "$( cd "$WORK/base" && FLEET_MAIN="$WORK/base" FAKE_ISSUE='' fleet_seat )"

# 4. Unrelated cwd, no @issue, cwd != FLEET_MAIN → empty (ambiguous).
eq "seat: unrelated cwd" "" \
  "$( cd "$WORK/random-elsewhere" && FLEET_MAIN="$WORK/base" FAKE_ISSUE='' fleet_seat )"

# 5. In an issue worktree but @issue EMPTY → NOT worker (the @issue is required,
#    not just the path shape). cwd isn't FLEET_MAIN either → empty.
eq "seat: issue worktree but @issue empty" "" \
  "$( cd "$WORK/claude-fleet-issue-118" && FLEET_MAIN="$WORK/base" FAKE_ISSUE='' fleet_seat )"

# 6. @issue set but cwd is the base checkout (not an issue dir) → NOT worker,
#    and NOT steward (steward requires @issue empty) → empty.
eq "seat: @issue set while sitting in base checkout" "" \
  "$( cd "$WORK/base" && FLEET_MAIN="$WORK/base" FAKE_ISSUE=42 fleet_seat )"

# 7. @issue set + issue-worktree cwd, but FLEET_MAIN unset → still worker
#    (worker seat doesn't depend on FLEET_MAIN).
eq "seat: worker without FLEET_MAIN in env" worker \
  "$( cd "$WORK/issue-111" && unset FLEET_MAIN; FAKE_ISSUE=111 fleet_seat )"

# ============================================================================
# B. fleet_reap_ok — the clean+merged reap gate
# ============================================================================
# Pure branches (no git needed: an empty/absent wtdir skips the dirty probe).
run_reap() {  # <wtdir> <root> <branch> <head> <base> <merged> → prints "<token> <rc>"
  local out rc
  out="$(fleet_reap_ok "$1" "$2" "$3" "$4" "$5" "$6")"; rc=$?
  printf '%s %s' "$out" "$rc"
}

# branch present in the merged list (exact whole-line match) → merged-pr / rc 0.
eq "reap: merged-PR exact match" "merged-pr 0" \
  "$(run_reap "" "" "feature-x" "" "" "$(printf 'foo\nfeature-x\nbar')")"

# branch NOT in merged list, no head/base to test ancestry → unmerged / rc 1.
eq "reap: not merged, no ancestry" "unmerged 1" \
  "$(run_reap "" "" "feature-x" "" "" "$(printf 'foo\nbar')")"

# exact-LINE match: 'feat' must NOT match a 'feature-x' line (grep -qxF) →
# unmerged, guarding against a substring/prefix false-positive.
eq "reap: substring is not a merged match" "unmerged 1" \
  "$(run_reap "" "" "feat" "" "" "$(printf 'feature-x\nother')")"

# git-dependent branches, against a real throwaway repo.
REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m tip
TIP_SHA="$(git -C "$REPO" rev-parse HEAD)"

# clean worktree whose HEAD is an ancestor of base → ancestor / rc 0.
eq "reap: ancestor of base" "ancestor 0" \
  "$(run_reap "$REPO" "$REPO" "somebranch" "$BASE_SHA" "$TIP_SHA" "")"

# HEAD is NOT an ancestor of base (tip vs older base) and not merged → unmerged.
eq "reap: not an ancestor" "unmerged 1" \
  "$(run_reap "$REPO" "$REPO" "somebranch" "$TIP_SHA" "$BASE_SHA" "")"

# dirty worktree short-circuits to dirty / rc 1 even if the branch would
# otherwise count as merged. Use a MODIFIED TRACKED file (not an untracked one)
# so `git status --porcelain` reports it regardless of any global
# core.excludesFile — an untracked file could be gitignored away on a dev box.
printf 'orig\n' > "$REPO/tracked"
git -C "$REPO" add tracked
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m 'add tracked'
printf 'changed\n' >> "$REPO/tracked"        # now ' M tracked' — always dirty
eq "reap: dirty short-circuits merged" "dirty 1" \
  "$(run_reap "$REPO" "$REPO" "feature-x" "" "" "$(printf 'feature-x')")"
git -C "$REPO" checkout -q -- tracked         # restore clean for any later use

# ============================================================================
# C. sessmap lookups + fleet_cache routing (per-fleet layout, issue #181)
# ============================================================================
FLEET_C="$WORK/cache"          # override the module default (plain var, reassignable)
mkdir -p "$FLEET_C"

# No sessmap yet → both cached lookups return empty.
eq "slug_cached: no sessmap" "" "$(fleet_slug_cached s1)"
eq "repo_cached: no sessmap" "" "$(fleet_repo_cached s1)"

# Write the sessmap to the NEW global/ location: session<TAB>slug<TAB>repo.
mkdir -p "$FLEET_C/global"
printf 's1\tacme-widgets\tacme/widgets\n' >  "$FLEET_C/global/sessmap"
printf 's2\tacme-gadgets\tacme/gadgets\n' >> "$FLEET_C/global/sessmap"

eq "slug_cached: hit (global/)" "acme-widgets" "$(fleet_slug_cached s1)"
eq "repo_cached: hit (global/)" "acme/widgets" "$(fleet_repo_cached s1)"
eq "repo_cached: 2nd row"       "acme/gadgets" "$(fleet_repo_cached s2)"
eq "repo_cached: miss"          ""             "$(fleet_repo_cached nope)"

# sessmap dual-read: with NO global/ file, a legacy flat sessmap still resolves.
rm -f "$FLEET_C/global/sessmap"
printf 's3\tacme-legacy\tacme/legacy\n' > "$FLEET_C/sessmap"
eq "slug_cached: legacy flat sessmap" "acme-legacy" "$(fleet_slug_cached s3)"
# and global/ WINS over the legacy flat file when both exist.
mkdir -p "$FLEET_C/global"
printf 's1\tacme-widgets\tacme/widgets\n' >  "$FLEET_C/global/sessmap"
printf 's2\tacme-gadgets\tacme/gadgets\n' >> "$FLEET_C/global/sessmap"
eq "sessmap: global/ wins over legacy" "acme-widgets" "$(fleet_slug_cached s1)"

# fleet_cache routing: the slug'd fetch lives at fleets/<slug>/<base>, gated on its
# .ts marker. No .ts yet → the (non-existent) new-layout path (reader = "loading").
eq "cache: no .ts → new-layout path" "$FLEET_C/fleets/acme-widgets/prmap" "$(fleet_cache prmap s1)"

# Drop the new-layout .ts marker → routes to the fleets/<slug>/ file.
mkdir -p "$FLEET_C/fleets/acme-widgets"
: > "$FLEET_C/fleets/acme-widgets/prmap.ts"
eq "cache: .ts present → fleets/<slug> file" "$FLEET_C/fleets/acme-widgets/prmap" "$(fleet_cache prmap s1)"

# Dual-read: with ONLY a legacy flat <base>_<slug>.ts (no new-layout .ts), the
# legacy file is still returned so a fleet keeps working across land→migrate.
: > "$FLEET_C/issues_acme-widgets.ts"
eq "cache: legacy flat dual-read" "$FLEET_C/issues_acme-widgets" "$(fleet_cache issues s1)"

# A session that doesn't resolve to a slug → degenerate flat fallback.
eq "cache: unresolved session → flat" "$FLEET_C/issues" "$(fleet_cache issues nope)"

# --- two-fleet routing: no cross-fleet leak (issue #180) --------------------
# Each session must route to ITS OWN slug'd cache and NEVER the other's. Both
# fetches have COMPLETED (both new-layout .ts markers present).
mkdir -p "$FLEET_C/fleets/acme-gadgets"
: > "$FLEET_C/fleets/acme-gadgets/prmap.ts"
eq "2fleet: s1 → its own prmap"  "$FLEET_C/fleets/acme-widgets/prmap" "$(fleet_cache prmap s1)"
eq "2fleet: s2 → its own prmap"  "$FLEET_C/fleets/acme-gadgets/prmap" "$(fleet_cache prmap s2)"
[ "$(fleet_cache prmap s1)" != "$(fleet_cache prmap s2)" ] \
  || { echo "FAIL 2fleet: s1 and s2 must not share a prmap (cross-fleet leak)"; exit 1; }
CHECKS=$((CHECKS + 1))   # the bracket assertion above (the two eq calls self-count)

# ============================================================================
# D. layout helpers (issue #181): dirs, dual-layout conf, enumeration, repo→sess
# ============================================================================
CONFROOT="$WORK/conf"
FLEET_CONF_DIR="$CONFROOT"     # override the module default (plain var, reassignable)
: "$FLEET_CONF_DIR"           # read by the sourced fleet-lib helpers (opaque to shellcheck)

# fleet_state_dir / fleet_cache_dir / fleet_cache_global create + print the dir.
eq "state_dir path"  "$CONFROOT/fleets/fleet-a" "$(fleet_state_dir fleet-a)"
[ -d "$CONFROOT/fleets/fleet-a" ] || fail "state_dir did not create the dir"
eq "cache_dir path"  "$FLEET_C/fleets/acme-widgets" "$(fleet_cache_dir acme-widgets)"
[ -d "$FLEET_C/fleets/acme-widgets" ] || fail "cache_dir did not create the dir"
eq "cache_global"    "$FLEET_C/global" "$(fleet_cache_global)"

# fleet_conf_file dual-layout: new fleets/<sess>/conf preferred, else legacy flat.
printf 'FLEET_REPO="acme/new"\n' > "$CONFROOT/fleets/fleet-a/conf"
printf 'FLEET_REPO="acme/legacy"\n' > "$CONFROOT/fleet-b.conf"
eq "conf_file: new layout"     "$CONFROOT/fleets/fleet-a/conf" "$(fleet_conf_file fleet-a)"
eq "conf_file: legacy flat"    "$CONFROOT/fleet-b.conf"        "$(fleet_conf_file fleet-b)"
eq "conf_file: absent → new"   "$CONFROOT/fleets/fleet-z/conf" "$(fleet_conf_file fleet-z)"

# fleet_each_conf enumerates each fleet ONCE, preferring the new layout. Give
# fleet-a BOTH a new dir and a legacy flat conf — it must appear only once (new).
printf 'FLEET_REPO="acme/stale"\n' > "$CONFROOT/fleet-a.conf"
enum=$(fleet_each_conf | sort)
eq "each_conf: fleet-a once, new path" "$CONFROOT/fleets/fleet-a/conf" \
  "$(printf '%s\n' "$enum" | awk -F'\t' '$1=="fleet-a"{print $2}')"
eq "each_conf: fleet-a listed once" "1" \
  "$(printf '%s\n' "$enum" | awk -F'\t' '$1=="fleet-a"' | grep -c .)"
eq "each_conf: fleet-b (legacy) present" "$CONFROOT/fleet-b.conf" \
  "$(printf '%s\n' "$enum" | awk -F'\t' '$1=="fleet-b"{print $2}')"

# fleet_sess_for_repo maps a repo back to its configured session (normalized).
eq "sess_for_repo: new-layout fleet"  "fleet-a" "$(fleet_sess_for_repo acme/new)"
eq "sess_for_repo: URL form matches"  "fleet-a" "$(fleet_sess_for_repo https://github.com/acme/new.git)"
eq "sess_for_repo: legacy fleet"      "fleet-b" "$(fleet_sess_for_repo acme/legacy)"
eq "sess_for_repo: unknown → empty"   ""        "$(fleet_sess_for_repo acme/nope)"

# DETERMINISM GUARD: the issue-bridge + fleet-watch key their per-repo state to the
# CANONICAL session (fleet_sess_for_repo) so two sessions serving ONE repo share it
# rather than re-seeding. With two fleets on the same repo, the mapping must be
# STABLE (first-enumerated wins, same every call) — else the watcher/bridge would
# flip which dir they read and spuriously re-seed an already-firing edge.
mkdir -p "$CONFROOT/fleets/dup-1" "$CONFROOT/fleets/dup-2"
printf 'FLEET_REPO="shared/repo"\n' > "$CONFROOT/fleets/dup-1/conf"
printf 'FLEET_REPO="shared/repo"\n' > "$CONFROOT/fleets/dup-2/conf"
csess1=$(fleet_sess_for_repo shared/repo); csess2=$(fleet_sess_for_repo shared/repo)
eq "sess_for_repo: stable across calls (canonical)" "$csess1" "$csess2"
case "$csess1" in dup-1|dup-2) : ;; *) fail "sess_for_repo: two-fleets-one-repo must resolve to one of them, got [$csess1]";; esac
CHECKS=$((CHECKS + 1))


# ============================================================================
# E. per-fleet socket helpers (issue #159)
# ============================================================================
# fleet_socket is the single scheme point: the socket LABEL is the session name.
eq "socket: label == session name (identity)" "fleet-acme" "$(fleet_socket fleet-acme)"

# fleet_sockets enumerates the per-fleet confs, then keeps only those whose server
# actually answers has-session. s3 has a conf but its server is "down" (FAKE_DOWN)
# → excluded; a missing conf dir yields nothing (the user's default tmux is never
# probed). NB: prefix-assigned FAKE_DOWN/FLEET_CONF_DIR reach the fake tmux the
# same way FAKE_ISSUE reaches it above.
SOCKCONF="$WORK/sockconf"; mkdir -p "$SOCKCONF"
: > "$SOCKCONF/s1.conf"; : > "$SOCKCONF/s2.conf"; : > "$SOCKCONF/s3.conf"
eq "sockets: live confs only (down fleet excluded)" "s1,s2," \
  "$(FLEET_CONF_DIR="$SOCKCONF" FAKE_DOWN="s3" fleet_sockets | sort | tr '\n' ',')"
eq "sockets: no conf dir → empty (default tmux untouched)" "" \
  "$(FLEET_CONF_DIR="$WORK/does-not-exist" fleet_sockets)"

# --- issue #203 REGRESSION GUARD: new-layout (#181) socket discovery ----------
# After #181 moved confs to fleets/<sess>/conf, fleet_sockets globbed the empty
# flat *.conf path and returned NOTHING — every socket-aware daemon (bridge/watch/
# collector-fanout/dispatch) found "no live fleet" and serviced the whole estate
# not at all. These pin: (1) discovery from the NEW layout, (2) label == the DIR
# basename (never `basename … .conf`, which yields "conf"), (3) dual-read of a
# still-flat legacy conf. If fleet_sockets ever hand-rolls the flat glob again,
# the first assertion drops to empty and fails loudly.
NEWCONF="$WORK/newconf"; mkdir -p "$NEWCONF/fleets/na" "$NEWCONF/fleets/nb" "$NEWCONF/fleets/nc"
: > "$NEWCONF/fleets/na/conf"; : > "$NEWCONF/fleets/nb/conf"; : > "$NEWCONF/fleets/nc/conf"
eq "sockets #203: new-layout discovery + dir-basename label (nc down)" "na,nb," \
  "$(FLEET_CONF_DIR="$NEWCONF" FAKE_DOWN="nc" fleet_sockets | sort | tr '\n' ',')"
# Label derivation MUST be the dir name, never "conf": a single fleets/foo/conf
# fleet resolves to label "foo". (The bug produced "conf" for every fleet.)
SOLOCONF="$WORK/newconf-solo"; mkdir -p "$SOLOCONF/fleets/foo"; : > "$SOLOCONF/fleets/foo/conf"
eq "sockets #203: single new-layout fleet → label is the dir, not 'conf'" "foo" \
  "$(FLEET_CONF_DIR="$SOLOCONF" fleet_sockets)"
# Dual-read: a HALF-migrated estate — one fleet in the new layout, one still flat —
# lists BOTH, each exactly once (a fleet with a new-layout dir is not double-listed
# by a leftover flat conf of the same name).
MIXCONF="$WORK/mixconf"; mkdir -p "$MIXCONF/fleets/newf"
: > "$MIXCONF/fleets/newf/conf"           # migrated fleet
: > "$MIXCONF/oldf.conf"                   # un-migrated legacy flat fleet
: > "$MIXCONF/newf.conf"                   # stale leftover flat conf for newf — must NOT re-list
eq "sockets #203: dual-read half-migrated, each fleet once" "newf,oldf," \
  "$(FLEET_CONF_DIR="$MIXCONF" fleet_sockets | sort -u | tr '\n' ',')"
eq "sockets #203: newf listed exactly once (no flat double-count)" "1" \
  "$(FLEET_CONF_DIR="$MIXCONF" fleet_sockets | grep -cx newf)"

# fleet_hub_sessions fans out across live sockets — one 'plan' hub each.
eq "hub_sessions: one per live socket" "s1,s2," \
  "$(FLEET_CONF_DIR="$SOCKCONF" FAKE_DOWN="s3" fleet_hub_sessions | sort | tr '\n' ',')"
# ...and equally over the NEW layout (fans through the same fleet_sockets).
eq "hub_sessions #203: one per new-layout socket" "na,nb," \
  "$(FLEET_CONF_DIR="$NEWCONF" FAKE_DOWN="nc" fleet_hub_sessions | sort | tr '\n' ',')"

# fleet_session_count sums the non-hub worker windows across live sockets (1 each,
# the down fleet contributes none) — the system-wide cap now spans every socket.
eq "session_count: sums workers across live sockets" "2" \
  "$(FLEET_CONF_DIR="$SOCKCONF" FAKE_DOWN="s3" fleet_session_count)"


# --- fleet_summary_key (issue #208): dash-summary cache key is collision-free ---
# across per-fleet tmux servers, which renumber windows from @1. Two fleets each
# with window @2 must map to DISTINCT keys, else one fleet's summary row bleeds
# into the other's dash.
eq "summary_key: <session>_<numeric-id>" "fleetA_2" "$(fleet_summary_key fleetA @2)"
eq "summary_key: cross-fleet same window-id → DISTINCT keys" "fleetB_2" "$(fleet_summary_key fleetB @2)"
eq "summary_key: id is digits-only (strips the @)" "s_17" "$(fleet_summary_key s @17)"
eq "summary_key: unexpected chars in session sanitized to _" "a_b.c_1" "$(fleet_summary_key 'a/b.c' @1)"
eq "summary_key: empty session → bare _<id> (single-fleet / uncached)" "_2" "$(fleet_summary_key '' @2)"
# The hot-path reader inlines the SAME expansion (fork-free) — assert byte-identity
# so the two can't silently drift.
_inline() { local sess="$1" wid="$2"; printf '%s_%s' "${sess//[^A-Za-z0-9._-]/_}" "${wid//[^0-9]/}"; }
eq "summary_key: inline reader form matches the helper" "$(fleet_summary_key 'a/b.c' @42)" "$(_inline 'a/b.c' @42)"

printf 'selftest OK: fleet-lib (%s assertions — seat incl. #118 guard, reap gate, sessmap/cache routing, 2-fleet no-leak #180, per-fleet layout #181, per-fleet sockets #159, summary-key #208)\n' "$CHECKS"
