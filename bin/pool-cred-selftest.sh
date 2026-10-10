#!/bin/bash
# pool-cred-selftest.sh — a warm-pool window is its FLEET's session, also to the hub
# (issue #2914).
#
# scratch-pool.sh parks warm windows in the holding session `<fleet>-pool` until a
# person (or ⌃s) takes one. fleet-session-wrap.sh mints the session's worker
# credential at launch (fleet-mcp.py --cred mint), and before #2914 that read the
# pane's session bare: the claims named `<fleet>-pool`'s fleet UUID, a fleet no
# hub has registered — so on a central-route machine the session pass came back
# 404 and the warm window sat on 「凭据代理没给出会话凭据」 forever.
#
# Legs (a REAL isolated tmux server via the -S PATH-shim — never the live one):
#   MINT      a window parked in pf-pool mints a credential naming pf's fleet UUID —
#             with FLEET_LAUNCH_SESSION (the pool's launch line), and without it
#             (the socket label IS the fleet, #159); a pf window is unchanged
#   CLAIMED   the same window moved into pf (a claim) mints the same UUID
#   ATTACH    conf/tmux-attention.conf's client-attached[77]: a client attaching
#             to pf-pool lands in pf; one attaching to pf stays there
#   PAGE      a launch refused for a 404 says so (cred_unknown), not 「代理没给」
#
# tmux / python3 / script absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 absent — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-cred-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"
mkdir -p "$WORK/bin" "$WORK/sock" "$FLEET_CONF_DIR" "$TMPDIR"

# The socket's basename is the fleet's name, as `tmux -L pf` would make it.
SOCK="$WORK/sock/pf"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$WORK"' EXIT

pass=0
fail() { printf 'FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }

U_PF=11111111-2222-4333-8444-555555555555
U_POOL=99999999-8888-4777-8666-555555555555     # what the pool's name would resolve to
mkdir -p "$FLEET_CONF_DIR/fleets/pf" "$FLEET_CONF_DIR/fleets/pf-pool"
printf '%s\n' "$U_PF" > "$FLEET_CONF_DIR/fleets/pf/identity"
printf '%s\n' "$U_POOL" > "$FLEET_CONF_DIR/fleets/pf-pool/identity"

tmux -f /dev/null new-session -d -s pf -n home -c "$WORK" || fail "could not start the isolated tmux server"
tmux new-session -d -s pf-pool -n warm-67 -c "$WORK"
tmux set-window-option -t pf-pool:warm-67 @fleet_id aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
tmux set-window-option -t pf:home @fleet_id bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee
SPID=$(tmux display-message -p '#{pid}')

# uuid_of <pane> [VAR=value…] → the fleet_uuid the minted credential's claims carry
uuid_of() {
  local pane="$1"; shift
  env -u FLEET_WORKER_CRED -u FLEET_LAUNCH_SESSION "$@" TMUX="$SOCK,$SPID,0" TMUX_PANE="$pane" \
    FLEET_CRED_FID_WAIT=0 python3 "$BIN/fleet-mcp.py" --cred mint 2>"$WORK/mint.err" \
  | python3 -c 'import base64, json, sys
p = sys.stdin.read().strip().split(".")[1]
print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["fleet_uuid"])'
}

WP=$(tmux display-message -p -t pf-pool:warm-67 '#{pane_id}')
HP=$(tmux display-message -p -t pf:home '#{pane_id}')

# --- MINT --------------------------------------------------------------------
got=$(uuid_of "$WP" FLEET_LAUNCH_SESSION=pf)
[ "$got" = "$U_PF" ] || fail "MINT: a warm window launched for pf names $got, not pf's $U_PF" "$(cat "$WORK/mint.err")"
got=$(uuid_of "$WP")
[ "$got" = "$U_PF" ] || fail "MINT: with no FLEET_LAUNCH_SESSION the socket label should name pf ($got)" "$(cat "$WORK/mint.err")"
got=$(uuid_of "$HP" FLEET_LAUNCH_SESSION=pf)
[ "$got" = "$U_PF" ] || fail "MINT: a pf window's credential changed ($got)"
ok "MINT a window parked in pf-pool asserts pf's fleet UUID (launch env, and the socket label alone)"

# --- CLAIMED -----------------------------------------------------------------
tmux move-window -s pf-pool:warm-67 -t pf: || fail "CLAIMED: could not move the warm window"
got=$(uuid_of "$WP" FLEET_LAUNCH_SESSION=pf)
[ "$got" = "$U_PF" ] || fail "CLAIMED: the claimed window names $got"
ok "CLAIMED the same window, moved into pf, mints the same UUID (↵ retry after a claim)"
tmux new-session -d -s pf-pool -n warm-68 -c "$WORK"   # the claim emptied the pool: the next warm entry

# --- ATTACH ------------------------------------------------------------------
if command -v script >/dev/null 2>&1; then
  hook=$(grep '^set-hook -g client-attached\[77\]' "$BIN/../conf/tmux-attention.conf")
  [ -n "$hook" ] || fail "ATTACH: conf/tmux-attention.conf carries no client-attached[77]"
  printf '%s\n' "$hook" > "$WORK/hook.conf"
  tmux source-file "$WORK/hook.conf" || fail "ATTACH: the hook line does not parse"
  attach_to() { # attach_to <session> → the session the client sits in a moment later
    if script --version >/dev/null 2>&1; then   # util-linux: the command is -c's string
      (sleep 4 | script -qfc "'$WORK/bin/tmux' attach -t '$1'" /dev/null >/dev/null 2>&1 &)
    else                                         # BSD: the command follows the file
      (sleep 4 | script -q /dev/null "$WORK/bin/tmux" attach -t "$1" >/dev/null 2>&1 &)
    fi
    local i s=''
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.3
      s=$(tmux list-clients -F '#{client_session}' 2>/dev/null | head -1)
      [ "$s" = pf ] && break
    done
    printf '%s' "$s"
    for c in $(tmux list-clients -F '#{client_name}' 2>/dev/null); do tmux detach-client -t "$c" >/dev/null 2>&1; done
    sleep 0.5
  }
  got=$(attach_to pf-pool)
  [ "$got" = pf ] || fail "ATTACH: a client attaching to pf-pool stayed in '$got'"
  got=$(attach_to pf)
  [ "$got" = pf ] || fail "ATTACH: a client attaching to pf ended in '$got'"
  ok "ATTACH a client landing in pf-pool is moved to pf; one landing in pf stays"
else
  printf 'skip ATTACH (no script(1))\n'
fi

# --- PAGE --------------------------------------------------------------------
line=$(cd "$BIN" && python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("p", "fleet-session-page.py"); p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
print(p.headline(1, p.TEXT["zh"], failed="launch", why="cred_unknown")[0])')
case "$line" in
  *'入口不认这个会话'*'补登记并重试'*) : ;;
  *) fail "PAGE: a 404 refusal reads '$line'" ;;
esac
grep -q '5) echo .fleet-claude: the hub does not know this session' "$BIN/fleet-claude.sh" \
  || fail "PAGE: fleet-claude.sh does not tell a 404 (exit 5) apart"
grep -q 'sys.exit(5)' "$BIN/fleet-session-cred.sh" || fail "PAGE: fleet-session-cred.sh does not exit 5 on a 404"
ok "PAGE a launch refused for a hub 404 says 「入口不认这个会话 · ↵ 补登记并重试」"

printf 'pool-cred-selftest: %d legs passed\n' "$pass"
