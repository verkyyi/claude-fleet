#!/bin/bash
# Print the tag of the fleet-ci-runner image: ci-<16 hex> of the text it is built
# from — every file under extras/ci-runner/, tokenledger/{hub,shared,agent,e2e}/go.{mod,sum}
# (its Go module cache; modules since #4811, #4812, #4814) and bin/fleet-ci-job-gate.sh (its job gate). Usage: tag.sh [<repo root>]
#
# The same text ⇒ the same tag ⇒ build.sh pushes nothing (issue #3864); a pin
# moved anywhere in it is a new tag, so the scale set never runs a stale copy
# under a current name.
set -euo pipefail
ROOT=${1:-"$(cd "$(dirname "$0")/../.." && pwd)"}
cd "$ROOT"
sum() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }
h=$(for f in $(LC_ALL=C find extras/ci-runner -type f ! -name '*.md' | LC_ALL=C sort) \
            tokenledger/hub/go.mod tokenledger/hub/go.sum tokenledger/shared/go.mod tokenledger/shared/go.sum \
            tokenledger/agent/go.mod tokenledger/agent/go.sum tokenledger/e2e/go.mod tokenledger/e2e/go.sum \
            bin/fleet-ci-job-gate.sh; do
      printf '%s\n' "$f"; sum < "$f"
    done | sum)
echo "ci-${h:0:16}"
