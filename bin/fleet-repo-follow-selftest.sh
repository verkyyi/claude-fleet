#!/bin/bash
# fleet-repo-follow-selftest.sh — T673 (节点选择 C): a managed machine adds the repos
# its person's machines host, only ever adding, a failed add retried without
# blocking the others; the doctor's rows read its record.
#
# Drives bin/fleet-repo-follow.py through its two seams (FLEET_REPO_FOLLOW_HUB_CMD
# — the hub's /v1/node/repos answer; FLEET_REPO_FOLLOW_ADD_CMD — a fake
# `fleet-repo.sh` that writes the overlay the real one would) in a sandbox
# FLEET_CONF_DIR; the local set is read by fleet_repos (bin/fleet-lib.sh) as the
# real road does. bin/fleet-base-sync.sh calls the tick; bin/fleet-doctor.sh
# reads `status --doctor`.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/repo-follow-st.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

export FLEET_CONF_DIR="$T/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/fleet/repos"
: > "$FLEET_CONF_DIR/fleets/fleet/conf"
overlay() { # <owner/repo>
  local slug="${1//\//-}"
  printf 'FLEET_REPO=%s\n' "$1" > "$FLEET_CONF_DIR/fleets/fleet/repos/$slug.conf"
  printf '%s\n' "$slug" >> "$FLEET_CONF_DIR/fleets/fleet/repos/.order"
}
overlay a/one

# The hub's answer: role + the person's set, from a file the legs rewrite.
answer() { # <role> <repo>...
  local role="$1"; shift
  python3 - "$role" "$@" > "$T/answer.json" <<'PY'
import json, sys
role, repos = sys.argv[1], sys.argv[2:]
print(json.dumps({"owner": "gh:1", "role": role, "repos": repos,
                  "machines": [{"hostname": "mac-a", "login": "alice", "self": True, "repos": ["a/one"], "starts_24h": 3},
                               {"hostname": "mac-b", "login": "alice", "repos": repos, "starts_24h": 1}]}))
PY
}
export FLEET_REPO_FOLLOW_HUB_CMD="echo x >> '$T/hub.calls'; cat '$T/answer.json'"

# The fake fleet-repo.sh: every call logged; bad/* fails like a clone that could not.
cat > "$T/fake-repo.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/add.calls"
[ "\$1" = add ] || exit 2
repo="\${@: -1}"
case "\$repo" in
  bad/*) echo "fleet-repo: clone of \$repo failed: repository not found" >&2; echo failed:clone; exit 1 ;;
esac
slug="\${repo//\//-}"
printf 'FLEET_REPO=%s\n' "\$repo" > "$FLEET_CONF_DIR/fleets/fleet/repos/\$slug.conf"
printf '%s\n' "\$slug" >> "$FLEET_CONF_DIR/fleets/fleet/repos/.order"
echo "added:\$slug"
SH
chmod +x "$T/fake-repo.sh"
export FLEET_REPO_FOLLOW_ADD_CMD="bash $T/fake-repo.sh"
export FLEET_REPO_FOLLOW_SECS=600
RF() { python3 "$BIN/fleet-repo-follow.py" "$@"; }
hosted() { bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1 && fleet_repos fleet' _ "$BIN" | tr '\n' ' '; }
st() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$FLEET_CONF_DIR/repo-follow.json" "$1"; }

# A — managed: what the person's machines host and this one lacks is added; a
# failing clone is written down and does not stop the next repo.
answer managed a/one bad/repo b/two
RF tick
chk "A added the missing repo, kept the hosted one" '[ "$(hosted)" = "a/one b/two " ]'
chk "A the failing repo is recorded with its reason" '[ "$(st "d[\"failed\"][\"bad/repo\"][\"reason\"]")" = "failed:clone — fleet-repo: clone of bad/repo failed: repository not found" ]'
chk "A it did not block the repo after it" 'grep -q "add --session fleet b/two" "$T/add.calls"'
chk "A missing is only the failed one" '[ "$(st "\",\".join(d[\"missing\"])")" = bad/repo ]'

# B — the set grows by one ⇒ the next round registers it here; the failed one is
# retried that round (its first retry waits for no backoff).
answer managed a/one bad/repo b/two c/three
FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "B the new repo is registered on the next round" '[ "$(hosted)" = "a/one b/two c/three " ]'
chk "B the failed repo was retried" '[ "$(st "d[\"failed\"][\"bad/repo\"][\"tries\"]")" = 2 ]'
chk "B a second failure backs off" '[ "$(st "d[\"failed\"][\"bad/repo\"][\"next\"] > d[\"checked\"]")" = True ]'

# C — throttled: a fresh record means no hub read this tick.
n=$(wc -l < "$T/hub.calls")
RF tick
chk "C a tick inside FLEET_REPO_FOLLOW_SECS does not ask the hub" '[ "$(wc -l < "$T/hub.calls")" = "$n" ]'

# D — only ever adds: a repo the person's set no longer names stays hosted, and
# nothing ever calls remove.
answer managed a/one
FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "D a repo gone from the set stays hosted here" '[ "$(hosted)" = "a/one b/two c/three " ]'
chk "D no remove is ever run" '! grep -q "^remove" "$T/add.calls"'
chk "D a repo no longer missing is no longer failing" '[ "$(st "d[\"failed\"]")" = "{}" ]'

# E — not managed (a client, an untyped login): nothing is added.
answer client a/one d/four
FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "E a client adds nothing" '! grep -q "d/four" "$T/add.calls"'
chk "E its record says why" 'RF status --doctor | grep -q "^info	跟仓库	不跟：not managed (role=client)"'
answer "" a/one d/four
FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "E an untyped login adds nothing" '! grep -q "d/four" "$T/add.calls"'

# F — the doctor's rows: the gap, why, and where the sessions went.
answer managed a/one b/two c/three bad/repo
FLEET_REPO_FOLLOW_SECS=0 RF tick
out=$(RF status --doctor)
chk "F the gap line names the missing repo" 'printf "%s\n" "$out" | grep -q "^gap		bad/repo$"'
chk "F 跟仓库 says what did not get added" 'printf "%s\n" "$out" | grep -q "^warn	跟仓库	缺 1 个：bad/repo；没加上：bad/repo — failed:clone"'
chk "F 分到 lists the last 24 hours per machine" 'printf "%s\n" "$out" | grep -q "^info	分到	近 24 小时 hub 分到各台的会话：mac-a（本机） 3 · mac-b 1$"'

# G — the hub not answering is written down and adds nothing; off is off.
FLEET_REPO_FOLLOW_HUB_CMD='echo "入口不通" >&2; exit 4' FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "G an unreachable hub is recorded" '[ "$(st "d[\"error\"]")" = "入口不通" ]'
n=$(wc -l < "$T/hub.calls")
FLEET_REPO_FOLLOW=0 FLEET_REPO_FOLLOW_SECS=0 RF tick
chk "G FLEET_REPO_FOLLOW=0 asks nothing" '[ "$(wc -l < "$T/hub.calls")" = "$n" ]'

# H — the callers: base-sync runs the tick, the doctor reads the record.
chk "H base-sync calls the tick" 'grep -q "fleet-repo-follow.py\" tick" "$BIN/fleet-base-sync.sh"'
chk "H the doctor reads status --doctor" 'grep -q "fleet-repo-follow.py\" status --doctor" "$BIN/fleet-doctor.sh"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
