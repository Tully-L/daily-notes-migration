#!/bin/bash
# Entry point for the migrate-notes.sh regression suite. See ../TDD.md.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
/Users/tully/.platformio/python3/bin/python3.11 "$SCRIPT_DIR/run_tests.py"
