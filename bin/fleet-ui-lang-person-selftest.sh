#!/bin/bash
# fleet-ui-lang-person-selftest.sh — the interface language follows the PERSON
# (issue #3329, EPIC #3178 D5–D9): the person's own choice (`ui_lang` in the
# personal layer, person-bundle.json) > what a 看台's client brought
# (FLEET_VIEW_LANG, the door's @view_lang) > Chinese.
#   A. no LANG                         ⇒ 中文, no one-time line
#   B. en_US                           ⇒ English + the one-time line ONCE per device
#   C. the person set zh, en_US comes  ⇒ still 中文, never the one-time line
#   D. 跟系统走 (fleet-config.py lang auto, the hub a seam) ⇒ detection again;
#      lang zh|en writes ui_lang on the hub and re-reads this computer's copy
#   E. the personal layer's validator (fleet-agent-team.py) takes zh | en only
#   F. the top line (fleet-topbar.py render --node): vl= sets the language, fl=/flu=
#      the one-time line for its seconds, then the status line again
#   Z. FLEET_UI_LANG zh|en still forces the machine, before everything
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-ui-lang-person selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uilp-st.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$3" in *"$2"*) ;; *) fail "$1 (want '$2' in it)" "$3" ;; esac; }

export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"
unset FLEET_UI_LANG FLEET_VIEW_LANG FLEET_UI_PERSON_FILE LC_ALL LC_MESSAGES LC_CTYPE
export LANG=en_US.UTF-8   # the login's own locale: a 看台's connection must win over it
L() { sh "$BIN/fleet-ui-lang.sh" lang; }
H() { sh "$BIN/fleet-ui-lang.sh" first-hint "$1"; }

# --- A. none said ⇒ Chinese ----------------------------------------------------------
eq "A: no LANG brought ⇒ 中文" zh "$(FLEET_VIEW_LANG='' L)"
eq "A: … C / POSIX the same" zh "$(FLEET_VIEW_LANG=C L)$(FLEET_VIEW_LANG=POSIX L | sed 's/zh//')"
eq "A: … no one-time line" "" "$(FLEET_VIEW_LANG='' H devA)"
eq "A: zh_CN brought ⇒ 中文" zh "$(FLEET_VIEW_LANG=zh_CN.UTF-8 L)"
eq "A: outside a 看台 the login's locale, as before" en "$(L)"

# --- B. en_US ⇒ English, told once per device -----------------------------------------
eq "B: en_US brought ⇒ English" en "$(FLEET_VIEW_LANG=en_US.UTF-8 L)"
eq "B: … de_DE too (anything not zh)" en "$(FLEET_VIEW_LANG=de_DE.UTF-8 L)"
has "B: the first time, the one-time line" "Using English from your system (LANG=en_US.UTF-8) · ⌘P → Language to change" \
  "$(FLEET_VIEW_LANG=en_US.UTF-8 H devB)"
eq "B: … never twice for that device" "" "$(FLEET_VIEW_LANG=en_US.UTF-8 H devB)"
has "B: … another device is told its own" "Using English" "$(FLEET_VIEW_LANG=en_US.UTF-8 H devB2)"

# --- C. the person's choice wins, and silences detection ------------------------------
printf '{"version": 2, "bundle": {"roles": {}, "ui_lang": "zh"}}' > "$FLEET_CONF_DIR/person-bundle.json"
eq "C: set zh, en_US comes ⇒ still 中文" zh "$(FLEET_VIEW_LANG=en_US.UTF-8 L)"
eq "C: … and never the one-time line" "" "$(FLEET_VIEW_LANG=en_US.UTF-8 H devC)"
printf '{"version":3,"bundle":{"ui_lang":"en"}}' > "$FLEET_CONF_DIR/person-bundle.json"
eq "C: set en (one-line JSON), no LANG ⇒ English" en "$(FLEET_VIEW_LANG='' L)"
eq "C: … outside a 看台 too" en "$(LANG=zh_CN.UTF-8 L)"
printf '{"version":4,"bundle":{"roles":{"worker":"---\\nx: \\"ui_lang\\": \\"en\\"\\n---\\n"}}}' > "$FLEET_CONF_DIR/person-bundle.json"
eq "C: a role overlay quoting ui_lang is not a choice" zh "$(FLEET_VIEW_LANG='' L)"

# --- D. fleet-config.py lang: the hub (a seam), then this computer's copy -------------
printf '{"version":1,"bundle":{"roles":{}}}' > "$WORK/hub.json"
cat > "$WORK/hub.sh" <<EOF
#!/bin/sh
st='$WORK/hub.json'; body=\$(cat)
[ "\$1" = GET ] && { cat "\$st"; exit 0; }
python3 -c '
import json, sys
b, st = json.loads(sys.argv[1]), sys.argv[2]
cur = json.load(open(st))
if b.get("base") != cur["version"]:
    print(json.dumps({"status": 409, "error": "stale"})); sys.exit()
new = {"version": cur["version"] + 1, "prev": cur["version"], "bundle": b["bundle"]}
json.dump(new, open(st, "w")); print(json.dumps(new))' "\$body" "\$st"
EOF
export FLEET_PERSON_HUB_CMD="sh $WORK/hub.sh \"\$@\"" FLEET_PERSON_BUNDLE_CMD="cat $WORK/hub.json"
rm -f "$FLEET_CONF_DIR/person-bundle.json"
C() { python3 "$BIN/fleet-config.py" lang "$@"; }
C zh >/dev/null 2>"$WORK/err" || fail "D: lang zh failed" "$(cat "$WORK/err")"
eq "D: lang zh ⇒ the hub keeps ui_lang" zh "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle"].get("ui_lang"))' "$WORK/hub.json")"
eq "D: … the rest of the layer untouched" '{}' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["bundle"]["roles"]))' "$WORK/hub.json")"
eq "D: … this computer's copy re-read at once" zh "$(C)"
eq "D: … and drawn in it: en_US comes ⇒ 中文" zh "$(FLEET_VIEW_LANG=en_US.UTF-8 L)"
C auto >/dev/null 2>"$WORK/err" || fail "D: lang auto failed" "$(cat "$WORK/err")"
eq "D: 跟系统走 ⇒ no ui_lang on the hub" None "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundle"].get("ui_lang"))' "$WORK/hub.json")"
eq "D: … here" auto "$(C)"
eq "D: … detection again: en_US ⇒ English" en "$(FLEET_VIEW_LANG=en_US.UTF-8 L)"
eq "D: … none said ⇒ 中文" zh "$(FLEET_VIEW_LANG='' L)"
C fr >/dev/null 2>&1; eq "D: lang fr refused (exit 2)" 2 "$?"
unset FLEET_PERSON_HUB_CMD FLEET_PERSON_BUNDLE_CMD

# --- E. the validator, the hub's rule in Python ----------------------------------------
V() { python3 - "$BIN/fleet-agent-team.py" "$1" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("t", sys.argv[1]); t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
b = json.loads(sys.argv[2])
print(t.validate(b, "personal") or "ok", "|", t.validate(b, "team") or "ok")
PY
}
eq "E: zh ok (personal), not the team's" 'ok | bundle.ui_lang is not something a team hands out' "$(V '{"ui_lang":"zh"}')"
eq "E: en ok" 'ok' "$(V '{"ui_lang":"en"}' | cut -d' ' -f1)"
for bad in '"fr"' '"en_US.UTF-8"' '""' '1' '["zh"]'; do
  has "E: ui_lang $bad refused" 'bundle.ui_lang must be "zh" or "en"' "$(V "{\"ui_lang\":$bad}")"
done

# --- F. the top line --------------------------------------------------------------------
T() { (cd "$BIN" && python3 fleet-topbar.py render --node cw=100 "$@"); }
now=$(date +%s)
has "F: fl= within flu ⇒ the one-time line" "Using English" "$(T "fl=Using English from your system" "flu=$((now + 8))")"
case "$(T "fl=Using English from your system" "flu=$((now - 1))")" in *"Using English"*) fail "F: the one-time line outlived its seconds" ;; esac
CHECKS=$((CHECKS + 1))

# --- Z. the machine's force still comes first --------------------------------------------
printf '{"version":5,"bundle":{"ui_lang":"en"}}' > "$FLEET_CONF_DIR/person-bundle.json"
eq "Z: FLEET_UI_LANG=zh beats the person" zh "$(FLEET_UI_LANG=zh FLEET_VIEW_LANG=en_US.UTF-8 L)"
eq "Z: … and says nothing once" "" "$(FLEET_UI_LANG=zh FLEET_VIEW_LANG=en_US.UTF-8 H devZ)"

printf 'fleet-ui-lang-person selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
