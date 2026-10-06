#!/bin/bash
# fleet-node-sleepwatch.sh — say when this computer is about to sleep and when
# it woke (issue #1721, EPIC #1718 C3): one line each on stdout, for as long
# as it runs —
#
#   ready    the watch is listening
#   sleep    the system is about to sleep (lid closed, the Apple menu's Sleep,
#            the idle timer) — NSWorkspaceWillSleepNotification
#   wake     it woke — NSWorkspaceDidWakeNotification
#
# The node's agent (ccquota, internal/agent/node_sleep.go) runs it on a
# PERSONAL login (`fleet node compute on --personal`): `sleep` flags the
# machine 维护中 with reason sleep and tells the person's client how many
# sessions are still running; `wake` clears that flag. The agent also spots a
# wake on its own (its wall clock jumped past its monotonic one), so a watch
# that cannot run costs the warning before sleep, never the wake.
#
# macOS only — osascript's JavaScript bridge, in the login's GUI session (a
# LaunchAgent is). Elsewhere, or with no osascript: exit 3, and the agent does
# not start it again. FLEET_SLEEPWATCH_SELFTEST=1 posts one sleep and one wake
# to itself and exits — the selftest's seam, no sleep needed.
set -uo pipefail

[ "$(uname -s)" = Darwin ] || exit 3
command -v osascript >/dev/null 2>&1 || exit 3

script=$(cat <<'JXA'
ObjC.import('AppKit');
function out(s) {
  $.NSFileHandle.fileHandleWithStandardOutput.writeData($(s + "\n").dataUsingEncoding($.NSUTF8StringEncoding));
}
ObjC.registerSubclass({ name: 'FleetSleepWatch', methods: {
  'willSleep:': { types: ['void', ['id']], implementation: function (n) { out('sleep'); } },
  'didWake:': { types: ['void', ['id']], implementation: function (n) { out('wake'); } },
}});
var watch = $.FleetSleepWatch.alloc.init;
var nc = $.NSWorkspace.sharedWorkspace.notificationCenter;
nc.addObserverSelectorNameObject(watch, 'willSleep:', $.NSWorkspaceWillSleepNotification, $());
nc.addObserverSelectorNameObject(watch, 'didWake:', $.NSWorkspaceDidWakeNotification, $());
out('ready');
if ($.NSProcessInfo.processInfo.environment.objectForKey('FLEET_SLEEPWATCH_SELFTEST').js === '1') {
  nc.postNotificationNameObject($.NSWorkspaceWillSleepNotification, $());
  nc.postNotificationNameObject($.NSWorkspaceDidWakeNotification, $());
  $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.5));
} else {
  $.NSRunLoop.currentRunLoop.run;
}
JXA
)
exec osascript -l JavaScript -e "$script"
