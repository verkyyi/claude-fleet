#!/bin/bash
# fleet-creds-import.sh — put this machine's Claude setup-tokens into the hub's
# credential vault as SHARED-POOL accounts (issue #1463).
#
# The pool files in <accounts>/<label> are the long-lived tokens `claude
# setup-token` mints (sk-ant-oat01-…, ~1 year, no refresh token). The hub's
# vault (#1415) used to take only refresh tokens; now it takes a setup token as
# kind "setup_token", hands it down as is, and reminds the operator 30 days
# before it ends. This command reads each pool file and POSTs it to the hub
# over the viewer token — the token travels in a 0600 file to curl, never on a
# command line, and is never printed: not on success, not on failure.
#
#   fleet-creds-import.sh [--principal <id>] [--expires-at <RFC3339>] [--dry-run] [label …]
#
#   label …        which pool files; default = every plain setup-token file in
#                  the accounts dir. A file already holding `hub:<label>` is
#                  skipped (the hub owns it), as is anything that is not an
#                  sk-ant-oat01- token.
#   --principal    "pool" (default) = a shared-pool account every active
#                  principal may lease; or one person's id (wecom-…).
#   --expires-at   when the token ends, RFC3339 UTC. Default: the pool file's
#                  mtime + 365 days (`claude setup-token` mints for a year and
#                  the file is written right after) — printed per label so you
#                  can see what was assumed. The hub refuses one already past.
#   --dry-run      print the plan, send nothing.
#
# Env: CCQUOTA_HUB_URL (required), CCQUOTA_VIEWER_TOKEN or ~/.ccquota/viewer-token
# (the OPERATOR's — the route is operator-only), FLEET_ACCOUNTS_DIR (default
# ~/.config/claude-fleet/accounts).
#
# Exit 0 = every selected token imported (skips are not failures, and are
# listed); 1 = at least one import failed (the hub's answer is shown); 2 = usage.
#
# Afterwards nothing on THIS machine changes: the files stay as they are until
# this login's ccquota agent runs with CCQUOTA_FLEET_CREDS=1, leases them back
# and replaces each pool file with the hub marker (m4 first; m5 in its own
# window, issue #1463 step 5).
set -uo pipefail

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

PRINCIPAL=pool EXPIRES='' DRY=0
LABELS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --principal)  [ -n "${2:-}" ] || usage; PRINCIPAL="$2"; shift 2 ;;
    --expires-at) [ -n "${2:-}" ] || usage; EXPIRES="$2"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    usage ;;
    --*)          printf 'fleet-creds-import: unknown option %s\n' "$1" >&2; usage ;;
    *)            LABELS+=("$1"); shift ;;
  esac
done

ACCT_DIR="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}"
[ -d "$ACCT_DIR" ] || { printf 'fleet-creds-import: no accounts dir %s\n' "$ACCT_DIR" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-creds-import: python3 is required\n' >&2; exit 2; }
command -v curl    >/dev/null 2>&1 || { printf 'fleet-creds-import: curl is required\n' >&2; exit 2; }

HUB="${CCQUOTA_HUB_URL:-}"
[ -n "$HUB" ] || { printf 'fleet-creds-import: CCQUOTA_HUB_URL is not set\n' >&2; exit 2; }
HUB="${HUB%/}"
# The viewer token where ccquota itself finds it: the env, else ~/.ccquota/viewer-token.
VIEWER="${CCQUOTA_VIEWER_TOKEN:-}"
[ -n "$VIEWER" ] || { [ -r "$HOME/.ccquota/viewer-token" ] && read -r VIEWER < "$HOME/.ccquota/viewer-token"; } || VIEWER=''
if [ -z "$VIEWER" ] && [ "$DRY" = 0 ]; then
  printf 'fleet-creds-import: no viewer token (CCQUOTA_VIEWER_TOKEN or ~/.ccquota/viewer-token) — the route is operator-only\n' >&2
  exit 2
fi

# Default labels: every regular file that is not a .conf / dotfile / backup.
if [ "${#LABELS[@]}" -eq 0 ]; then
  for f in "$ACCT_DIR"/*; do
    [ -f "$f" ] || continue
    l=${f##*/}
    case "$l" in .*|*~|*.conf) continue ;; esac
    LABELS+=("$l")
  done
fi
[ "${#LABELS[@]}" -gt 0 ] || { printf 'fleet-creds-import: no pool files in %s\n' "$ACCT_DIR" >&2; exit 2; }

# Private workspace for the request bodies and the auth header: 0700 dir,
# 0600 files, gone on exit however we leave.
umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-creds-import.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
printf 'Authorization: Bearer %s\n' "$VIEWER" > "$WORK/hdr"

# plan <file> <label> <principal> <expires-or-empty> → stdout: one line
#   "<expires>\t<reason>"  reason "" = ok, else why this label is skipped.
# Also writes the request body to $WORK/body when ok. The token is read here,
# inside python, and goes nowhere but that 0600 file.
plan() {
  python3 - "$1" "$2" "$3" "$4" "$WORK/body" <<'PY'
import json, os, sys, datetime
path, label, principal, expires, out = sys.argv[1:6]
try:
    with open(path, 'rb') as f:
        tok = f.readline().strip().decode('ascii', 'replace')
except OSError as e:
    print('\t' + 'unreadable: ' + e.strerror); sys.exit(0)
if tok.startswith('hub:'):
    print('\talready hub-managed (pool file holds the hub marker)'); sys.exit(0)
if not tok.startswith('sk-ant-oat01-') or len(tok) < 20 or any(c.isspace() for c in tok):
    print('\tnot a `claude setup-token` (sk-ant-oat01-…) file'); sys.exit(0)
if expires:
    exp = expires
    try:
        datetime.datetime.strptime(exp.replace('Z', '+00:00'), '%Y-%m-%dT%H:%M:%S%z')
    except ValueError:
        print('\t--expires-at must be RFC3339, e.g. 2027-10-03T00:00:00Z'); sys.exit(0)
else:
    mt = datetime.datetime.fromtimestamp(os.stat(path).st_mtime, datetime.timezone.utc)
    exp = (mt + datetime.timedelta(days=365)).strftime('%Y-%m-%dT%H:%M:%SZ')
body = {"action": "put", "principal_id": principal, "provider": "claude", "account": label,
        "secret": {"setup_token": tok, "expires_at": exp}}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump(body, f)
print(exp + '\t')
PY
}

ok=0 failed=0 skipped=0
for l in ${LABELS[@]+"${LABELS[@]}"}; do
  f="$ACCT_DIR/$l"
  case "$l" in
    ''|.*|*/*|*~|*.conf) printf 'skip   %-14s not a pool label\n' "$l"; skipped=$((skipped+1)); continue ;;
  esac
  [ -f "$f" ] || { printf 'skip   %-14s no such pool file\n' "$l"; skipped=$((skipped+1)); continue; }
  rm -f "$WORK/body"
  line=$(plan "$f" "$l" "$PRINCIPAL" "$EXPIRES") || { printf 'FAIL   %-14s could not read it\n' "$l"; failed=$((failed+1)); continue; }
  exp=${line%%	*}; why=${line#*	}
  if [ -n "$why" ]; then printf 'skip   %-14s %s\n' "$l" "$why"; skipped=$((skipped+1)); continue; fi
  if [ "$DRY" = 1 ]; then
    printf 'would  %-14s → %s · %s · setup_token · expires %s%s\n' "$l" "$HUB" "$PRINCIPAL" "$exp" "${EXPIRES:+ (given)}"
    ok=$((ok+1)); continue
  fi
  code=$(curl -sS -m 30 -o "$WORK/resp" -w '%{http_code}' -H @"$WORK/hdr" -H 'Content-Type: application/json' \
           --data-binary @"$WORK/body" "$HUB/v1/fleet/credentials" 2>"$WORK/err") || code=000
  rm -f "$WORK/body"
  if [ "$code" = 200 ]; then
    printf 'put    %-14s → %s · setup_token · expires %s%s\n' "$l" "$PRINCIPAL" "$exp" "${EXPIRES:+ (given)}"
    ok=$((ok+1))
  else
    # The hub's answer names the reason and never echoes a secret.
    printf 'FAIL   %-14s HTTP %s %s\n' "$l" "$code" "$(tr -d '\n' < "$WORK/resp" 2>/dev/null; tr -d '\n' < "$WORK/err" 2>/dev/null)" >&2
    failed=$((failed+1))
  fi
done

if [ "$DRY" = 1 ]; then
  printf 'dry-run: %d would be imported, %d skipped — nothing sent\n' "$ok" "$skipped"
else
  printf '%d imported, %d skipped, %d failed → %s/credentials\n' "$ok" "$skipped" "$failed" "$HUB"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
