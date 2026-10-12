#!/bin/bash
# fleet-conf-example.sh — print the short sample fleet.conf.example (issue #3576).
#
# conf/fleet.conf.reference is the ONE list of settings: every key, its default,
# its help and the tag line the prefix+c modal reads. The repo root keeps only a
# short sample for a first-time reader — the keys tagged @tier=common, each with
# its label and its line as the reference spells it — generated from the
# reference so the two never disagree:
#
#   bin/fleet-conf-example.sh > fleet.conf.example        # regenerate
#   bin/fleet-conf-example.sh --check                     # exit 1 when stale
#
# conf-surface-selftest.sh runs --check on every PR.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="${FLEET_CONF_REFERENCE:-$ROOT/conf/fleet.conf.reference}"
[ -f "$REF" ] || { echo "fleet-conf-example: no $REF" >&2; exit 2; }

gen() {
  cat <<'HEAD'
# claude-fleet — a short sample of the settings most people touch.
# GENERATED from conf/fleet.conf.reference by bin/fleet-conf-example.sh; do not
# edit by hand. Every key, its default and its help: conf/fleet.conf.reference.
#
# Your settings live in $FLEET_CONF_DIR/fleet.conf (default
# ~/.config/claude-fleet/fleet.conf; plain shell, assignments only). The config
# panel (prefix+c) edits them; `fleet doctor` reads them back. A line left
# commented keeps the default shown.
HEAD
  awk '
    /^# *@label=/ && /@tier=common/ {
      lbl = $0; sub(/^# *@label=/, "", lbl); sub(/ @[a-z]+=.*/, "", lbl)
      grp = $0; if (match(grp, /@group=[^ ]+/)) grp = substr(grp, RSTART + 7, RLENGTH - 7); else grp = "other"
      pend = 1; next
    }
    pend && /^#?[A-Z_][A-Z0-9_]*=/ {
      if (!(grp in body)) order[++n] = grp
      body[grp] = body[grp] sprintf("# %s\n%s\n", lbl, $0)
      pend = 0; next
    }
    { pend = 0 }
    END { for (i = 1; i <= n; i++) printf "\n# ── %s ──\n%s", order[i], body[order[i]] }
  ' "$REF"
}

case "${1:-}" in
  --check)
    if gen | cmp -s - "$ROOT/fleet.conf.example"; then exit 0; fi
    echo "fleet-conf-example: fleet.conf.example is stale — run bin/fleet-conf-example.sh > fleet.conf.example" >&2
    exit 1 ;;
  "") gen ;;
  *) echo "usage: fleet-conf-example.sh [--check]" >&2; exit 2 ;;
esac
