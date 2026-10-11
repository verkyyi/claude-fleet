#!/bin/bash
# fleet-release-lib.sh — a login install takes its new versions from the hub's
# signed release, never GitHub (issue #2773, EPIC #2770 C3). Sourced by
# fleet-install-sync.sh (every tick with a hub) and fleet-host-install.sh (the
# first checkout); fleet-release-key.sh (`fleet host trust-release-key`) re-pins.
#
# TRUST. The hub's release key is pinned ONCE per login — $FLEET_CONF_DIR/
# release.pub (0644), taken from GET /v1/fleet/release/key the first time this
# login meets a hub that keeps releases — and from then on only that key counts:
# every release is checked against it by fleet-release-fetch.py (the manifest's
# SSHSIG via `ssh-keygen -Y verify`, every file's sha256 — no ccquota, #3162)
# before anything is unpacked or switched. A new key is taken by itself only
# when the pinned one vouches for it (the hub's key-endorsement); otherwise it
# is a person's to accept: fleet-release-key.sh --trust prints both
# fingerprints and asks.
#
# STORAGE. The verified tree is imported into the install's own repository as
# ONE local commit — a temporary index, `add -A -f`, write-tree, commit-tree on
# the commit the install is at — subject `fleet-release: <upstream sha> seq=<n>`,
# kept alive by refs/fleet/rel/<upstream sha>. So fleet-install-apply.sh's
# `git diff from to` / `git show from:…` read two commits exactly as before, the
# version dir keeps the upstream sha as its name, and the repository needs no
# remote. «Only forward» is the signed seq, never git ancestry.
#
# A hub with no release store (no CCQUOTA_FLEET_RELEASE_KEY — every release
# route 404s) is told apart from a hub that does not answer: the first means
# «follow stable over git, as before» (EPIC #2770 共同约定 7), the second
# «入口不可达 — stay on this version».
#
# Sourced, never run. No `local` takes a zsh special parameter's name (#1633).

# fleet_rel_hub_url — the hub this login talks to ('' = none)
fleet_rel_hub_url() {
  local u="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}"
  case "$u" in http://*|https://*) printf '%s' "${u%/}" ;; esac
}

# fleet_rel_http <url> <out> <timeout> — the HTTP code curl got (000 = no
# answer); the body in <out>, curl's last error line in REL_ERR
fleet_rel_http() {
  local code
  REL_ERR=''
  code=$(curl -sS --max-time "$3" -o "$2" -w '%{http_code}' "$1" 2>"$2.err") || :
  REL_ERR=$(tail -n 1 "$2.err" 2>/dev/null)
  rm -f "$2.err"
  case "$code" in ''|*[!0-9]*) code=000 ;; esac
  printf '%s' "$code"
}

# fleet_rel_stable <hub> <timeout> — what the hub calls stable: REL_SHA REL_SEQ
# (a HINT: unsigned here; the fetch below verifies the real one).
# rc 0 · 3 the hub keeps no releases (404) · 1 no answer (REL_ERR says why)
fleet_rel_stable() {
  local f code out
  REL_SHA='' REL_SEQ=''
  f=$(mktemp "${TMPDIR:-/tmp}/fleet-rel-stable.XXXXXX") || return 1
  code=$(fleet_rel_http "$1/v1/fleet/release/stable" "$f" "$2")
  case "$code" in
    200) ;;
    404) rm -f "$f"; return 3 ;;
    000) rm -f "$f"; REL_ERR="no answer${REL_ERR:+ ($REL_ERR)}"; return 1 ;;
    *)   rm -f "$f"; REL_ERR="HTTP $code from /v1/fleet/release/stable"; return 1 ;;
  esac
  out=$(python3 -c 'import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
    s, q = str(d.get("sha") or ""), int(d.get("seq") or 0)
except Exception:
    sys.exit(1)
if not re.match(r"^[0-9a-f]{40}$", s):
    sys.exit(1)
print(s, q)' "$f" 2>/dev/null)
  rm -f "$f"
  [ -n "$out" ] || { REL_ERR='the hub answered /v1/fleet/release/stable with no release'; return 1; }
  # shellcheck disable=SC2034  # read by the caller (fleet-install-sync.sh, fleet-host-install.sh)
  REL_SHA=${out%% *} REL_SEQ=${out#* }
  return 0
}

# fleet_rel_fp <key file> — a short fingerprint a person can compare: ccquota's
# release.KeyID (sha256 of the RAW key, 16 hex) — the one a manifest's `key`,
# the hub and fleet-node-update.py print. Before #3047 this hashed the base64
# TEXT, so one key read as two (9b1e0fd0… here, f82fba7b… everywhere else) and
# looked like a rotation. A line that is no 32-byte key keeps the text hash.
fleet_rel_fp() {
  local k f
  k=$(awk 'NF >= 2 { print $2; exit }' "$1" 2>/dev/null)
  [ -n "$k" ] || { printf '?'; return 0; }
  f=$(python3 -c 'import base64, hashlib, sys
try:
    r = base64.b64decode(sys.argv[1], validate=True)
except Exception:
    sys.exit(1)
if len(r) != 32:
    sys.exit(1)
print(hashlib.sha256(r).hexdigest()[:16])' "$k" 2>/dev/null) && [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  printf '%s' "$k" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-16
}

# fleet_rel_keyline <file> — rc 0 when <file> holds one `ed25519 <base64>` line
fleet_rel_keyline() { grep -Eq '^ed25519 [A-Za-z0-9+/=_-]{8,}$' "$1" 2>/dev/null; }

# fleet_rel_pubkey <conf dir> <hub> <timeout> — the pinned key's path. None
# yet: the hub's, taken once and pinned (said on stderr with its fingerprint).
# rc 1 + REL_ERR when there is none and the hub gives none.
fleet_rel_pubkey() {
  local pk="$1/release.pub" f code
  if [ -s "$pk" ]; then printf '%s\n' "$pk"; return 0; fi
  f=$(mktemp "${TMPDIR:-/tmp}/fleet-rel-key.XXXXXX") || return 1
  code=$(fleet_rel_http "$2/v1/fleet/release/key" "$f" "$3")
  if [ "$code" != 200 ] || ! fleet_rel_keyline "$f"; then
    [ "$code" = 200 ] && REL_ERR='the hub answered /v1/fleet/release/key with no ed25519 key'
    [ "$code" = 000 ] || [ "$code" = 200 ] || REL_ERR="HTTP $code from /v1/fleet/release/key"
    rm -f "$f"; return 1
  fi
  mkdir -p "$1" 2>/dev/null
  head -n 1 "$f" > "$pk.tmp.$$" && chmod 0644 "$pk.tmp.$$" && mv -f "$pk.tmp.$$" "$pk" \
    || { rm -f "$f" "$pk.tmp.$$"; REL_ERR="cannot write $pk"; return 1; }
  rm -f "$f"
  printf 'fleet-release: pinned the hub'"'"'s release key %s (%s) — from now on only it counts; a new one needs `fleet host trust-release-key`\n' "$(fleet_rel_fp "$pk")" "$pk" >&2
  printf '%s\n' "$pk"
}

# fleet_rel_fetch <hub> <pubkey> <sha|stable> <dest> [<timeout>] — the release,
# verified, at <dest> (the tree + .release/manifest.json). No ccquota (issue
# #3162): bin/fleet-release-fetch.py checks it with python3 and the system's
# `ssh-keygen -Y verify` against the pinned key (an older hub's plain ed25519
# signature in python), every file by its sha256. rc 1 + REL_ERR (its last line).
fleet_rel_fetch() {
  local out
  REL_ERR=''
  out=$(python3 "$(dirname "${BASH_SOURCE[0]}")/fleet-release-fetch.py" --hub "$1" --pubkey "$2" \
          --timeout "${5:-60}" "$3" "$4" 2>&1 </dev/null) && [ -f "$4/.release/manifest.json" ] \
    && { printf '%s\n' "$out" | grep '^fleet-release: ' >&2; return 0; }
  REL_ERR=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)
  [ -n "$REL_ERR" ] || REL_ERR='fleet-release-fetch.py left no .release/manifest.json'
  rm -rf "$4"
  return 1
}

# fleet_rel_manifest <dir> — `<sha> <seq> <prev>` of <dir>/.release/manifest.json
fleet_rel_manifest() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
print(str(d.get("sha") or "-"), int(d.get("seq") or 0), str(d.get("prev") or "-"))' "$1/.release/manifest.json" 2>/dev/null
}

# fleet_rel_of <repo> <rev> — `<upstream sha> <seq>` when <rev> is an imported
# release; rc 1 otherwise (a plain commit of the repository)
fleet_rel_of() {
  local s
  s=$(git -C "$1" log -1 --format=%s "$2" 2>/dev/null) || return 1
  case "$s" in "fleet-release: "*) ;; *) return 1 ;; esac
  s=${s#fleet-release: }
  set -- "${s%% *}" "${s#* seq=}"
  case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#1}" = 40 ] || return 1
  case "$2" in *[!0-9]*|'') return 1 ;; esac
  printf '%s %s\n' "$1" "$2"
}

# fleet_rel_below <repo> <rev> — rc 0 when an imported release is somewhere in
# <rev>'s history (so a <rev> that is not one is a hand commit on top of one)
fleet_rel_below() {
  [ -n "$(git -C "$1" log -1 --format=%H --grep='^fleet-release: ' "$2" 2>/dev/null)" ]
}

# fleet_rel_import <repo> <tree dir> <parent commit|''> <upstream sha> <seq> —
# the tree (minus .release/) as one commit on <parent>, refs/fleet/rel/<sha>
# pointing at it; the commit printed. rc 1: nothing made.
fleet_rel_import() {
  local repo="$1" tdir="$2" parent="$3" usha="$4" useq="$5" gd idx tr cm
  gd=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  idx="$gd/fleet-rel-index.$$"
  rm -f "$idx"
  if ! ( cd "$tdir" && GIT_DIR="$gd" GIT_WORK_TREE="$tdir" GIT_INDEX_FILE="$idx" \
         git -c core.autocrlf=false -c core.safecrlf=false add -A -f -- . ':(exclude).release' ) >/dev/null 2>&1 </dev/null; then
    rm -f "$idx"; return 1
  fi
  tr=$(GIT_DIR="$gd" GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null </dev/null)
  rm -f "$idx"
  [ -n "$tr" ] || return 1
  cm=$(GIT_DIR="$gd" GIT_AUTHOR_NAME=fleet-release GIT_AUTHOR_EMAIL=fleet-release@localhost \
       GIT_COMMITTER_NAME=fleet-release GIT_COMMITTER_EMAIL=fleet-release@localhost \
       git commit-tree "$tr" ${parent:+-p "$parent"} -m "fleet-release: $usha seq=$useq" 2>/dev/null </dev/null) || return 1
  [ -n "$cm" ] || return 1
  git -C "$repo" update-ref "refs/fleet/rel/$usha" "$cm" >/dev/null 2>&1 </dev/null || return 1
  printf '%s\n' "$cm"
}

# fleet_rel_drop_origin <repo> <remote> <bak> — the remote goes (its URL kept in
# <bak> for one version: fleet_rel_restore_origin puts it back). Nothing to do
# without one. Says what it did on stderr.
fleet_rel_drop_origin() {
  local u
  u=$(git -C "$1" remote get-url "$2" 2>/dev/null) || return 0
  [ -n "$u" ] || return 0
  mkdir -p "$(dirname "$3")" 2>/dev/null
  printf '%s %s\n' "$2" "$u" > "$3" || return 1
  git -C "$1" remote remove "$2" >/dev/null 2>&1 </dev/null || return 1
  printf 'fleet-release: removed the %s remote (%s) — versions come from the hub now; kept in %s (FLEET_DIST_SOURCE=github puts it back)\n' "$2" "$u" "$3" >&2
}

# fleet_rel_restore_origin <repo> <remote> <bak> — the remote the hub road took
# away, back (FLEET_DIST_SOURCE=github, or a hub that stopped keeping releases)
fleet_rel_restore_origin() {
  local n u
  git -C "$1" remote get-url "$2" >/dev/null 2>&1 && return 0
  [ -s "$3" ] || return 0
  read -r n u < "$3" 2>/dev/null || return 0
  [ "$n" = "$2" ] && [ -n "$u" ] || return 0
  git -C "$1" remote add "$2" "$u" >/dev/null 2>&1 </dev/null \
    && printf 'fleet-release: put the %s remote back (%s) — this tick follows stable over git\n' "$2" "$u" >&2
}

# fleet_rel_first_checkout <dir> <conf dir> <timeout> [<log>] — a NEW install at
# <dir> (it must not exist): the hub's signed stable — the key pinned now, the
# tree verified (fleet_rel_fetch: no ccquota, #3162), imported as one local
# commit; no remote, never GitHub.
# The one first checkout of fleet-host-install.sh and fleet-login-install.sh
# (issue #2775). The hub: fleet_rel_hub_url, else <conf dir>/fleet.conf's.
# rc 0 made — REL_SHA (the upstream sha) · REL_SEQ · REL_FPR (the key's
#      fingerprint) · REL_HUB
# rc 3 no hub, or one that keeps no releases (404) — nothing made
# rc 1 failed — REL_STAGE (unreachable · key · fetch · place) +
#      REL_ERR; <dir> may hold a half-made repository: the caller removes it
# shellcheck disable=SC2034  # every REL_* it sets is the caller's (fleet-host-install.sh, fleet-login-install.sh)
fleet_rel_first_checkout() {
  local dir="$1" conf="$2" tmo="$3" log="${4:-/dev/null}" hub pub stg m c
  REL_STAGE='' REL_FPR='' REL_HUB=''
  hub=$(fleet_rel_hub_url)
  # shellcheck disable=SC2034,SC1091  # FLEET_SHELL=1 picks fleet.conf's [client] section
  [ -n "$hub" ] || hub=$(FLEET_SHELL=1; [ -f "$conf/fleet.conf" ] && . "$conf/fleet.conf" >/dev/null 2>&1; fleet_rel_hub_url)
  [ -n "$hub" ] || return 3
  REL_HUB=$hub
  fleet_rel_stable "$hub" "$tmo"; case $? in 0) ;; 3) return 3 ;; *) REL_STAGE=unreachable; return 1 ;; esac
  pub=$(fleet_rel_pubkey "$conf" "$hub" "$tmo" 2>>"$log") || { REL_STAGE=key; return 1; }
  stg="$dir.rel"; rm -rf "$stg" "$stg.partial"
  fleet_rel_fetch "$hub" "$pub" "$REL_SHA" "$stg" "$tmo" 2>>"$log" || { REL_STAGE=fetch; return 1; }
  m=$(fleet_rel_manifest "$stg")
  REL_SEQ=$(printf '%s' "$m" | awk '{print $2}')
  if ! { git init -q "$dir" >>"$log" 2>&1 && c=$(fleet_rel_import "$dir" "$stg" '' "${m%% *}" "$REL_SEQ") \
         && git -C "$dir" reset -q --hard "$c" >>"$log" 2>&1 </dev/null; }; then
    rm -rf "$stg"; REL_STAGE=place; REL_ERR="cannot place it in $dir"; return 1
  fi
  rm -rf "$stg"
  REL_SHA=${m%% *} REL_FPR=$(fleet_rel_fp "$pub")
}
