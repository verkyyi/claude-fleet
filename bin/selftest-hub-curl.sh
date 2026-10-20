# shellcheck shell=bash
# selftest-hub-curl.sh — the stub curl the operator-command selftests hand their
# script through FLEET_HUB_CURL (sourced; not a test). fleet-node-revoke,
# fleet-node-trust, fleet-cred-policy and fleet-machine-policy each had a copy.
#
#   hc_stub [by-path]  writes $WORK/curl and exports it: argv → STUB_LOG, the stdin
#                  header (-H @-) → STUB_HDR, "<method> <url> <body>" → STUB_BODY;
#                  answers from $FAKE_DIR/<last path segment>.{body,code}, else
#                  $FAKE_DIR/{body,code}, else {} 200; FAKE_RC set = curl fails so
#   reset          forgets every record and answer
#   fake [name] <body> [code]   an answer: by name after `hc_stub by-path`, else the one
hc_stub() {
  HC_BY_PATH=0; [ "${1:-}" = by-path ] && HC_BY_PATH=1
  STUB="$WORK/curl"
  cat > "$STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
body='' url='' method=GET hdr=''
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) body="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) [ "$2" = @- ] && hdr=$(cat); shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$hdr" >> "$STUB_HDR"
printf '%s %s %s\n' "$method" "$url" "$body" >> "$STUB_BODY"
[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"
n="$FAKE_DIR/${url##*/}."
[ -e "${n}body" ] || [ -e "${n}code" ] || n="$FAKE_DIR/"
printf '%s\n%s' "$(cat "${n}body" 2>/dev/null || printf '{}')" "$(cat "${n}code" 2>/dev/null || printf 200)"
STUB
  chmod +x "$STUB"
  export STUB_LOG="$WORK/curl.log" STUB_HDR="$WORK/curl.hdr" STUB_BODY="$WORK/curl.body" FLEET_HUB_CURL="$STUB" \
    FAKE_DIR="$WORK/fake"
  mkdir -p "$FAKE_DIR"
}
reset() { rm -f "$STUB_LOG" "$STUB_HDR" "$STUB_BODY" "$FAKE_DIR"/*; unset FAKE_RC; }
fake() {
  if [ "$HC_BY_PATH" = 1 ]; then
    printf '%s' "$2" > "$FAKE_DIR/$1.body"; printf '%s' "${3:-200}" > "$FAKE_DIR/$1.code"
  else
    printf '%s' "$1" > "$FAKE_DIR/body"; printf '%s' "${2:-200}" > "$FAKE_DIR/code"
  fi
}
