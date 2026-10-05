#!/bin/bash
# The Bridge's offline tests: the control centre's request policy
# (control_policy.swift). No Bridge, no VM, no network.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -o "$out/control-tests" \
  control_policy.swift tests/control_tests.swift
"$out/control-tests"
