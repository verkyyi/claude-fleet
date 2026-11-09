#!/bin/bash
# Periodic entrypoint guard. Sourced: no shell option changes.
fleet_job_guard() {
  local key="$1"; shift
  if [ "${FLEET_JOB_PID:-}" = "$$" ] && [ "${FLEET_JOB_KEY:-}" = "$key" ] && [ -e /dev/fd/198 ]; then
    return 0
  fi
  exec python3 "${BASH_SOURCE[0]%/*}/fleet_tick_lock.py" run "$key" /bin/bash "$0" "$@"
}
