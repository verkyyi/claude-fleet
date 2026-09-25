#!/bin/bash
# fleet-ui-lang-selftest.sh — FLEET_UI_LANG selector and core tmux UI strings.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
pass=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; ok "$1"; }

eq 'en forced' "$(FLEET_UI_LANG=en "$BIN/fleet-ui-lang.sh" lang)" en
eq 'zh forced' "$(FLEET_UI_LANG=zh "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows zh locale' "$(LC_ALL= LC_MESSAGES= LC_CTYPE= FLEET_UI_LANG=auto LANG=zh_CN.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows en locale' "$(LC_ALL= LC_MESSAGES= LC_CTYPE= FLEET_UI_LANG=auto LANG=en_US.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" en
eq 'auto preserves Chinese in C locale' "$(LC_ALL= LC_MESSAGES= LC_CTYPE= FLEET_UI_LANG=auto LANG=C "$BIN/fleet-ui-lang.sh" lang)" zh

# Importing fleet-sidebar.py would run none of its main loop, but its filename has
# a dash. Probe through a tiny importlib shim so the constants are tested as used.
probe_sidebar() {
  FLEET_UI_LANG=$1 python3 - "$BIN/fleet-sidebar.py" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("fleet_sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.PLACEHOLDER)
print(mod.HELP_ROW)
print(mod.target_name("hdr:none"))
print(mod.placeholder("hdr:none"))
PY
}

eq 'sidebar English strings' "$(probe_sidebar en | paste -sd'|' -)" 'New session name…| ? keys|no repo|New session → no repo…'
eq 'sidebar Chinese strings' "$(probe_sidebar zh | paste -sd'|' -)" '新会话名…| ? 快捷键|无仓库|新会话 → 无仓库…'
eq 'ghost English' "$(FLEET_UI_LANG=en FLEET_SESSION= "$BIN/dash-agent-prompt.sh" ghost 2>/dev/null)" '↵ new scratch (prefilled, unsent) · switch agent: ⌃v'
eq 'ghost Chinese' "$(FLEET_UI_LANG=zh FLEET_SESSION= "$BIN/dash-agent-prompt.sh" ghost 2>/dev/null)" '↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v'

printf 'selftest OK: %s assertions passed (FLEET_UI_LANG)\n' "$pass"
