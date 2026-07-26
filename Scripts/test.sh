#!/bin/bash
# Runs the LggrKit test suite.
#
# Why this wrapper exists: with Command Line Tools (no Xcode), plain `swift test` builds the test
# bundle, prints "Build complete!", exits 0 — and silently runs nothing, because SwiftPM cannot
# locate Testing.framework, which CLT installs outside the SDK. A green exit code with zero tests
# executed is worse than a failure, so this script passes the framework search path explicitly and
# then asserts that a test run actually happened.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

# These have to be passed on the command line, not only in Package.swift: with the manifest settings
# alone SwiftPM compiles and links the bundle but then declines to run it, exiting 0 in silence.
SWIFT_TEST_ARGS=()
# Any Xcode*.app counts, betas and versioned installs included; pointing the compiler at the Command
# Line Tools copy of Testing.framework while Xcode is active would shadow Xcode's own.
if compgen -G "/Applications/Xcode*.app" > /dev/null || [ "${LGGR_NO_CLT_TESTING_FLAGS:-}" = "1" ]; then
    HAS_XCODE=1
else
    HAS_XCODE=0
fi

if [ -d "$CLT_FRAMEWORKS/Testing.framework" ] && [ "$HAS_XCODE" -eq 0 ]; then
    SWIFT_TEST_ARGS+=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS")
    SWIFT_TEST_ARGS+=(-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

OUTPUT_FILE="$(mktemp -t lggr-test)"
trap 'rm -f "$OUTPUT_FILE"' EXIT

# `${a[@]+"${a[@]}"}` rather than `"${a[@]}"`: macOS ships bash 3.2, where expanding an *empty* array
# under `set -u` is an unbound-variable error. The array is only empty when Xcode is installed — which
# is never true on the machine this was written on and always true in CI, so the plain form passed
# locally and failed on the first push.
swift test ${SWIFT_TEST_ARGS[@]+"${SWIFT_TEST_ARGS[@]}"} "$@" 2>&1 | tee "$OUTPUT_FILE"
SWIFT_TEST_STATUS=${PIPESTATUS[0]}

if [ "$SWIFT_TEST_STATUS" -ne 0 ]; then
    echo ""
    echo "FAIL: swift test exited with status $SWIFT_TEST_STATUS."
    exit "$SWIFT_TEST_STATUS"
fi

# Guard against the silent-skip trap described above.
#
# The count is extracted and compared, not merely matched. An earlier version of this guard tested
# for `Test run with [0-9]+ test`, which "Test run with 0 tests in 0 suites passed" satisfies — so
# the one line written to catch a zero-test run was itself waving it through.
TEST_COUNT="$(grep -oE 'Test run with [0-9]+ test' "$OUTPUT_FILE" | grep -oE '[0-9]+' | head -1)"

if [ -z "$TEST_COUNT" ]; then
    echo ""
    echo "FAIL: swift test reported success but printed no test-run summary at all."
    echo "      This is the Testing.framework discovery problem, not a passing suite."
    exit 1
fi

if [ "$TEST_COUNT" -eq 0 ]; then
    echo ""
    echo "FAIL: swift test executed zero tests and called it a pass."
    exit 1
fi

# A suite that suddenly shrinks is the quieter version of the same failure: a target that stopped
# being discovered still reports a healthy-looking number for whatever remains. The floor is
# committed, so a genuine reduction has to be an explicit, reviewable edit to this file.
MINIMUM_TESTS=667
if [ "$TEST_COUNT" -lt "$MINIMUM_TESTS" ]; then
    echo ""
    echo "FAIL: only $TEST_COUNT tests ran; this suite has had at least $MINIMUM_TESTS."
    echo "      Either a test target stopped being discovered, or tests were removed."
    echo "      If the reduction is deliberate, lower MINIMUM_TESTS in Scripts/test.sh."
    exit 1
fi

if grep -qE 'Test run with [0-9]+ test.* failed' "$OUTPUT_FILE"; then
    echo ""
    echo "FAIL: the test run reported failures."
    exit 1
fi

echo ""
echo "OK: $(grep -oE 'Test run with [0-9]+ test[s]? in [0-9]+ suite[s]? passed.*' "$OUTPUT_FILE" | head -1)"
