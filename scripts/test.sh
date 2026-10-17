#!/bin/bash
# Command Line Tools ship the Swift Testing macros outside the default plugin search path.
set -euo pipefail
cd "$(dirname "$0")/.."
plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
