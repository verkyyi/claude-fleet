#!/usr/bin/env python3
# selftest-entry
"""Report delegation is retired; history remains readable without writes."""
from pathlib import Path
import subprocess
import sys

if __name__ == "__main__":
    sys.exit(subprocess.call([sys.executable, str(Path(__file__).with_name("fleet-parent-retirement-selftest.py")),
        "RetirementTests.test_old_entrypoints_return_immediately_without_writes",
        "RetirementTests.test_delegation_history_is_read_only"]))
