#!/bin/bash
# fleet-quotawatch.sh — retired (T549, EPIC T542 C3). The per-minute quota watch
# is gone: a full subscription is the credential pool's to change, and its four
# side errands (modelcap sweep, proxy quota push, collector self-heal, alerts
# write) run on the state-reconcile tick, bin/fleet-reconcile-tick.sh. An old
# unit or an old caller that still runs this exits 0 quietly; `--status` answers
# `off`. compat-1v: 下一批删
for a in "$@"; do [ "$a" = --status ] && { printf 'off\t0\t0\n'; exit 0; }; done
exit 0
