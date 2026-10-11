#!/bin/bash
# fleet-ci-job-gate.sh — the test runner's job-started hook (claude-fleet#3144,
# EPIC #3139 C5 · 共同约定 7): a job runs on this machine only when it is the
# merged train's — never a pull request's.
#
# bin/fleet-ci-runner.py starts the runner with ACTIONS_RUNNER_HOOK_JOB_STARTED
# pointing here (a root-owned file the test login cannot change). The runner
# runs it as soon as a job is assigned, before any of the job's steps, with the
# job's GITHUB_* context in the environment; a non-zero exit fails the job with
# none of its steps run. A label alone cannot keep a pull_request job off the
# runner (GitHub matches labels whatever the event), so this is the rule:
#
#   GITHUB_REPOSITORY  = CI_GATE_REPO            (the one repo ci.env names)
#   GITHUB_EVENT_NAME  ∈ CI_GATE_EVENTS          (push workflow_dispatch schedule)
#   GITHUB_REF         = CI_GATE_REF             (refs/heads/master)
#   GITHUB_HEAD_REF    empty                     (set only on a pull request)
#   GITHUB_WORKFLOW_REF = <repo>/.github/workflows/<w>@<ref>, w ∈ CI_GATE_WORKFLOWS
#
# Anything missing refuses: a hook that cannot tell is a hook that says no.
# Exit 0 = the job may run · 1 = refused (one `::error::` line says why).
set -u

refuse() {
  printf '::error::fleet-ci: this runner takes only the merged train (%s) — refused: %s\n' \
    "${CI_GATE_REPO:-?}@${CI_GATE_REF:-?}" "$1"
  exit 1
}

repo="${CI_GATE_REPO:-}"
ref="${CI_GATE_REF:-refs/heads/master}"
events="${CI_GATE_EVENTS:-push workflow_dispatch schedule}"
wfs="${CI_GATE_WORKFLOWS:-}"

[ -n "$repo" ] || refuse "no CI_GATE_REPO"
[ -n "$wfs" ] || refuse "no CI_GATE_WORKFLOWS"
[ "${GITHUB_REPOSITORY:-}" = "$repo" ] || refuse "repository '${GITHUB_REPOSITORY:-}'"
[ -z "${GITHUB_HEAD_REF:-}" ] || refuse "a pull request (head ${GITHUB_HEAD_REF})"
ok=0
for e in $events; do [ "${GITHUB_EVENT_NAME:-}" = "$e" ] && ok=1; done
[ "$ok" = 1 ] || refuse "event '${GITHUB_EVENT_NAME:-}'"
[ "${GITHUB_REF:-}" = "$ref" ] || refuse "ref '${GITHUB_REF:-}'"
ok=0
for w in $wfs; do [ "${GITHUB_WORKFLOW_REF:-}" = "$repo/.github/workflows/$w@$ref" ] && ok=1; done
[ "$ok" = 1 ] || refuse "workflow '${GITHUB_WORKFLOW_REF:-}'"
printf 'fleet-ci: %s %s on %s — taken\n' "$GITHUB_EVENT_NAME" "${GITHUB_WORKFLOW_REF##*/}" "$GITHUB_REF"
exit 0
