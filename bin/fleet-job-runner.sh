#!/bin/sh
# fleet-job-runner.sh — what a throwaway Job runs (issue #3552, EPIC #3500 C7).
#
# render.py's Job starts it as `/bin/sh <this>` in the managed-node image, as
# uid 10001 on a read-only root, with /work and /tmp its only writable places,
# no token, no home disk and no key of anyone's. From its environment:
#
#   FLEET_JOB_MIRROR  where the commit is fetched from (the cluster's git
#                     mirror, the repo's URL); empty = no checkout, run in /work
#   FLEET_JOB_REF     the 40-hex commit
#   FLEET_JOB_CMD     the one command line, run by `sh -c` in the checkout
#   FLEET_CLUSTER_CACHES / FLEET_EGRESS_PROXY
#                     npm / pip / Go from the cluster's caches, HTTPS_PROXY
#                     (an open kind only) — the same settings a person's pod
#                     gets, from fleet-node-linux.py's devnet_settings
#
# It writes everything to stdout — the Job's log is the one channel back
# (fleet-ops reads it, the hub relays it to `fleet job`). What the command
# leaves in $FLEET_JOB_OUT (/work/out) comes last, as one gzipped tar in base64
# between two marker lines, at most FLEET_JOB_OUT_MAX bytes (4 MiB) packed:
#
#   ::fleet-job:: artifacts <bytes>
#   <base64 lines>
#   ::fleet-job:: artifacts-end
#   ::fleet-job:: exit <rc>
#
# Exit: the command's own exit; 90 the checkout failed.
set -u
say() { printf '::fleet-job:: %s\n' "$*"; }
here=$(cd "$(dirname "$0")" && pwd)
work=${FLEET_JOB_WORK:-/work}   # a seam for the selftest
out=$work/out
mkdir -p "$out" "$work/src" || { say "error: $work is not writable"; say "exit 90"; exit 90; }
export FLEET_JOB_OUT="$out"

# the cluster's package caches and egress, one source with a person's pod
if [ -n "${FLEET_CLUSTER_CACHES:-}${FLEET_EGRESS_PROXY:-}" ] && [ -f "$here/fleet-node-linux.py" ] \
   && command -v python3 >/dev/null 2>&1; then
  envs=$(python3 -I - "$here/fleet-node-linux.py" <<'PY' 2>/dev/null
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('fnl', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.stdout.write(m.devnet_settings(os.environ)[1])
PY
) || envs=''
  # each line is KEY=VALUE, VALUE a URL or a host list (no space, no quote)
  while IFS='=' read -r k v; do
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    export "$k=$v"
  done <<EOF
$envs
EOF
fi

cd "$work/src" || exit 90
if [ -n "${FLEET_JOB_MIRROR:-}" ]; then
  say "fetch ${FLEET_JOB_REPO:-?} ${FLEET_JOB_REF:-?}"
  git init -q . && git remote add origin "$FLEET_JOB_MIRROR" || { say "exit 90"; exit 90; }
  # one commit by its sha; a mirror that serves only refs takes a whole fetch
  if ! git fetch -q --depth 1 origin "$FLEET_JOB_REF" 2>/dev/null; then
    git fetch -q origin '+refs/heads/*:refs/remotes/origin/*' || { say "error: fetch from the mirror failed"; say "exit 90"; exit 90; }
  fi
  git -c advice.detachedHead=false checkout -q "$FLEET_JOB_REF" \
    || { say "error: commit $FLEET_JOB_REF is not on the mirror (pushed?)"; say "exit 90"; exit 90; }
fi

say "run ${FLEET_JOB_KIND:-?}: ${FLEET_JOB_CMD:-}"
sh -c "${FLEET_JOB_CMD:-true}" 2>&1
rc=$?

if [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
  pack=${TMPDIR:-/tmp}/fleet-job-out.$$.tgz
  tar -C "$out" -czf "$pack" . 2>/dev/null
  n=$(wc -c < "$pack" | tr -d ' ')
  if [ "$n" -le "${FLEET_JOB_OUT_MAX:-4194304}" ]; then
    say "artifacts $n"
    base64 < "$pack"
    say "artifacts-end"
  else
    say "artifacts dropped: $n bytes packed, over ${FLEET_JOB_OUT_MAX:-4194304}"
  fi
fi
say "exit $rc"
exit "$rc"
