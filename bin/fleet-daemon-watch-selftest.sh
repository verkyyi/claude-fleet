#!/bin/bash
# fleet-daemon-watch-selftest.sh — the interval-daemon liveness alarm and its
# per-unit self-heal (issue #639). Drives the REAL bin/fleet-daemon-lib.sh,
# bin/fleet-daemon-watch.sh and bin/fleet-alerts.sh's `refresh --kick` against a fake `launchctl` on
# PATH — no launchd, no tmux server, no network.
#
# WHY THIS EXISTS ON TOP OF fleet-collect-stale-selftest.sh. #636/#638 instrumented
# the collector, and two days later the same machine showed the fault is
# domain-wide: launchd stopped scheduling EVERY StartInterval unit at once, all of
# their logs freezing inside the same two minutes, while the KeepAlive units never
# missed a frame. Three properties of the generalization are easy to break
# silently and are therefore pinned here:
#
#   1. registry  — the unit table matches launchd/*.plist.tmpl EXACTLY. A daemon
#                  whose interval was retuned in its plist but not here would be
#                  judged against the wrong number, in the quiet direction.
#   2. relative  — the threshold is MULTIPLES of each unit's own StartInterval
#                  (×5, floored at 180s), not one absolute constant. The absolute
#                  600s #638 shipped is what let a collector running once per 7–14
#                  minutes read `fresh` for hours: the failure is DEGRADATION, and
#                  only a relative threshold sees it.
#   3. never     — a unit that has never ticked on this host says nothing (fresh
#                  install, or a unit this machine never had — #492).
#   4. pended    — overdue + `state = not running` ⇒ exactly one `kickstart -k` at
#                  that unit's own target, logged, stamped.
#   5. running   — overdue + `state = running` ⇒ NEVER kicked. `kickstart -k` KILLS
#                  the current invocation, so kicking a merely-slow tick would
#                  abort working work; a slow tick is exactly what a relative
#                  threshold can confuse with a pended one, and this is the guard
#                  that makes the tighter threshold safe. `--force --now` overrides.
#  15. lock      — a lock held by a live peer is respected and SURVIVES the losing
#                  kicker's exit (the trap must not free somebody else's lock);
#                  debris older than the steal timeout is taken over.
#   6. per-unit  — the rate limit is PER UNIT: a second stalled daemon is still
#                  kicked while the first one is cooling down.
#   7. scoping   — a NON-live checkout writes its stamps away from the shared
#                  global/ cache. #639's own tail: a worker testing the self-heal
#                  inside its `issue-<N>` worktree put `↻ dash kicked 7m` on the
#                  live operator's status bar, off a log that did not exist there.
#   8. status    — many units print a table; ONE unit prints the legacy
#                  fleet-collect-kick line, which is the shim's whole contract.
#   9. bar       — the aggregate `⚠ daemon stale <names>` segment, its `↻` trace
#                  after recovery, and `collect` NOT printed twice (it has its own
#                  `⚠ dash stale` segment).
#  10. stamps    — every interval daemon still stamps its own unit at the top of
#                  its script, and the ones with a non-unit invocation mode
#                  (diskguard --gate) only stamp in the mode their unit actually runs. Without this the
#                  whole alarm is silently unarmed.
#  11. off       — FLEET_DAEMON_KICK=0 kicks nothing and keeps the alarm.
#  14. dry-run   — --dry-run reports the exact remedy it WOULD apply and mutates
#                  nothing: no stamp, no fail counter, no launchctl call. It is the
#                  one mode an operator reaches for mid-incident, so a dry-run that
#                  bootstraps a unit is worse than no dry-run at all.
#  13. inflight  — a LIVE tick counts as evidence NOW, so a unit whose single
#                  phase legitimately runs for minutes (a 551s `git` phase is on
#                  record from a big monorepo fleet) is not painted stale every
#                  tick. Past the supersede deadline it stops counting: at that
#                  point the collector itself calls the tick wedged.
#  12. escalate  — a kickstart buys ONE execution, not restored scheduling: on the
#                  #639 host six of seven units logged ZERO runs over 27.8 minutes
#                  AFTER being hand-kicked. So repeated ineffective kicks escalate
#                  to a real bootout+bootstrap, the fail counter resets the moment
#                  the unit ticks again, and a reload that leaves the unit UNLOADED
#                  is retried at once instead of waiting out its cooldown.
#
# Exit 0 = pass, non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
FILES='fleet-daemon-watch.sh fleet-daemon-lib.sh usage-lib.sh fleet-alerts.sh fleet-palette.sh'
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/daemon-watch-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"   # physical path: the scripts resolve $BIN via pwd
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/.claude-dash/global" "$WORK/other/bin"
for f in $FILES; do cp "$BIN/$f" "$WORK/bin/"; done
cp "$BIN/fleet-daemon-lib.sh" "$BIN/fleet-daemon-watch.sh" "$WORK/other/bin/"
chmod +x "$WORK/bin/"*.sh "$WORK/other/bin/"*.sh
G="$WORK/.claude-dash/global"
: "${G:?G unset}"; [ -d "$G" ] || exit 2
# Every wipe below goes through this, never a bare `rm "$G"/*.tick`: an empty $G
# would expand that to `rm /*.tick`. One guarded helper is cheaper than trusting
# ten call sites (and the repo's bash guard rightly refuses the bare shape).
wipe() { [ -n "${G:-}" ] && [ -d "$G" ] && rm -f "$G"/*.tick "$G"/*.kick.ts "$G"/*.kick.fails "$G"/*.reload.ts 2>/dev/null
         [ -n "${FAKE_LC_STATE:-}" ] && [ -d "$FAKE_LC_STATE" ] && rm -f "$FAKE_LC_STATE"/*.out 2>/dev/null
         return 0; }

# --- fake launchctl -----------------------------------------------------------
# `print gui/<uid>/com.claude-fleet.<unit>` exits 113 for a unit named in
# $FAKE_UNLOADED, else prints a plist-shaped body whose TOP-LEVEL `state` is
# `running` iff the unit is named in $FAKE_RUNNING. The nested (two-tab) socket
# `state = active` lines are there on purpose: the real output has them, and a
# parser that takes the first `state` it sees anywhere would read them instead.
cat > "$WORK/fakepath/launchctl" <<'FAKE'
#!/bin/bash
# Models LOADEDNESS, not just a canned answer, because the reload path's whole
# point is the VERIFY afterwards: `bootout` takes the unit out of the domain and
# only a successful `bootstrap` puts it back, so a failed reload has to be
# observable as "print now fails" — that is the outcome worse than a pend.
S="${FAKE_LC_STATE:?}"
case "$1" in
  print)
    u="${2##*.}"
    [ -f "$S/$u.out" ] && exit 113
    case " ${FAKE_UNLOADED:-} " in *" $u "*) exit 113 ;; esac
    st='not running'
    case " ${FAKE_RUNNING:-} " in *" $u "*) st=running ;; esac
    printf 'com.claude-fleet.%s = {\n' "$u"
    printf '\tactive count = 1\n'
    printf '\tstate = %s\n' "$st"
    printf '\tsockets = {\n\t\tfd = 4\n\t\tstate = active\n\t}\n'
    printf '\truns = 2651\n\tlast exit code = 0\n}\n'
    exit 0 ;;
  kickstart) echo "$*" >> "$FAKE_KICK_LOG"; exit "${FAKE_KICK_RC:-0}" ;;
  bootout)   echo "$*" >> "$FAKE_KICK_LOG"; u="${2##*.}"; : > "$S/$u.out"; exit 0 ;;
  bootstrap) echo "$*" >> "$FAKE_KICK_LOG"
             u="$(basename "${3:-}" .plist)"; u="${u#com.claude-fleet.}"
             [ "${FAKE_BOOTSTRAP_RC:-0}" = 0 ] && rm -f "$S/$u.out"
             exit "${FAKE_BOOTSTRAP_RC:-0}" ;;
esac
exit 0
FAKE
# A host with systemd would otherwise fall through to it in the no-unit case.
printf '#!/bin/bash\nexit 1\n' > "$WORK/fakepath/systemctl"
chmod +x "$WORK/fakepath/launchctl" "$WORK/fakepath/systemctl"

export PATH="$WORK/fakepath:$PATH"
export TMPDIR="$WORK"              # every stamp read/write lands under WORK
export FLEET_LIVE_ROOT="$WORK"     # …and this work tree is "the live install"
export FAKE_KICK_LOG="$WORK/kicks.log"
export FAKE_LC_STATE="$WORK/lcstate"; mkdir -p "$FAKE_LC_STATE"
export FLEET_DAEMON_KICK_COOLDOWN=600
: > "$FAKE_KICK_LOG"
export FLEET_CONF_DIR="$WORK/conf"   # the kick log is the login's record (#4668)
KICKLOG="$FLEET_CONF_DIR/logs/daemon-kick.log"

CHECKS=0
now()  { date +%s; }
kicks() { wc -l < "$FAKE_KICK_LOG" 2>/dev/null | tr -d " " || echo 0; }

lib()   { bash -c 'set -uo pipefail; . "$1/fleet-daemon-lib.sh"; shift; eval "$@"' _ "$WORK/bin" "$@"; }
watch() { bash "$WORK/bin/fleet-daemon-watch.sh" "$@" 2>>"$WORK/watch.err"; }
# …and the same run with its stderr RETURNED (watch() files it away instead).
watch_err() { { bash "$WORK/bin/fleet-daemon-watch.sh" "$@" >/dev/null; } 2>&1; }
# The bar only COUNTS alerts since issue #1238: render it (TTL 0 = rewrite the
# alerts file every call), then print the bar, the rows, and the raw file (the
# unit names ride in the daemon row's `detail`).
bar()   { FLEET_CONF_DIR="$WORK/noconf" FLEET_ALERTS_TTL=0 bash "$WORK/bin/fleet-alerts.sh" refresh --kick >/dev/null 2>&1
          bash "$WORK/bin/fleet-alerts.sh" bar 2>/dev/null; echo; bash "$WORK/bin/fleet-alerts.sh" list --plain 2>/dev/null; cat "$G/alerts.ndjson" 2>/dev/null; }
# tick <unit> <age-seconds> — stamp a unit as last scheduled that long ago.
tick()  { printf '%s\n' "$(( $(now) - $2 ))" > "$G/$1.tick"; }

# ------------------------------------------------------------- 1. registry ----
# The table in the lib and the StartInterval in each plist template must be the
# same number, in both directions.
TMPL="$BIN/../launchd"
if [ -d "$TMPL" ]; then
  for f in "$TMPL"/com.claude-fleet.*.plist.tmpl; do
    [ -f "$f" ] || continue
    unit="$(basename "$f" .plist.tmpl)"; unit="${unit#com.claude-fleet.}"
    iv="$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9]*\)</integer>.*|\1|p' "$f" | head -1)"
    if [ -z "$iv" ]; then
      # No StartInterval ⇒ a KeepAlive unit ⇒ it must NOT be in the registry: it
      # can't be pended, and one of them (the spinner) is the hand that kicks —
      # UNLESS it is a stamping KeepAlive loop named in
      # fleet_daemon_keepalive_units (memguard, #1292: watched for a WEDGE).
      if lib 'fleet_daemon_keepalive_units' | grep -qx "$unit"; then
        lib "fleet_daemon_known $unit" \
          || st_fail "1: KeepAlive unit $unit is in fleet_daemon_keepalive_units but not in the registry"
        grep -q '<key>KeepAlive</key><true/>' "$f" \
          || st_fail "1: $unit is listed as a KeepAlive registry unit but its plist is not KeepAlive"
      else
        lib "fleet_daemon_known $unit" \
          && st_fail "1: KeepAlive unit $unit is in the interval registry"
      fi
      st_count; continue
    fi
    lib "fleet_daemon_known $unit" \
      || st_fail "1: com.claude-fleet.$unit has StartInterval=$iv but is missing from fleet_daemon_units"
    got="$(lib "fleet_daemon_interval $unit")"
    [ "$got" = "$iv" ] \
      || st_fail "1: $unit interval drifted — plist says ${iv}s, the registry says ${got}s"
    st_count
  done
  for u in $(lib 'fleet_daemon_unit_names'); do
    [ -f "$TMPL/com.claude-fleet.$u.plist.tmpl" ] \
      || st_fail "1: registry lists $u but launchd/com.claude-fleet.$u.plist.tmpl does not exist"
    st_count
  done
else
  printf 'selftest: launchd/ templates not shipped here — skipping the registry lockstep check\n' >&2
fi

# ------------------------------------------------------------- 2. relative ----
[ "$(lib 'fleet_daemon_stale_secs collect')" = 300 ]            || st_fail "2: 60s unit not 5×60"; st_count
[ "$(lib 'fleet_daemon_stale_secs memguard')" = 180 ]           || st_fail "2: 2s unit not floored at 180"; st_count
[ "$(lib 'fleet_daemon_stale_secs worktree-autoclean')" = 18000 ] || st_fail "2: 3600s unit not 5×3600"; st_count
[ "$(FLEET_DAEMON_STALE_MULT=2 lib 'fleet_daemon_stale_secs collect')" = 180 ] \
  || st_fail "2: MULT=2 on a 60s unit should floor to 180"; st_count
[ "$(FLEET_DAEMON_STALE_MULT=20 lib 'fleet_daemon_stale_secs collect')" = 1200 ] \
  || st_fail "2: MULT does not scale"; st_count
[ "$(FLEET_DAEMON_STALE_FLOOR=0 FLEET_DAEMON_STALE_MULT=2 lib 'fleet_daemon_stale_secs collect')" = 120 ] \
  || st_fail "2: FLOOR=0 does not release the floor"; st_count
[ "$(FLEET_DAEMON_STALE_BASE_SYNC=90 lib 'fleet_daemon_stale_secs base-sync')" = 90 ] \
  || st_fail "2: per-unit absolute override (dash → underscore) not honored"; st_count
# The degradation #639 measured: 401s behind a 60s interval. Relative ⇒ overdue;
# under #638's absolute 600s ⇒ fresh. If the second half ever stops holding, the
# fixture no longer reproduces the bug.
tick cleanup 401
[ -n "$(lib 'fleet_daemon_overdue cleanup '"$WORK")" ] \
  || st_fail "2: 401s behind a 60s interval still reads fresh (the #639 blind spot)"; st_count
[ -z "$(FLEET_DAEMON_STALE_CLEANUP=600 lib 'fleet_daemon_overdue cleanup '"$WORK")" ] \
  || st_fail "2: 401s should be fresh at an absolute 600s — fixture no longer reproduces #639"; st_count

# ---------------------------------------------------------------- 3. never ----
wipe
[ -z "$(lib 'fleet_daemon_overdue cleanup '"$WORK")" ] || st_fail "3: alarmed with no stamp at all"; st_count
[ "$(watch --unit cleanup --status | cut -f1)" = never ] || st_fail "3: --status not never"; st_count
watch --unit cleanup; [ "$(kicks)" -eq 0 ] || st_fail "3: kicked a unit that never ticked"; st_count
case "$(bar)" in *"daemon · stale"*) st_fail "3: bar alarmed with no stamps at all" ;; esac; st_count

# --------------------------------------------------------------- 4. pended ----
tick cleanup 900
[ "$(watch --unit cleanup --status | cut -f1)" = stale ] || st_fail "4: --status not stale"; st_count
watch --unit cleanup
[ "$(kicks)" -eq 1 ] || st_fail "4: expected exactly 1 kickstart, got $(kicks)"; st_count
grep -q 'kickstart -k gui/.*/com.claude-fleet.cleanup$' "$FAKE_KICK_LOG" \
  || st_fail "4: kicked the wrong target: $(cat "$FAKE_KICK_LOG")"; st_count
[ -f "$G/cleanup.kick.ts" ] || st_fail "4: no per-unit kick stamp"; st_count
grep -q 'kick .*unit=cleanup .*mgr=launchd.*rc=0' "$KICKLOG" \
  || st_fail "4: log line missing unit/mgr/rc: $(cat "$KICKLOG" 2>/dev/null)"; st_count

# -------------------------------------------------------------- 5. running ----
# The guard that makes the tighter threshold safe: a tick that is merely BEHIND is
# still doing the work, and kickstart -k would abort it.
#
# 400s is stale (>= the 300s threshold) but well inside the 900s WEDGED bound that
# #682 added — this section is about the SLOW half of that split, and §16 covers
# the other. It used to stamp 900s, which is now exactly the wedge threshold.
: > "$FAKE_KICK_LOG"; rm -f "$G/ledger-watch.kick.ts"
tick ledger-watch 400
FAKE_RUNNING=ledger-watch watch --unit ledger-watch
[ "$(kicks)" -eq 0 ] || st_fail "5: killed a RUNNING tick with kickstart -k"; st_count
grep -q 'slow .*unit=ledger-watch' "$KICKLOG" || st_fail "5: a slow unit was not logged: $(cat "$KICKLOG")"; st_count
[ -n "$(lib 'fleet_daemon_overdue ledger-watch '"$WORK")" ] || st_fail "5: alarm dropped for a slow unit"; st_count
# …and the deliberate override still gets through.
FAKE_RUNNING=ledger-watch watch --unit ledger-watch --force --now
[ "$(kicks)" -eq 1 ] || st_fail "5: --force --now did not override the running guard"; st_count

# ------------------------------------------------------------- 6. per-unit ----
# cleanup is inside its cooldown from §4; base-sync has never been kicked. One
# shared rate limit would swallow the second unit — that is the bug being pinned.
: > "$FAKE_KICK_LOG"
tick base-sync 900
watch --unit cleanup --unit base-sync
[ "$(kicks)" -eq 1 ] || st_fail "6: expected base-sync only (cleanup is cooling), got $(kicks)"; st_count
grep -q 'com.claude-fleet.base-sync$' "$FAKE_KICK_LOG" \
  || st_fail "6: the uncooled unit was not the one kicked: $(cat "$FAKE_KICK_LOG")"; st_count
# Past its own cooldown, cleanup is retried — stuck daemons are retried, not spun on.
printf '%s\n' "$(( $(now) - 700 ))" > "$G/cleanup.kick.ts"
: > "$FAKE_KICK_LOG"; watch --unit cleanup
[ "$(kicks)" -eq 1 ] || st_fail "6: no retry past the per-unit cooldown"; st_count

# -------------------------------------------------------------- 7. scoping ----
# $WORK/other is NOT the live root, so its watch must write its own stamps and
# leave the shared global/ cache — the one the live status bar reads — untouched.
sd_live="$(lib "fleet_daemon_state_dir $WORK")"
sd_dev="$(lib "fleet_daemon_state_dir $WORK/other")"
[ "$sd_live" = "$G" ] || st_fail "7: the live root does not resolve to global/ (got $sd_live)"; st_count
[ "$sd_dev" != "$sd_live" ] || st_fail "7: a non-live checkout shares the live state dir"; st_count
case "$sd_dev" in *"/.claude-dash/dev-"*) st_count ;; *) st_fail "7: dev state dir is not a dev- sibling: $sd_dev" ;; esac
: > "$FAKE_KICK_LOG"; rm -f "$G/ledger-watch.kick.ts"
tick ledger-watch 900
bash "$WORK/other/bin/fleet-daemon-watch.sh" --unit ledger-watch >/dev/null 2>&1
[ ! -f "$G/ledger-watch.kick.ts" ] \
  || st_fail "7: a worktree's watch wrote a kick stamp into the LIVE status bar (the #639 tail)"; st_count
[ "$(kicks)" -eq 0 ] \
  || st_fail "7: a worktree's watch read the live stamps and kicked the operator's daemon"; st_count
# A sweep may reuse its resolved directory; the next sweep must still see new
# stamps, and switching roots must still select each root's own stamp (#4444).
mkdir -p "$sd_dev"
printf '11\n' > "$G/ledger-watch.tick"
printf '22\n' > "$sd_dev/ledger-watch.tick"
# shellcheck disable=SC2016  # evaluated by lib in the child shell
scope_pair="$(lib 'for root in '"$WORK $WORK/other"'; do d=$(fleet_daemon_state_dir "$root"); fleet_daemon_tick_ts ledger-watch "$root" "$d"; printf " "; done')"
[ "$scope_pair" = '11 22 ' ] || st_fail "7: reused state directory crossed roots: $scope_pair"; st_count
printf '33\n' > "$sd_dev/ledger-watch.tick"
[ "$(lib 'fleet_daemon_tick_ts ledger-watch '"$WORK/other $sd_dev")" = 33 ] \
  || st_fail "7: reused state directory cached the stamp contents"; st_count
rm -f "$sd_dev/ledger-watch.tick"
tick ledger-watch 900

# --------------------------------------------------------------- 8. status ----
# ONE unit ⇒ the legacy fleet-collect-kick contract, 3 fields. Several ⇒ a table
# whose first column is the unit name.
one="$(watch --unit cleanup --status)"
[ "$(printf '%s' "$one" | awk -F'\t' '{print NF}')" = 3 ] \
  || st_fail "8: single-unit --status is not the legacy 3-field line: $one"; st_count
tbl="$(watch --status)"
[ "$(printf '%s\n' "$tbl" | wc -l | tr -d ' ')" = "$(lib 'fleet_daemon_unit_names' | wc -l | tr -d ' ')" ] \
  || st_fail "8: --status did not report every registry unit"; st_count
[ "$(printf '%s\n' "$tbl" | awk -F'\t' 'NR==1{print NF}')" = 6 ] \
  || st_fail "8: the --status table is not 6 columns (unit/verdict/age/threshold/kick-age/fails): $tbl"; st_count
printf '%s\n' "$tbl" | grep -q '^ledger-watch	' \
  || st_fail "8: --status table is not keyed by unit name: $tbl"; st_count

# ------------------------------------------------------------------ 9. bar ----
wipe
tick cleanup 900; tick ledger-watch 900; tick base-sync 900
out="$(FLEET_DAEMON_KICK=0 bar)"
case "$out" in *"✖ 1#"*"daemon · stale · 3 units"*'"detail":"cleanup,base-sync,ledger-watch"'*) st_count ;;
  *) st_fail "9: bar did not count the stalled units, or the row lost their names: $out" ;; esac
# collect belongs to the `dash · stale` row and must not be listed twice.
wipe
printf 'pid=1\nstart=%s\nphase=done\nphase_ts=%s\nend=%s\ndur=1\n' \
  "$(( $(now) - 900 ))" "$(( $(now) - 900 ))" "$(( $(now) - 900 ))" > "$G/collect.heartbeat"
out="$(FLEET_DAEMON_KICK=0 bar)"
case "$out" in *"dash · stale"*) st_count ;; *) st_fail "9: the collector row is gone: $out" ;; esac
case "$out" in *"daemon · stale"*) st_fail "9: collect is named in BOTH rows: $out" ;; esac; st_count
# Recovered, but recently kicked ⇒ the trace outlives the outage.
rm -f "$G/collect.heartbeat"
printf '%s\n' "$(now)" > "$G/cleanup.kick.ts"
out="$(FLEET_DAEMON_KICK=0 bar)"
case "$out" in *"↻  daemon · stale · kicked"*) st_count ;; *) st_fail "9: recovery was silent — no aggregate trace: $out" ;; esac
printf '%s\n' "$(( $(now) - 99999 ))" > "$G/cleanup.kick.ts"
out="$(FLEET_DAEMON_KICK=0 bar)"
case "$out" in *"daemon · stale"*) st_fail "9: the trace outlived its window: $out" ;; esac; st_count

# --------------------------------------------------------------- 10. stamps ----
# The alarm is only as armed as the stamps feeding it, and a daemon losing its
# stamp line is invisible — the unit just reads `never` forever.
stamps_for() { grep -c "fleet_daemon_stamp_tick $2" "$BIN/$1" 2>/dev/null || echo 0; }
for pair in 'tmux-dash-collect.sh collect' \
            'fleet-cleanup-daemon.sh cleanup' \
            'fleet-base-sync.sh base-sync' 'fleet-diskguard.sh diskguard' \
            'fleet-ledger-watch.sh ledger-watch' 'worktree-autoclean.sh worktree-autoclean' \
            'fleet-install-sync.sh install-sync' 'fleet-reconcile-tick.sh reconcile'; do
  set -- $pair
  [ "$(stamps_for "$1" "$2")" -ge 1 ] \
    || st_fail "10: $1 no longer stamps its scheduling heartbeat (unit $2) — its alarm is unarmed"; st_count
done
# One with a non-unit invocation mode must stamp ONLY in the unit's mode,
# or another daemon's tick keeps their stamp fresh while they are pended.
grep -q "case \" \$\* \" in \*' --watch '\*)" "$BIN/fleet-diskguard.sh" \
  || st_fail "10: diskguard stamps outside --watch — cleanup/base-sync call it --gate every tick"; st_count
# The lib source is GUARDED everywhere: instrumentation must not be able to kill
# the daemon it instruments if an install is ever half-synced.
for f in tmux-dash-collect.sh fleet-cleanup-daemon.sh \
         fleet-base-sync.sh fleet-diskguard.sh fleet-ledger-watch.sh \
         worktree-autoclean.sh fleet-install-sync.sh; do
  grep -q 'fleet_daemon_stamp_tick' "$BIN/$f" || st_fail "10: $f lost its stamp"
  grep -qF '[ -f "$BIN/fleet-daemon-lib.sh" ]' "$BIN/$f" \
    || st_fail "10: $f sources fleet-daemon-lib.sh UNGUARDED — a half-synced install would kill the daemon instead of just losing its alarm"; st_count
done

# ------------------------------------------------------------------ 11. off ----
wipe; : > "$FAKE_KICK_LOG"
tick cleanup 900
FLEET_DAEMON_KICK=0 watch --unit cleanup
[ "$(kicks)" -eq 0 ] || st_fail "11: kicked with FLEET_DAEMON_KICK=0"; st_count
case "$(FLEET_DAEMON_KICK=0 bar)" in *"✖  daemon · stale"*) st_count ;;
  *) st_fail "11: FLEET_DAEMON_KICK=0 also silenced the alarm" ;; esac
# …and the collector's own #638 switch still only covers the collector.
tick collect 900
FLEET_COLLECT_KICK=0 watch --unit collect --unit cleanup
[ "$(kicks)" -eq 1 ] || st_fail "11: FLEET_COLLECT_KICK=0 leaked to other units (kicks=$(kicks))"; st_count
grep -q 'com.claude-fleet.cleanup$' "$FAKE_KICK_LOG" \
  || st_fail "11: FLEET_COLLECT_KICK=0 silenced the wrong unit: $(cat "$FAKE_KICK_LOG")"; st_count

# ------------------------------------------------------------- 12. escalate ----
wipe; : > "$FAKE_KICK_LOG"
export FLEET_LAUNCHD_AGENTS_DIR="$WORK/agents"; mkdir -p "$FLEET_LAUNCHD_AGENTS_DIR"
: > "$FLEET_LAUNCHD_AGENTS_DIR/com.claude-fleet.cleanup.plist"
export FLEET_DAEMON_RELOAD_AFTER=3 FLEET_DAEMON_RELOAD_COOLDOWN=1800
# Three kicks that never bring it back — the cooldown is stepped over between
# passes exactly the way wall-clock would.
for i in 1 2 3; do
  tick cleanup 900
  watch --unit cleanup
  [ "$(lib "fleet_daemon_kick_fails cleanup $WORK")" = "$i" ] \
    || st_fail "12: fail counter did not reach $i (got $(lib "fleet_daemon_kick_fails cleanup $WORK"))"; st_count
  printf '%s\n' "$(( $(now) - 700 ))" > "$G/cleanup.kick.ts"   # step past the kick cooldown
done
[ "$(grep -c 'kickstart -k' "$FAKE_KICK_LOG")" -eq 3 ] \
  || st_fail "12: expected 3 plain kicks before escalating, got $(cat "$FAKE_KICK_LOG")"; st_count
# The fourth pass escalates instead of kicking again.
: > "$FAKE_KICK_LOG"
tick cleanup 900; watch --unit cleanup
grep -q '^bootout ' "$FAKE_KICK_LOG" || st_fail "12: no bootout on the 4th pass: $(cat "$FAKE_KICK_LOG")"; st_count
grep -q "^bootstrap gui/.* $FLEET_LAUNCHD_AGENTS_DIR/com.claude-fleet.cleanup.plist$" "$FAKE_KICK_LOG" \
  || st_fail "12: bootstrap did not name the unit's own plist: $(cat "$FAKE_KICK_LOG")"; st_count
[ "$(grep -c 'kickstart -k' "$FAKE_KICK_LOG")" -eq 0 ] \
  || st_fail "12: escalated AND kicked -k (that would kill the unit it just reloaded)"; st_count
grep -q 'reload .*unit=cleanup .*after=3 kicks' "$KICKLOG" \
  || st_fail "12: the reload was not logged with its kick count: $(cat "$KICKLOG")"; st_count
[ -f "$G/cleanup.reload.ts" ] || st_fail "12: no reload cooldown stamp"; st_count
# Its own long cooldown holds the next one back.
: > "$FAKE_KICK_LOG"
printf '%s\n' "$(( $(now) - 700 ))" > "$G/cleanup.kick.ts"
tick cleanup 900; watch --unit cleanup
grep -q '^bootout ' "$FAKE_KICK_LOG" && st_fail "12: reloaded again inside the reload cooldown"; st_count
[ "$(grep -c 'kickstart -k' "$FAKE_KICK_LOG")" -eq 1 ] \
  || st_fail "12: inside the reload cooldown it should fall back to a plain kick: $(cat "$FAKE_KICK_LOG")"; st_count
# A reload that leaves the unit UNLOADED is the worst outcome — it must be logged
# as such and NOT stamp the cooldown, so the next pass retries immediately.
wipe; : > "$FAKE_KICK_LOG"
printf '4\n' > "$G/base-sync.kick.fails"
: > "$FLEET_LAUNCHD_AGENTS_DIR/com.claude-fleet.base-sync.plist"
tick base-sync 900
FAKE_BOOTSTRAP_RC=1 watch --unit base-sync
[ -f "$FAKE_LC_STATE/base-sync.out" ] \
  || st_fail "12: the fixture did not actually leave the unit booted out"; st_count
grep -q 'reload-FAILED unit=base-sync' "$KICKLOG" \
  || st_fail "12: a reload that left the unit unloaded was not flagged: $(cat "$KICKLOG")"; st_count
[ ! -f "$G/base-sync.reload.ts" ] \
  || st_fail "12: a FAILED reload stamped its cooldown — the unit would stay unloaded for 30m"; st_count
# The next pass retries at once — no reload cooldown to wait out, because a unit
# that is merely NOT LOADED has a lighter remedy than a reload: bootstrap it back
# from the plist that is sitting right there. Without that branch a failed reload
# is a one-way door (probe says "absent", so the reload path is never reached).
: > "$FAKE_KICK_LOG"
printf '%s\n' "$(( $(now) - 700 ))" > "$G/base-sync.kick.ts"
tick base-sync 900; watch --unit base-sync
[ ! -f "$FAKE_LC_STATE/base-sync.out" ] || st_fail "12: the retry did not bring the unit back"; st_count
grep -q 'bootstrap unit=base-sync' "$KICKLOG" \
  || st_fail "12: the recovery was not logged as a bootstrap: $(cat "$KICKLOG")"; st_count
grep -q 'kickstart -k' "$FAKE_KICK_LOG" \
  && st_fail "12: kickstart -k on a unit that was not loaded (nothing to kill)"; st_count
# And the ladder resets the moment the unit ticks again.
tick base-sync 5; watch --unit base-sync
[ "$(lib "fleet_daemon_kick_fails base-sync $WORK")" = 0 ] \
  || st_fail "12: the fail counter survived a recovery — one bad afternoon would arm a reload forever"; st_count
# FLEET_DAEMON_RELOAD_AFTER=0 disables the escalation entirely.
wipe; : > "$FAKE_KICK_LOG"
printf '9\n' > "$G/cleanup.kick.fails"
tick cleanup 900
FLEET_DAEMON_RELOAD_AFTER=0 watch --unit cleanup
grep -q '^bootout ' "$FAKE_KICK_LOG" && st_fail "12: RELOAD_AFTER=0 still escalated"; st_count
[ "$(grep -c 'kickstart -k' "$FAKE_KICK_LOG")" -eq 1 ] || st_fail "12: RELOAD_AFTER=0 stopped kicking too"; st_count

# ------------------------------------------------------------- 13. inflight ----
# A relative threshold is only safe if a long-but-working tick is not mistaken for
# a pended one. The collector's phase heartbeat advances at phase BOUNDARIES, so a
# single slow phase looks identical to silence — its overlap-guard pid file is what
# tells them apart, and without this the monorepo fleet would read `⚠ dash stale`
# through every tick of a 551s git phase.
wipe
printf 'start=%s\nphase=git\nphase_ts=%s\n' \
  "$(( $(now) - 900 ))" "$(( $(now) - 900 ))" > "$G/collect.heartbeat"
[ -n "$(lib "fleet_daemon_overdue collect $WORK")" ] \
  || st_fail "13: a 900s-silent heartbeat with no tick in flight should be overdue"; st_count
printf '%s\t%s\n' "$$" "$(( $(now) - 400 ))" > "$G/collect.pid"
[ -z "$(lib "fleet_daemon_overdue collect $WORK")" ] \
  || st_fail "13: a LIVE tick 400s in (deadline 600s) was still called stale"; st_count
printf '%s\t%s\n' "$$" "$(( $(now) - 900 ))" > "$G/collect.pid"
[ -n "$(lib "fleet_daemon_overdue collect $WORK")" ] \
  || st_fail "13: a tick past the supersede deadline still counted as alive"; st_count
printf '999999\t%s\n' "$(( $(now) - 100 ))" > "$G/collect.pid"
[ -n "$(lib "fleet_daemon_overdue collect $WORK")" ] \
  || st_fail "13: a pid file naming a DEAD process counted as alive"; st_count
rm -f "$G/collect.pid" "$G/collect.heartbeat"
# Only `collect` has a pid guard; the plain-tick units must not grow one silently.
[ "$(lib 'fleet_daemon_field collect 3')" = 'hb:collect.heartbeat,pid:collect.pid' ] \
  || st_fail "13: collect's evidence sources changed: $(lib 'fleet_daemon_field collect 3')"; st_count
[ "$(lib 'fleet_daemon_field cleanup 3')" = tick ] \
  || st_fail "13: cleanup grew an evidence source it has no writer for"; st_count

# -------------------------------------------------------------- 14. dry-run ----
dry_is_inert() {  # $1 = unit, $2 = expected word in the report
  : > "$FAKE_KICK_LOG"
  out="$(watch_err --unit "$1" --dry-run)"
  case "$out" in *"$2"*) st_count ;; *) st_fail "14: $1 dry-run did not report '$2': $out" ;; esac
  [ ! -s "$FAKE_KICK_LOG" ] || st_fail "14: $1 dry-run called launchctl: $(cat "$FAKE_KICK_LOG")"; st_count
  [ ! -f "$G/$1.kick.ts" ]    || st_fail "14: $1 dry-run wrote a kick stamp"; st_count
  [ ! -f "$G/$1.kick.fails" ] || st_fail "14: $1 dry-run wrote a fail counter"; st_count
  [ ! -f "$G/$1.reload.ts" ]  || st_fail "14: $1 dry-run wrote a reload stamp"; st_count
  [ ! -d "$G/$1.kick.lock" ]  || st_fail "14: $1 dry-run left its lock behind"; st_count
}
# plain pend → would kick
wipe; tick cleanup 900
dry_is_inert cleanup 'would kick'
# already kicked to no effect → would escalate
wipe; tick cleanup 900; printf '5\n' > "$G/cleanup.kick.fails"
: > "$FAKE_KICK_LOG"
out="$(watch_err --unit cleanup --dry-run)"
case "$out" in *'would RELOAD'*) st_count ;; *) st_fail "14: dry-run did not report the escalation: $out" ;; esac
[ ! -s "$FAKE_KICK_LOG" ] || st_fail "14: the escalation dry-run called launchctl: $(cat "$FAKE_KICK_LOG")"; st_count
[ "$(cat "$G/cleanup.kick.fails")" = 5 ] || st_fail "14: dry-run advanced the fail counter"; st_count
# not loaded but the plist is there → would bootstrap, and MUST NOT actually do it
wipe; tick base-sync 900
: > "$FLEET_LAUNCHD_AGENTS_DIR/com.claude-fleet.base-sync.plist"
: > "$FAKE_LC_STATE/base-sync.out"          # pretend it was booted out
dry_is_inert base-sync 'would BOOTSTRAP'
[ -f "$FAKE_LC_STATE/base-sync.out" ] || st_fail "14: dry-run actually bootstrapped the unit"; st_count
# a running tick → would not touch it (400s: stale, but inside the 900s wedge
# bound #682 added — §16 covers the dry-run report for a WEDGED unit)
wipe; tick ledger-watch 400
: > "$FAKE_KICK_LOG"
out="$(FAKE_RUNNING=ledger-watch watch_err --unit ledger-watch --dry-run)"
case "$out" in *'would NOT touch it'*) st_count ;; *) st_fail "14: dry-run on a running unit: $out" ;; esac
[ ! -s "$FAKE_KICK_LOG" ] || st_fail "14: dry-run touched a running unit"; st_count

# ----------------------------------------------------------------- 15. lock ----
wipe; : > "$FAKE_KICK_LOG"
tick cleanup 900
mkdir -p "$G/cleanup.kick.lock"; now > "$G/cleanup.kick.lock/ts"      # a live peer
watch --unit cleanup
[ "$(kicks)" -eq 0 ] || st_fail "15: kicked while a peer held the lock"; st_count
[ -d "$G/cleanup.kick.lock" ] \
  || st_fail "15: the LOSING kicker deleted the winner's lock on its way out (EXIT trap aimed at a lock it never owned)"; st_count
printf '%s\n' "$(( $(now) - 200 ))" > "$G/cleanup.kick.lock/ts"      # debris, not a peer
watch --unit cleanup
[ "$(kicks)" -eq 1 ] || st_fail "15: stale lock debris was not taken over"; st_count
[ ! -d "$G/cleanup.kick.lock" ] || st_fail "15: the winning kicker left its own lock behind"; st_count

# --------------------------------------------------------------- 16. wedged ----
# #639 made "a RUNNING unit is never kicked" absolute, and #682 is the bill: on
# 2026-09-15 collect and quotawatch each sat `state = running` and frozen for ~54
# minutes. `--status` correctly called both stale, the alarm was accurate, and the
# self-heal stood down BY DESIGN while the dash served 53-minute-old data with
# nothing left that could recover it.
#
# The split is by DURATION, not by liveness: past fleet_daemon_wedged_secs (3x the
# unit's own stale threshold) a RUNNING unit has stopped advancing its heartbeat
# for three whole alarm windows, and takes the ordinary ladder. §5 pins the slow
# half; this pins the wedged half and the knob that turns it off.
wipe; : > "$FAKE_KICK_LOG"; : > "$KICKLOG"

# the threshold itself, and both knobs
[ "$(lib 'fleet_daemon_wedged_secs collect')" = 900 ]   || st_fail "16: collect's wedge bound is not 3x its 300s stale threshold"; st_count
[ "$(FLEET_DAEMON_WEDGED_MULT=2 lib 'fleet_daemon_wedged_secs collect')" = 600 ]   || st_fail "16: FLEET_DAEMON_WEDGED_MULT does not retune the bound"; st_count
[ "$(FLEET_DAEMON_WEDGED_MULT=0 lib 'fleet_daemon_wedged_secs collect')" = 0 ]   || st_fail "16: MULT=0 must disable the wedge verdict"; st_count
[ "$(FLEET_DAEMON_WEDGED_LEDGER_WATCH=360 lib 'fleet_daemon_wedged_secs ledger-watch')" = 360 ]   || st_fail "16: a per-unit override must win outright"; st_count

# RUNNING + stale past the bound ⇒ healed, and said so in the log
tick ledger-watch 1200
FAKE_RUNNING=ledger-watch watch --unit ledger-watch
[ "$(kicks)" -eq 1 ]   || st_fail "16: a RUNNING unit frozen for 1200s was not healed — this is the #682 stand-down"; st_count
grep -q 'wedged .*unit=ledger-watch' "$KICKLOG"   || st_fail "16: the wedge verdict was not logged: $(cat "$KICKLOG")"; st_count

# …and the knob restores the pre-#682 hands-off guard exactly.
wipe; : > "$FAKE_KICK_LOG"; : > "$KICKLOG"
tick ledger-watch 1200
FLEET_DAEMON_WEDGED_MULT=0 FAKE_RUNNING=ledger-watch watch --unit ledger-watch
[ "$(kicks)" -eq 0 ]   || st_fail "16: FLEET_DAEMON_WEDGED_MULT=0 must never touch a running unit"; st_count
grep -q 'slow .*unit=ledger-watch' "$KICKLOG"   || st_fail "16: with the knob off a frozen unit must still log as slow"; st_count

# The dry-run verdict and the real one must not be able to disagree (they are
# decided in one place, beside do_reload).
wipe; : > "$FAKE_KICK_LOG"; : > "$KICKLOG"
tick ledger-watch 1200
case "$(FAKE_RUNNING=ledger-watch watch_err --unit ledger-watch --dry-run)" in
  *"RUNNING but WEDGED"*) st_count ;;
  *) st_fail "16: --dry-run does not report the wedge verdict the real run acts on" ;;
esac
[ "$(kicks)" -eq 0 ] || st_fail "16: --dry-run kicked"; st_count

# --- fleet_daemon_fair_budget (issue #850) ------------------------------------
# Pure arithmetic: an even, adaptive, floored, capped split of a tick's remaining
# budget across the fleets still to visit.
fb() { lib "fleet_daemon_fair_budget $1 $2 ${3:-5}"; }
[ "$(fb 60 3)" = 20 ] || st_fail "fair_budget: 60s across 3 fleets is 20 each"; st_count
[ "$(fb 40 2)" = 20 ] || st_fail "fair_budget: leftover after the first fleet is re-divided (40/2=20)"; st_count
[ "$(fb 20 1)" = 20 ] || st_fail "fair_budget: the last fleet gets all that remains"; st_count
[ "$(fb 12 5)" = 5  ] || st_fail "fair_budget: a thin slice is floored to 5s"; st_count
[ "$(fb 3 1)"  = 3  ] || st_fail "fair_budget: the floor never exceeds what remains"; st_count
[ "$(fb 30 0)" = 30 ] || st_fail "fair_budget: a zero divisor is treated as one"; st_count
[ "$(fb x 3)"  = 0  ] || st_fail "fair_budget: garbage remaining is 0, and 0 caps the floor to 0"; st_count
[ "$(fb 60 3 15)" = 20 ] || st_fail "fair_budget: an explicit floor below the share is inert"; st_count
[ "$(fb 10 3 15)" = 10 ] || st_fail "fair_budget: an explicit floor is still capped at what remains"; st_count

printf 'selftest PASS: %s assertions (registry · relative · never · pended · running · per-unit · scoping · status · bar · stamps · off · escalate · inflight · dry-run · lock · wedged · fair-budget)\n' "$CHECKS"
exit 0
