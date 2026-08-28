#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The seam (docs/spec/02): PlugsightCore is platform-neutral and MUST NOT import
# IOKit, CoreGraphics, or EndpointSecurity (nor any submodule of them, e.g.
# `import IOKit.hid`). Build the target, then fail on any such import.
swift build --target PlugsightCore

if grep -REn 'import[[:space:]]+(IOKit|CoreGraphics|EndpointSecurity)([[:space:]]|\.|$)' Sources/PlugsightCore; then
  echo "SEAM VIOLATION: PlugsightCore imports a platform framework" >&2
  exit 1
fi

echo "seam OK"
