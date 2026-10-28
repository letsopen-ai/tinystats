#!/bin/bash
# Require the final Swift Testing completion, including its singular test/suite grammar.
# XCTest-only or interrupted zero-exit output is not sufficient.
set -euo pipefail
grep -Eq 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed' -- "${1:?Swift test log path}"
