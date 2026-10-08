#!/bin/bash
# fleet-release-selftest.sh — `fleet release` (bin/fleet-release.sh, issue #2483,
# EPIC #2482 C3): six steps, each checked, stopping at the first that fails.
#
# A sandbox origin (bare repo, three commits on master, stable at the first), the
# REAL bin/fleet-stable.sh as step ②, and fakes for everything past GitHub: a gh
# on PATH (canned check runs / macOS runs per commit), a hub whose /version reads
# the sandbox's stable tag, a /v1/nodes with m4 · m5 (this machine) · a lost m7,
# machines whose version is a file the KICK writes, a local install-sync that
# writes its state file, a doctor that prints an install row.
#
#   A. --dry-run lists the six steps ①…⑥, exit 0: nothing pushed, nothing kicked,
#      nothing synced, no log line.
#   B. CI red (a check run failed) → exit 3, the check is NAMED, stable unmoved,
#      log result=refused:ci. A red macOS run → exit 3 with its run URL.
#   C. a release: stable moves, the hub follows, m4 is kicked and follows, the lost
#      m7 is named and not waited for, this machine syncs and its doctor PASSes →
#      exit 0, ①–⑥ each one line, log result=released with m4@<n>s.
#   D. --rollback moves stable back to the log's `from`, log result=rollback.
#   E. a machine that never follows → exit 5 naming it and the rollback command,
#      log result=failed:machines; stable stays where ② put it.
#   F. this machine's install-sync rejects the version (rolled-back) → stable is
#      moved back on its own, exit 5, log result=rolled-back.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$BIN/fleet-release.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-release-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

d="$WORK"; mkdir -p "$d/shim" "$d/home" "$d/conf/global" "$d/seed"
export HOME="$d/home" FLEET_CONF_DIR="$d/conf"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CCQUOTA_VIEWER_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_RELEASE_MACHINES 2>/dev/null

git init -q --bare -b master "$d/origin.git" && git clone -q "$d/origin.git" "$d/seed" 2>/dev/null || { echo "FAIL  rig"; exit 1; }
mkdir -p "$d/seed/.github/workflows"; echo 'name: selftests (macOS)' > "$d/seed/.github/workflows/selftests-macos.yml"
for i in 1 2 3; do
  echo "$i" > "$d/seed/f"; git -C "$d/seed" add -A && git -C "$d/seed" commit -qm "c$i" || exit 1
  git -C "$d/seed" rev-parse HEAD > "$d/c$i"
done
git -C "$d/seed" push -q origin HEAD:master || exit 1
c1=$(cat "$d/c1") c2=$(cat "$d/c2") c3=$(cat "$d/c3")
git --git-dir="$d/origin.git" update-ref refs/tags/stable "$c1"
git clone -q "$d/origin.git" "$d/co" 2>/dev/null || exit 1
stable() { git --git-dir="$d/origin.git" rev-parse refs/tags/stable; }

# gh: check runs per commit from $d/checks.<sha> (tab form; default: two green),
# the macOS runs from $d/macruns. fleet-release asks with a tab-joined --jq,
# fleet-stable with a space-joined one — the shim answers each in its own form.
cat > "$d/shim/gh" <<SH
#!/bin/bash
args="\$*"
case "\$args" in
  *check-runs*)
    sha=\$(printf '%s' "\$args" | sed -n 's#.*commits/\([0-9a-f]*\)/check-runs.*#\1#p')
    f="$d/checks.\$sha"; [ -f "\$f" ] || f="$d/checks.default"
    case "\$args" in *'\\t'*) cat "\$f" ;; *) tr '\t' ' ' < "\$f" ;; esac ;;
  *actions/workflows/*) cat "$d/macruns" 2>/dev/null ;;
  *) exit 1 ;;
esac
SH
chmod +x "$d/shim/gh"
printf 'completed\tsuccess\tselftests (shard 1)\ncompleted\tsuccess\tlint\n' > "$d/checks.default"
macgreen() { : > "$d/macruns"; for s in "$@"; do printf '%s\tcompleted\tsuccess\tpush\t%s\tselftests (macOS)\n' "$s" "${s:0:6}" >> "$d/macruns"; done; }

# the hub, the roster, the machines, this machine
printf '#!/bin/sh\nprintf "{\\"stable\\": \\"%%s\\"}" "$(git --git-dir=%s rev-parse refs/tags/stable)"\n' "$d/origin.git" > "$d/hubver"
cat > "$d/nodes.json" <<'J'
{"machines": [{"hostname": "m4host.local", "alias": "m4", "status": "online"},
              {"hostname": "m5host", "alias": "m5", "status": "online"},
              {"hostname": "m7host", "alias": "m7", "status": "lost"},
              {"hostname": "laptop", "status": "online", "personal": true}],
 "nodes": [{"hostname": "m4host.local", "fleet_version": "0000000", "last_heartbeat": "2026-10-08T00:00:00Z"}]}
J
printf '#!/bin/sh\ncat "%s/ver.$1" 2>/dev/null\n' "$d" > "$d/verof"
# a kick: the machine follows stable at once (unless it is $d/stuck.<m>)
printf '#!/bin/sh\necho "$1" >> "%s/kicked"\n[ -f "%s/stuck.$1" ] || git --git-dir=%s rev-parse refs/tags/stable > "%s/ver.$1"\n' "$d" "$d" "$d/origin.git" "$d" > "$d/kick"
# the local install-sync: follows stable (result switched), or rejects it when $d/reject exists
cat > "$d/sync" <<SH
#!/bin/sh
echo run >> "$d/synced"
st=\$(git --git-dir=$d/origin.git rev-parse refs/tags/stable)
if [ -f "$d/reject" ]; then
  printf 'result: rolled-back\nhead: %s\nreason: the doctor printed a new FAIL\n' "\$(cat $d/localhead)" > "$d/conf/global/install-sync.state"
else
  printf 'result: switched\nhead: %s\nreason: install at stable\n' "\$st" > "$d/conf/global/install-sync.state"
  echo "\$st" > "$d/localhead"
fi
SH
printf '#!/bin/sh\necho "  PASS  fleet    x"\necho "  PASS  install  live at x — up to date with origin/master"\n' > "$d/doctor"
chmod +x "$d/hubver" "$d/verof" "$d/kick" "$d/sync" "$d/doctor"
echo "$c1" > "$d/localhead"

run() {   # run <args…> — fleet-release in the sandbox; OUT + RC
  OUT=$(PATH="$d/shim:$PATH" FLEET_RELEASE_LOG="$d/release.log" FLEET_RELEASE_HOST=m5host \
    FLEET_RELEASE_VERSION_CMD="$d/hubver" FLEET_RELEASE_NODES_CMD="cat $d/nodes.json" \
    FLEET_RELEASE_VERSION_OF_CMD="$d/verof" FLEET_RELEASE_KICK_CMD="$d/kick" \
    FLEET_RELEASE_SYNC_CMD="$d/sync" FLEET_RELEASE_DOCTOR_CMD="$d/doctor" \
    FLEET_RELEASE_SYNC_STATE="$d/conf/global/install-sync.state" FLEET_RELEASE_POLL=1 \
    FLEET_STABLE_LOG="$d/stable-move.log" \
    bash "$REL" --dir "$d/co" --repo o/r "$@" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
lastlog() { tail -n 1 "$d/release.log" 2>/dev/null; }
echo "$c1" > "$d/ver.m4"

# ── A. --dry-run lists the six steps ──
macgreen "$c2"
run --to "$c2" --dry-run
n=0; for s in ① ② ③ ④ ⑤ ⑥; do printf '%s\n' "$OUT" | grep -q "^$s " && n=$((n + 1)); done
if [ "$RC" = 0 ] && [ "$n" = 6 ]; then ok "A dry-run lists the six steps"; else bad "A dry-run rc=$RC steps=$n: $OUT"; fi
{ [ "$(stable)" = "$c1" ] && [ ! -f "$d/kicked" ] && [ ! -f "$d/synced" ] && [ ! -f "$d/release.log" ]; } \
  && ok "A dry-run pushed, kicked, synced and logged nothing" || bad "A dry-run changed something"
has 'm4=' && ! has 'm5=' && has 'm7（lost）' && ok "A ④ waits on m4, not on this machine (m5), names the lost m7" \
  || bad "A ④ machine list: $(printf '%s\n' "$OUT" | grep '④')"

# ── B. CI red → exit 3, named ──
printf 'completed\tsuccess\tlint\ncompleted\tfailure\tselftests (shard 3)\n' > "$d/checks.$c2"
run --to "$c2"
{ [ "$RC" = 3 ] && has 'selftests (shard 3) (failure)' && [ "$(stable)" = "$c1" ]; } \
  && ok "B a red check refuses (exit 3) and is named" || bad "B red check: rc=$RC $OUT"
case "$(lastlog)" in *result=refused:ci*) ok "B logged refused:ci" ;; *) bad "B log: $(lastlog)" ;; esac
rm -f "$d/checks.$c2"
printf '%s\tcompleted\tfailure\tpush\t4242\tselftests (macOS)\n' "$c2" > "$d/macruns"
run --to "$c2"
{ [ "$RC" = 3 ] && has 'actions/runs/4242' && [ "$(stable)" = "$c1" ]; } \
  && ok "B a red macOS run refuses (exit 3) with its URL" || bad "B red macOS: rc=$RC $OUT"

# ── C. a release ──
macgreen "$c2"
run --to "$c2"
n=0; for s in ① ② ③ ④ ⑤ ⑥; do printf '%s\n' "$OUT" | grep -q "^$s " && n=$((n + 1)); done
{ [ "$RC" = 0 ] && [ "$n" = 6 ] && [ "$(stable)" = "$c2" ]; } && ok "C released: six lines, stable moved" \
  || bad "C release rc=$RC steps=$n stable=$(stable): $OUT"
grep -qx m4 "$d/kicked" 2>/dev/null && ! grep -q m7 "$d/kicked" && ok "C kicked m4 (not the lost m7)" || bad "C kicks: $(cat "$d/kicked" 2>/dev/null)"
case "$(lastlog)" in *result=released*machines=m4@*) ok "C logged released with m4's arrival" ;; *) bad "C log: $(lastlog)" ;; esac

# ── D. --rollback ──
run --rollback
{ [ "$RC" = 0 ] && [ "$(stable)" = "$c1" ]; } && ok "D --rollback moved stable back to the log's from" || bad "D rollback rc=$RC: $OUT"
case "$(lastlog)" in *result=rollback*) ok "D logged rollback" ;; *) bad "D log: $(lastlog)" ;; esac

# ── E. a machine that never follows ──
touch "$d/stuck.m4"; echo "$c1" > "$d/ver.m4"
run --to "$c2" --machines-timeout 2
{ [ "$RC" = 5 ] && has 'm4（在' && has 'fleet release --rollback' && [ "$(stable)" = "$c2" ]; } \
  && ok "E a machine that never follows: exit 5, named, rollback said" || bad "E rc=$RC: $OUT"
case "$(lastlog)" in *result=failed:machines*m4:timeout*) ok "E logged failed:machines" ;; *) bad "E log: $(lastlog)" ;; esac
rm -f "$d/stuck.m4"

# ── F. this machine rejects the version → stable moved back on its own ──
macgreen "$c3"; touch "$d/reject"
run --to "$c3"
{ [ "$RC" = 5 ] && has '自动退回' && [ "$(stable)" = "$c2" ]; } \
  && ok "F local rejection rolled stable back by itself" || bad "F rc=$RC stable=$(stable): $OUT"
case "$(lastlog)" in *result=rolled-back*) ok "F logged rolled-back" ;; *) bad "F log: $(lastlog)" ;; esac

[ "$fails" -eq 0 ] && { echo "PASS fleet-release-selftest"; exit 0; }
echo "FAIL fleet-release-selftest: $fails"; exit 1
