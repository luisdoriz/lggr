#!/bin/bash
# Launches Lggr against a throwaway store, checks it stays alive, and quits it.
#
# Never verify a build by launching it against the real store. Lggr keeps the only copy of the user's
# working history, and two habits from early development are both destructive once anyone actually
# uses the app: deleting the support folder afterwards to clear fixture data, and launching a second
# instance while the first is running — whose in-memory snapshot will overwrite whatever is on disk.
#
# LGGR_STORE_DIR redirects every writer (document, activity log, heartbeat) so neither can happen.
set -uo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-debug}"
SANDBOX="$(mktemp -d -t lggr-smoke)"
trap 'rm -rf "$SANDBOX"' EXIT

./Scripts/make-app.sh "$CONFIGURATION" > /dev/null || {
    echo "FAIL: could not assemble the app."
    exit 1
}

BINARY="build/Lggr.app/Contents/MacOS/LggrApp"

echo "==> Launching against $SANDBOX"
LGGR_STORE_DIR="$SANDBOX" "$BINARY" &
APP_PID=$!

sleep 8

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: the app is not running 8 seconds after launch."
    echo "      Diagnose with:"
    echo "      log show --last 90s --predicate 'process == \"LggrApp\"' | tail -40"
    exit 1
fi

echo "==> Alive (pid $APP_PID)"

# Ambient capture that records nothing is the quiet failure worth catching here.
if [ -d "$SANDBOX/activity" ]; then
    echo "==> Recording: $(find "$SANDBOX/activity" -type f | wc -l | tr -d ' ') file(s) written"
else
    echo "WARN: nothing written to $SANDBOX/activity — capture may not have started"
fi

kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null

echo "OK: launched, recorded and quit. The real store was never opened."
