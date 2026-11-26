#!/bin/sh
# SwitchMTP Batch — AX regression test runner for the scrolling plan list.
# Copyright (C) 2025 fratei
# SPDX-License-Identifier: GPL-2.0
#
# Builds the probe, launches build/products with a fixture folder and runs the
# suite against that process. The release app in the parent folder is a
# different path and is left alone.
#
#   ./scripts/run-ax-scroll-list-test.sh            # 44-package fixture
#   FIXTURE=~/some/folder ./scripts/run-ax-scroll-list-test.sh
#
# Exit status 0 = every case passed.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/products/SwitchMTP Batch.app"
BIN="$APP/Contents/MacOS/SwitchMTPBatch"
TEST="$ROOT/build/tools/ax-scroll-list-test"
FIXTURE=${FIXTURE:-${SWITCHMTP_BATCH_TEST_FOLDER:-$HOME/fixture}}

if [ ! -x "$BIN" ]; then
    echo "missing $BIN — run scripts/build-xcode-app.sh first" >&2
    exit 2
fi

if [ ! -d "$FIXTURE" ]; then
    echo "fixture folder not found: $FIXTURE" >&2
    exit 2
fi

mkdir -p "$ROOT/build/tools"
xcrun swiftc -O "$ROOT/scripts/ax-scroll-list-test.swift" -o "$TEST"

# Stop only this build's own instances.
for pid in $(pgrep -f "$BIN" || true); do
    kill "$pid" 2>/dev/null || true
done
sleep 1

SWITCHMTP_BATCH_TEST_FOLDER="$FIXTURE" "$BIN" >/tmp/switchmtp-ax-scroll-test.log 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT INT TERM

sleep 4
"$TEST" "$APP_PID"
