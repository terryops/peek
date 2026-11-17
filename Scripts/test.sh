#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# AppKit, WebKit and the SSH probes keep process-wide state. Give each suite
# its own test process and store while discovering every suite in the package.
SUITES="$(swift test list --disable-xctest | cut -d / -f 1 | sort -u)"
[[ -n "$SUITES" ]] || { echo "No Swift test suites found" >&2; exit 1; }
STORE=""
trap '[[ -z "$STORE" ]] || rm -rf "$STORE"' EXIT
for SUITE in $SUITES; do
    STORE="$(mktemp -d /tmp/peek-tests.XXXXXX)"
    PEEK_HOME="$STORE" swift test --skip-build --disable-xctest --no-parallel --filter "^${SUITE}/"
    rm -rf "$STORE"
    STORE=""
done
