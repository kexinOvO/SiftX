#!/bin/sh
# Fast, offline-safe regressions; native download integration is documented separately.
set -eu
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Swift package tests require macOS; see docs/TESTING.md." >&2
  exit 1
fi

python3 -m unittest discover -s Tests/ConfigurationTests -p 'test_*.py'
node --test Tests/ProbeTests/*.test.cjs
swift test
