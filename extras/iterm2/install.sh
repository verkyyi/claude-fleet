#!/bin/bash
# install.sh — put the LAPTOP half of `fleet-open` in place (issue #1380).
#
# Run it on the computer you ssh FROM (the one running iTerm2), either locally
# from a checkout:
#
#   bash extras/iterm2/install.sh --mini macmini
#
# or from the mini, over the ssh you already have to the laptop:
#
#   ssh macbook 'bash -s -- --mini macmini' < ~/.claude/fleet/extras/iterm2/install.sh
#
# --mini is the ssh alias THIS computer uses to reach the mini. The secret
# (~/.config/claude-fleet/open.secret there) — and, when run through `bash -s`
# with no fleet_open.py beside it, the script itself — are read back over that
# alias. If the laptop can't ssh back unattended, copy both over first and pass
# --src <fleet_open.py> --secret-file <file>.
#
# What it does (each step is printed; --dry-run prints and changes nothing; a
# second run on an installed laptop changes nothing):
#   1. checks iTerm2 >= 3.5 and that its Python API is ON — never flips it: that
#      is the operator's switch (Settings ▸ General ▸ Magic ▸ Enable Python API);
#   2. installs fleet_open.py into iTerm2's Scripts/AutoLaunch;
#   3. writes ~/.config/fleet-open/{secret (0600), host}, and a default allow-list
#      if there is none (an existing one is never touched);
#   4. makes sure ssh to the mini multiplexes (ControlMaster auto, ControlPath
#      ~/.ssh/cm-%C, ControlPersist 10m) — only the keys `ssh -G` says are
#      missing, added to that Host block, after a ~/.ssh/config.bak-<date> copy.
#
# --uninstall removes the AutoLaunch script and the secret/host/port-map files
# (the log, the allow-list and ~/.ssh/config stay).
set -euo pipefail

ITERM_APP="${FLEET_OPEN_ITERM_APP:-/Applications/iTerm.app}"
ITERM_SUPPORT="$HOME/Library/Application Support/iTerm2"
AUTOLAUNCH="$ITERM_SUPPORT/Scripts/AutoLaunch"
CONF="$HOME/.config/fleet-open"
SSH_CONFIG="$HOME/.ssh/config"
# shellcheck disable=SC2088  # deliberate: the remote shell expands it
MINI_ROOT='~/.claude/fleet'   # the mini's live install, expanded on the mini
MIN_ITERM=3.5

MINI='' SRC='' SECRET_FILE='' DRY=0 UNINSTALL=0
usage() { sed -n '2,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --mini) MINI="${2:-}"; shift 2 ;;
    --mini=*) MINI="${1#*=}"; shift ;;
    --src) SRC="${2:-}"; shift 2 ;;
    --secret-file) SECRET_FILE="${2:-}"; shift 2 ;;
    --dry-run|-n) DRY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

CHANGES=0 WARNS=0
ok()   { printf '  ok     %s\n' "$*"; }
warn() { printf '  WARN   %s\n' "$*"; WARNS=$((WARNS + 1)); }
die()  { printf '  FAIL   %s\n' "$*"; exit 1; }
note() { printf '         %s\n' "$*"; }
# change <description> — counts it; under --dry-run says "would" and returns 1
change() {
  CHANGES=$((CHANGES + 1))
  if [ "$DRY" = 1 ]; then printf '  would  %s\n' "$*"; return 1; fi
  printf '  do     %s\n' "$*"
}

# ver_ge A B — numeric dotted compare; a suffix like "beta1" is ignored
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) {
      p = x[i] + 0; q = y[i] + 0
      if (p > q) exit 0
      if (p < q) exit 1
    }
    exit 0 }'
}

# put_file <dest> <mode> <content-file> <label> — write only when it differs
put_file() {
  if [ -f "$1" ] && cmp -s "$1" "$3"; then
    ok "$4 unchanged ($1)"
    if [ -z "$(find "$1" -prune -perm "$2")" ] && change "chmod $2 $1"; then   # exact mode, BSD + GNU
      chmod "$2" "$1"
    fi
    return 0
  fi
  if [ -f "$1" ]; then change "update $4 ($1)" || return 0
  else change "install $4 ($1)" || return 0; fi
  mkdir -p "$(dirname "$1")"
  local tmp="$1.tmp.$$"
  cp "$3" "$tmp" && chmod "$2" "$tmp" && mv -f "$tmp" "$1"
  return 0
}

remove() {   # remove <path> <label>
  if [ -e "$1" ]; then change "remove $2 ($1)" && rm -f "$1"; else ok "$2 already absent"; fi
  return 0
}

# -n on EVERY ssh here (issue #1405): under `ssh laptop 'bash -s' < install.sh`
# stdin IS the rest of this script, and an ssh without -n forwards it to the
# remote side — bash then reads EOF and exits 0 mid-install, silently.
mini_cat() {   # mini_cat <remote path, ~ expanded there> → stdout
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$MINI" "cat $1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-open-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf 'fleet-open laptop install%s\n' "$([ "$DRY" = 1 ] && printf ' (dry run)')"

if [ "$UNINSTALL" = 1 ]; then
  remove "$AUTOLAUNCH/fleet_open.py" "AutoLaunch script"
  remove "$CONF/secret" "secret"
  remove "$CONF/host" "host alias"
  remove "$CONF/ports.json" "port map"
  note "kept: $CONF/log, $CONF/allow, $SSH_CONFIG (ControlMaster stays harmless)"
  note "a running copy stops when iTerm2 restarts (or Scripts ▸ Manage ▸ Terminate)"
  printf 'changes: %d\n' "$CHANGES"
  exit 0
fi

# --- which mini -------------------------------------------------------------
if [ -z "$MINI" ] && [ -f "$CONF/host" ]; then
  MINI="$(sed -n '/^[[:space:]]*[^#[:space:]]/{s/[[:space:]]//g;p;q;}' "$CONF/host")"
fi
[ -n "$MINI" ] || die "which mini? pass --mini <the ssh alias this computer uses for it>"
case "$MINI" in
  [A-Za-z0-9]*) ;;
  *) die "--mini '$MINI' is not an ssh alias" ;;
esac
case "$MINI" in *[!A-Za-z0-9._@-]*) die "--mini '$MINI' is not an ssh alias" ;; esac
ok "mini ssh alias: $MINI"

# --- 1. iTerm2 + its Python API ---------------------------------------------
[ -d "$ITERM_APP" ] || die "iTerm2 not found at $ITERM_APP — install iTerm2 >= $MIN_ITERM first"
iver="$(defaults read "$ITERM_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
[ -n "$iver" ] || die "can't read iTerm2's version from $ITERM_APP"
ver_ge "$iver" "$MIN_ITERM" || die "iTerm2 $iver is too old — fleet-open needs >= $MIN_ITERM (iTerm2 ▸ Check for Updates)"
ok "iTerm2 $iver"
api="$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || true)"
if [ "$api" = 1 ]; then
  ok "iTerm2 Python API enabled"
else
  warn "iTerm2 Python API is OFF — turn it on yourself: iTerm2 ▸ Settings ▸ General ▸ Magic ▸ Enable Python API"
  note "(not changed for you: it lets local scripts drive iTerm2, so it is your call)"
fi
if ls -d "$ITERM_SUPPORT"/iterm2env* >/dev/null 2>&1; then
  ok "iTerm2 Python runtime present"
else
  warn "iTerm2's Python runtime is not installed yet"
  note "the first time the script starts, iTerm2 asks to download it — click Install once"
fi

# --- 2. the script ----------------------------------------------------------
if [ -z "$SRC" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  [ -n "$here" ] && [ -f "$here/fleet_open.py" ] && SRC="$here/fleet_open.py"
fi
if [ -n "$SRC" ]; then
  [ -f "$SRC" ] || die "--src $SRC: no such file"
  cp "$SRC" "$WORK/fleet_open.py"
  ok "script source: $SRC"
else
  mini_cat "$MINI_ROOT/extras/iterm2/fleet_open.py" > "$WORK/fleet_open.py" 2>"$WORK/err" \
    || die "can't read the script from $MINI ($(head -c 200 "$WORK/err")) — pass --src <fleet_open.py>"
  ok "script source: $MINI:$MINI_ROOT/extras/iterm2/fleet_open.py"
fi
ver="$(sed -n 's/^FLEET_OPEN_VERSION = "\([0-9]*\)".*/\1/p' "$WORK/fleet_open.py")"
[ -n "$ver" ] || die "that fleet_open.py has no FLEET_OPEN_VERSION line — not the right file"
put_file "$AUTOLAUNCH/fleet_open.py" 644 "$WORK/fleet_open.py" "fleet_open.py v$ver"

# --- 3. secret, host, allow-list --------------------------------------------
if [ -n "$SECRET_FILE" ]; then
  tr -d ' \t\r\n' < "$SECRET_FILE" > "$WORK/secret"
else
  # shellcheck disable=SC2088  # deliberate: the remote shell expands it
  mini_cat '~/.config/claude-fleet/open.secret' 2>"$WORK/err" | tr -d ' \t\r\n' > "$WORK/secret" || true
fi
[ -s "$WORK/secret" ] || die "no secret from $MINI (~/.config/claude-fleet/open.secret) — run fleet-open once on the mini (it creates one), or pass --secret-file"
printf '\n' >> "$WORK/secret"
if [ ! -d "$CONF" ] && change "create $CONF (0700)"; then mkdir -p "$CONF" && chmod 700 "$CONF"; fi
put_file "$CONF/secret" 600 "$WORK/secret" "secret"
printf '%s\n' "$MINI" > "$WORK/host"
put_file "$CONF/host" 644 "$WORK/host" "host alias"
if [ -f "$CONF/allow" ]; then
  ok "allow-list kept as is ($CONF/allow)"
else
  printf '# hosts fleet-open opens without asking (one per line; subdomains included)\ngithub.com\nclaude.ai\n' > "$WORK/allow"
  put_file "$CONF/allow" 644 "$WORK/allow" "default allow-list"
fi

# --- 4. ssh multiplexing to the mini ----------------------------------------
eff() { ssh -n -G "$MINI" 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }
missing=''
case "$(eff controlmaster)" in ''|false|no) missing="$missing ControlMaster" ;; esac
case "$(eff controlpath)" in ''|none) missing="$missing ControlPath" ;; esac
case "$(eff controlpersist)" in ''|no|false|0) missing="$missing ControlPersist" ;; esac
if [ -z "$missing" ]; then
  ok "ssh to $MINI already multiplexes (ControlMaster/ControlPath/ControlPersist set)"
else
  lines=''
  for k in $missing; do
    case "$k" in
      ControlMaster) lines="$lines  ControlMaster auto\n" ;;
      ControlPath) lines="$lines  ControlPath ~/.ssh/cm-%C\n" ;;
      ControlPersist) lines="$lines  ControlPersist 10m\n" ;;
    esac
  done
  if change "add$missing to Host $MINI in $SSH_CONFIG"; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    [ -f "$SSH_CONFIG" ] || { : > "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"; }
    bak="$SSH_CONFIG.bak-$(date +%Y%m%d)"
    if [ -e "$bak" ]; then note "backup $bak already exists (kept — it is the older copy)"
    else cp -p "$SSH_CONFIG" "$bak"; note "backup: $bak"; fi
    awk -v alias="$MINI" -v add="$lines" '
      BEGIN { gsub(/\\n/, "\n", add) }
      !done && tolower($1) == "host" {
        for (i = 2; i <= NF; i++) if ($i == alias) { print; printf "%s", add; done = 1; next }
      }
      { print }
      END { if (!done) { if (NR) print ""; print "Host " alias; printf "%s", add } }
    ' "$SSH_CONFIG" > "$WORK/ssh_config"
    cat "$WORK/ssh_config" > "$SSH_CONFIG"   # in place: keeps a symlinked/managed config a symlink
    still=''
    case "$(eff controlmaster)" in ''|false|no) still="$still ControlMaster" ;; esac
    case "$(eff controlpath)" in ''|none) still="$still ControlPath" ;; esac
    case "$(eff controlpersist)" in ''|no|false|0) still="$still ControlPersist" ;; esac
    [ -z "$still" ] || warn "ssh -G $MINI still lacks$still — an earlier Host/Match block wins; set them there by hand"
  fi
fi

printf 'changes: %d%s\n' "$CHANGES" "$([ "$WARNS" -gt 0 ] && printf ', %d warning(s)' "$WARNS")"
if [ "$DRY" = 0 ] && [ "$CHANGES" -gt 0 ]; then
  note "start it now: iTerm2 ▸ Scripts ▸ AutoLaunch ▸ fleet_open.py (or restart iTerm2)"
  note "then on the mini: fleet-open https://github.com — this computer's browser should open it"
fi
exit 0
