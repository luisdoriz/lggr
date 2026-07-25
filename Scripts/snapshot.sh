#!/bin/bash
# Renders each Phase 2 screen to a PNG in light and dark, for visual review.
#
# `#Preview` cannot compile without Xcode, so this is how the UI gets looked at. Note the limitation
# recorded in docs/_design/SPIKE-menubar.md: screens whose content sits in a LazyVStack inside a
# ScrollView come back empty, because offscreen rendering has no viewport. Screenshot the running app
# for those.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT="${1:-build/snapshots}"

swift build --product LggrApp
"$(swift build --show-bin-path)/LggrApp" --snapshot "$OUTPUT"

echo ""
echo "open $OUTPUT"
