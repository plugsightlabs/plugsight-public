#!/usr/bin/env bash
set -euo pipefail
swift build                             # builds plugsightd, which check-drift reads
swift test
ops/check-seam.sh
( cd mcp && npm run build && npm test )
node ops/check-drift.mjs
node ops/check-no-em-dash.mjs
