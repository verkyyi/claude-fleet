#!/usr/bin/env bash
# Stand up a throwaway hub with synthetic data, for capturing the README images.
#
# WHY THIS IS COMMITTED
#
# The README's screenshots have to be re-shootable. A one-off capture rots the
# moment the UI moves and nothing says so — the picture keeps looking plausible
# while it quietly stops being this program. Running this script reproduces the
# exact state the current images were taken from.
#
# WHY THE DATA IS SYNTHETIC
#
# The dashboard carries account emails, project paths (which are client names),
# machine names, OS logins, session ids and branches — see "Showing it to
# someone else" in the README. None of that may reach a public image. Every
# identifier below is invented; the demo repo names match claude-fleet's
# (acme-app) so the two projects' screenshots read as one story.
#
# The numbers are shaped to be plausible, not to be anyone's real usage. They
# go in through the real /v1/ingest endpoint and are priced by the hub's own
# pricing table, so what you photograph is the real UI on the real code path.
#
# Usage:
#   docs/img/seed-demo.sh            # build, seed, serve; prints the URL + token
#   PORT=9123 docs/img/seed-demo.sh  # pick the port
#
# Ctrl-C stops the hub and removes the temporary database.

set -euo pipefail

PORT="${PORT:-8799}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccquota-demo.XXXXXX")"
DB="$WORK/demo.db"
BIN="$WORK/ccquota"

cleanup() {
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

die() { # print the hub's own log before the trap deletes it
  echo "✗ $*" >&2
  [ -f "$WORK/hub.log" ] && { echo "--- hub.log ---" >&2; cat "$WORK/hub.log" >&2; }
  exit 1
}

echo "→ building"
( cd "$ROOT" && go build -o "$BIN" ./cmd/ccquota )

export CCQUOTA_DB="$DB"
export CCQUOTA_VIEWER_TOKEN="demo-viewer-token"

# Refuse to start on an occupied port. Skipping this check once cost an hour:
# a leftover hub from an earlier run answered /healthz, the readiness probe
# below took that as "we are up", and every later step then acted on a database
# the running hub had never heard of.
if curl -sf -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
  die "something already answers on 127.0.0.1:$PORT — stop it, or re-run with PORT=<other>"
fi

echo "→ starting hub on 127.0.0.1:$PORT"
# --pricing carries the gateway rates; without it the metered events ingest
# fine but price as nil and the consumption table shows one subscription row.
# --public-badges lets `ccquota badge` be fetched without a viewer token, which
# is what a README image needs.
"$BIN" hub --addr "127.0.0.1:$PORT" --db "$DB" \
  --pricing "$ROOT/docs/img/demo-pricing.json" --public-badges \
  >"$WORK/hub.log" 2>&1 &
HUB_PID=$!

# Ready means MY hub is serving and has created ITS database — not merely that
# the port answers.
ready=
for _ in $(seq 1 100); do
  kill -0 "$HUB_PID" 2>/dev/null || die "the hub exited during startup"
  if [ -f "$DB" ] && curl -sf -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.2
done
[ -n "$ready" ] || die "the hub did not become ready within 20s"

# Enroll the endpoints. The token is printed once, so capture it here.
# Plain variables, not an associative array: macOS still ships bash 3.2.
enroll_token() {
  "$BIN" enroll --name "$1" --db "$DB" | grep -oE 'ccq_[A-Za-z0-9_-]+' | head -1
}
MAC_TOKEN="$(enroll_token mac-mini)"
WEB_TOKEN="$(enroll_token web-01)"
LAP_TOKEN="$(enroll_token laptop-ada)"
for t in "$MAC_TOKEN" "$WEB_TOKEN" "$LAP_TOKEN"; do
  [ -n "$t" ] || die "enroll produced no token"
done
echo "→ enrolled mac-mini, web-01, laptop-ada"

echo "→ generating and pushing usage"
MAC_TOKEN="$MAC_TOKEN" WEB_TOKEN="$WEB_TOKEN" LAP_TOKEN="$LAP_TOKEN" \
HUB="http://127.0.0.1:$PORT" python3 "$ROOT/docs/img/seed-demo.py"

# Teams are assigned on the hub — an endpoint cannot name its own.
ENDPOINTS="$("$BIN" team --list --db "$DB" 2>/dev/null || true)"
assign() { # $1=machine name  $2=team
  local id
  # Endpoint ids look like ep_1789422774741475000 — the underscore has to be in
  # the class, or this silently matches the literal "ep" and every assignment
  # fails with "no endpoint \"ep\"".
  id="$(printf '%s\n' "$ENDPOINTS" | grep -i "$1" | grep -oE '^ep_[0-9]+' | head -1)"
  [ -n "$id" ] || die "no endpoint row for $1 in: $ENDPOINTS"
  "$BIN" team --endpoint "$id" --set "$2" --db "$DB" >/dev/null
}
assign mac-mini platform
assign web-01   platform
assign laptop   growth

# What a plan costs is the one figure the hub cannot observe.
#
# Effective-date it to the start of the window. Prices are appended, never
# backfilled, so a plan priced "now" covers only the seconds since — which
# rendered as "$1.16 of subscriptions" against a month of usage and read as a
# bug rather than as the honest proration it is.
# RFC3339, not a bare date: --from parses with time.RFC3339 and rejects
# "2026-08-14" outright.
PLAN_FROM="$(python3 -c "
import datetime
d = datetime.date.today() - datetime.timedelta(days=31)
print(d.isoformat() + 'T00:00:00Z')
")"
"$BIN" plan --set max --monthly 200 --from "$PLAN_FROM" --db "$DB" >/dev/null \
  || die "could not price the max plan"

cat <<EOF

  Dashboard   http://127.0.0.1:$PORT/?token=$CCQUOTA_VIEWER_TOKEN
  Database    $DB  (deleted on exit)

Ctrl-C to stop.
EOF

wait "$HUB_PID"
