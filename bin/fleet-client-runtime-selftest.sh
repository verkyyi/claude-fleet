#!/bin/bash
# fleet-client-runtime-selftest.sh — conf/client-runtime.list and the tool that
# makes it, bin/fleet-client-runtime.sh (issue #4824, EPIC #4823 C1).
#
#   A  --check on the committed list: every path in fleetclient/manifest, every
#      line well formed — exit 0
#   B  --check on a bad list: a path off the manifest, a path twice, an unknown
#      action, `static:read`, a line with no actions — exit 1, each one named
#   C  parse: a synthetic `strace -ff` run under a fake install root — an execve
#      of an installed file, the script python was started on, a module import
#      (its __pycache__ entry, found or written), a `.` by sh, `awk -f` ran;
#      python reading a hook as data is `:read`; a cp of a file, a failed open,
#      a directory, a path outside the root count for nothing; the per-process
#      files are removed
#   D  build: run beats read for the same action; one static hop from a file
#      that ran (fleet-host.sh → fleet-host-install.sh), none from a static file;
#      nothing followed out of fleet-client-core.sh; the list it writes passes --check
#   E  usage → 2
#   G  (issue #4826) --check's reference rule: a file an installed script names
#      and the package forgot → exit 1 with its file:line; NOT_HERE is excused
#   F  (issue #4826) --check the other way: a file the manifest installs and
#      the list lacks → exit 1, named; a `served` one off the list is fine; the
#      hand-written `agent` / `dispatch` uses survive a rebuild (leg D)
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
RT="$BIN/fleet-client-runtime.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/client-runtime.XXXXXX")
trap 'rm -rf "${T:?}"' EXIT
fail=0
ok() { echo "PASS  $1"; }
no() { echo "FAIL  $1"; fail=1; }
tab=$(printf '\t')

# A — the committed list
if out=$(bash "$RT" --check 2>&1); then ok "A the committed list passes --check"; else no "A --check: $out"; fi
n=$(grep -vc '^#' "$BIN/../conf/client-runtime.list")
[ "$n" -gt 30 ] && ok "A the list has $n files" || no "A only $n files on the list"
grep -q "^bin/fleet${tab}" "$BIN/../conf/client-runtime.list" && grep -q "^bin/fleet-thin.py${tab}.*view" "$BIN/../conf/client-runtime.list" \
  && ok "A bin/fleet and the thin client's view are on it" || no "A bin/fleet / fleet-thin.py view missing"

# B — a bad list
cat > "$T/bad.list" <<EOF
# a comment
bin/fleet${tab}view
bin/fleet${tab}ls
bin/no-such-file.sh${tab}view
bin/fleet-thin.py${tab}view,fly
bin/fleet-connect.py${tab}static:read
bin/fleet-login.py
EOF
out=$(bash "$RT" --check "$T/bad.list" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "B a bad list → exit 1" || no "B rc=$rc"
for w in 'bin/fleet twice' 'bin/no-such-file.sh is not in the client manifest' "unknown action 'fly'" "unknown action 'static:read'" 'not <path> TAB <actions>'; do
  case $out in *"$w"*) ok "B named: $w" ;; *) no "B not named: $w — $out" ;; esac
done

# C — parse a synthetic strace -ff run
R="$T/root"; mkdir -p "$R/bin/__pycache__" "$R/hooks" "$R/conf"
printf '#!/bin/sh\n' > "$R/bin/fleet"   # a #! script: its process is a sh
for f in bin/fleet-thin.py bin/fleet_tls.py bin/fleet-lib.sh bin/fleet-shape.awk bin/fleet-connect.py hooks/bash-guard.py conf/secret-shapes.list bin/fleet-login.py; do
  : > "$R/$f"
done
P="$T/view.strace"
cat > "$P.100" <<EOF
execve("$R/bin/fleet", ["$R/bin/fleet"], 0x7ffd /* 9 vars */) = 0
openat(AT_FDCWD, "$R/bin/fleet-lib.sh", O_RDONLY) = 3
openat(AT_FDCWD, "$R/bin", O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_DIRECTORY) = 3
openat(AT_FDCWD, "$R/bin/missing.sh", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/passwd", O_RDONLY|O_CLOEXEC) = 3
EOF
cat > "$P.101" <<EOF
execve("/usr/bin/python3", ["python3", "$R/bin/fleet-thin.py", "--view", "x"], 0x7ffd /* 9 vars */) = 0
openat(AT_FDCWD, "$R/bin/__pycache__/fleet_tls.cpython-312.pyc", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "$R/bin/fleet_tls.py", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "$R/bin/__pycache__/fleet_tls.cpython-312.pyc.1399", O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0644) = 3
openat(AT_FDCWD, "$R/bin/__pycache__/fleet-login.cpython-312.pyc", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "$R/hooks/bash-guard.py", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "$R/conf/secret-shapes.list", O_RDONLY|O_CLOEXEC) = 3
openat(AT_FDCWD, "$R/bin/fleet-connect.py", O_RDONLY|O_CLOEXEC) = 3
EOF
cat > "$P.102" <<EOF
execve("/usr/bin/awk", ["awk", "-v", "table=x", "-f", "$R/bin/fleet-shape.awk"], 0x7ffd /* 9 vars */) = 0
EOF
cat > "$P.103" <<EOF
execve("/usr/bin/cp", ["cp", "$R/bin/fleet-connect.py", "/tmp/x"], 0x7ffd /* 9 vars */) = 0
openat(AT_FDCWD, "$R/bin/fleet-connect.py", O_RDONLY) = 3
EOF
got=$(bash "$RT" parse "$P" "$R" view | sort)
want=$(printf '%s\n' "bin/fleet${tab}view" "bin/fleet-lib.sh${tab}view" "bin/fleet-login.py${tab}view" \
  "bin/fleet-shape.awk${tab}view" "bin/fleet-thin.py${tab}view" "bin/fleet_tls.py${tab}view" \
  "bin/fleet-connect.py${tab}view:read" "conf/secret-shapes.list${tab}view:read" "hooks/bash-guard.py${tab}view:read" | sort)
[ "$got" = "$want" ] && ok "C parse: ran · imported · sourced · awk -f; data reads :read; tools / failures / dirs / outside nothing" \
  || { no "C parse"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"); }
ls "$P".* >/dev/null 2>&1 && no "C the per-process files are left" || ok "C the per-process files are removed"

# D — build
mkdir -p "$T/d1" "$T/d2"
printf '%s\n' "bin/fleet-host.sh${tab}host-on" "bin/fleet-connect.py${tab}view:read" "conf/secret-shapes.list${tab}view:read" > "$T/d1/used.tsv"
printf '%s\n' "bin/fleet-connect.py${tab}view" "bin/not-in-manifest.sh${tab}view" > "$T/d2/used.tsv"
bash "$RT" build "$T/d1" "$T/d2" --write "$T/built.list" 2>"$T/build.err"
grep -q "^bin/fleet-connect.py${tab}view$" "$T/built.list" && ok "D run beats read for one action" || no "D connect: $(grep fleet-connect "$T/built.list")"
grep -q "^conf/secret-shapes.list${tab}view:read$" "$T/built.list" && ok "D a read alone stays :read" || no "D secret-shapes: $(grep secret-shapes "$T/built.list")"
grep -q "^bin/fleet-host-install.sh${tab}static$" "$T/built.list" && ok "D one static hop from a file that ran" || no "D no static fleet-host-install.sh"
grep -q 'not-in-manifest' "$T/built.list" && no "D a path off the manifest was listed" || ok "D a path off the manifest is dropped"
# fleet-release-sign.py is named by fleet-release-key.sh (static here), not by fleet-host.sh
grep -q '^bin/fleet-release-sign.py' "$T/built.list" && no "D a static file's names were followed (fleet-release-sign.py)" || ok "D no hop from a static file"
# well formed (a list off two actions misses most installed files — that half is F's)
out=$(bash "$RT" --check "$T/built.list" 2>&1 | grep -v 'is installed by the client manifest but on no line')
[ -z "$out" ] && ok "D the built list passes --check's line rules" || no "D built list fails --check: $out"
printf '%s\n' "bin/fleet-client-core.sh${tab}ls" > "$T/d1/used.tsv"
bash "$RT" build "$T/d1" --write "$T/lib.list" 2>/dev/null
[ "$(grep -vc '^#' "$T/lib.list")" = 1 ] && ok "D nothing followed out of fleet-client-core.sh" || no "D fleet-client-core.sh: $(grep -v '^#' "$T/lib.list" | head -5)"
# the hand-written uses (issue #4826) carry over from the list a build replaces
printf '%s\n' "bin/fleet-node-leave.sh${tab}agent" "bin/fleet-route.py${tab}dispatch" >> "$T/lib.list"
bash "$RT" build "$T/d1" --write "$T/lib.list" 2>/dev/null
grep -q "^bin/fleet-node-leave.sh${tab}agent$" "$T/lib.list" && grep -q "^bin/fleet-route.py${tab}dispatch$" "$T/lib.list" \
  && ok "D agent / dispatch carry over a rebuild" || no "D hand uses lost: $(grep -v '^#' "$T/lib.list")"

# F — the other way (issue #4826): a file the manifest INSTALLS is on the list;
# a `served` one need not be
grep -v '^#' "$BIN/../conf/client-runtime.list" | grep -v "^bin/fleet-route.py${tab}" > "$T/short.list"
out=$(bash "$RT" --check "$T/short.list" 2>&1); rc=$?
[ "$rc" = 1 ] && case $out in *'bin/fleet-route.py is installed by the client manifest but on no line'*) true ;; *) false ;; esac \
  && ok "F an installed file off the list → exit 1, named" || no "F rc=$rc $out"
grep -v '^#' "$BIN/../conf/client-runtime.list" | grep -v "^bin/fleet-node-join.sh${tab}" > "$T/served.list"
grep -q '^bin/fleet-node-join.sh[[:space:]]\{1,\}served$' "$BIN/../tokenledger/hub/api/fleetclient/manifest" \
  && bash "$RT" --check "$T/served.list" >/dev/null 2>&1 && ok "F a served file off the list is fine" || no "F served: $(bash "$RT" --check "$T/served.list" 2>&1)"

# G — what the installed scripts name (issue #4826, BREAK-IT client-pack-file-missing):
# a file the package forgot is named; one of NOT_HERE (fleet-hub-sessions.sh) is not
grep -v '^bin/fleet_iso.py$' "$BIN/../tokenledger/hub/api/fleetclient/manifest" > "$T/forgot.manifest"
grep -v "^bin/fleet_iso.py${tab}" "$BIN/../conf/client-runtime.list" > "$T/forgot.list"
out=$(bash "$RT" --check "$T/forgot.list" "$T/forgot.manifest" 2>&1); rc=$?
[ "$rc" = 1 ] && case $out in *'bin/fleet-services.py:'*'names bin/fleet_iso.py, which the client package neither installs nor serves'*) true ;; *) false ;; esac \
  && ok "G a forgotten file a client script names → exit 1, file:line named" || no "G rc=$rc $out"
printf '%s' "$out" | grep -q 'fleet-hub-sessions.sh' && no "G a NOT_HERE file was reported" || ok "G a home-side file (NOT_HERE) is not reported"

# E — usage
bash "$RT" >/dev/null 2>&1; [ $? = 2 ] && ok "E no command → 2" || no "E usage rc"
bash "$RT" parse x >/dev/null 2>&1; [ $? = 2 ] && ok "E parse with one argument → 2" || no "E parse usage rc"

[ "$fail" = 0 ] && echo "fleet-client-runtime-selftest: ok" || echo "fleet-client-runtime-selftest: FAILED"
exit "$fail"
