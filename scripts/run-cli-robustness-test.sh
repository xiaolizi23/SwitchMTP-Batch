#!/bin/sh
# SwitchMTP Batch — CLI functional/robustness regression runner.
# Copyright (C) 2025 fratei
# SPDX-License-Identifier: GPL-2.0
#
# Exercises the Swift CLI's local-only surface: argument validation, error
# paths, empty/edge inputs, JSON well-formedness and the scan/deep-check
# wiring. It does NOT touch the console — no install, restore or download is
# issued, so it is safe to run with the Switch disconnected.
#
#   ./scripts/run-cli-robustness-test.sh
#   CLI_BIN=/path/to/switchmtp-cli ./scripts/run-cli-robustness-test.sh
#   FIXTURE=/path/to/games ./scripts/run-cli-robustness-test.sh
#
# Exit status 0 = every case passed.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=${FIXTURE:-${SWITCHMTP_BATCH_TEST_FOLDER:-$HOME/fixture}}

if [ -n "${CLI_BIN:-}" ]; then
    BIN="$CLI_BIN"
else
    BIN="$ROOT/build/cli-derived/Build/Products/Debug/switchmtp-cli"
fi
if [ ! -x "$BIN" ]; then
    echo "missing CLI binary at $BIN — build the switchmtp-cli scheme first" >&2
    exit 2
fi

WORK=$(mktemp -d /tmp/switchmtp-cli-robust.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
echo "not a title" > "$WORK/bad.txt"

PASS=0
FAIL=0

# expect_exit <expected-code>[|<code>...] <label> -- <argv...>
expect_exit() {
    expected=$1; label=$2; shift 2
    case $1 in --) shift;; esac
    set +e
    "$BIN" "$@" >"$WORK/out.txt" 2>"$WORK/err.txt"
    code=$?
    set -e
    if echo "$expected" | tr '|' '\n' | grep -qx "$code"; then
        echo "PASS  [$label] exit=$code"
        PASS=$((PASS+1))
    else
        echo "FAIL  [$label] expected exit=$expected, got $code"
        echo "      stderr: $(head -1 "$WORK/err.txt")"
        FAIL=$((FAIL+1))
    fi
}

echo "== CLI robustness suite =="
echo "binary: $BIN"

# Help / version / usage
expect_exit 0 "help"            -- --help
expect_exit 0 "version"          -- version
expect_exit 0 "version-flag"     -- --version
expect_exit 0 "version-short"    -- -V
expect_exit 2 "unknown-command" -- frobnicate

# version --json carries platform/arch for machine-readable consumers.
set +e
"$BIN" version --json >"$WORK/ver.json" 2>"$WORK/ver.err"
ver_code=$?
set -e
if [ "$ver_code" -eq 0 ] && python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert {"version","os","arch"} <= set(d), d
assert d["arch"] in ("arm64", "x86_64"), d
' "$WORK/ver.json"; then
    echo "PASS  [version-json] arch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["arch"])' "$WORK/ver.json")"
    PASS=$((PASS+1))
else
    echo "FAIL  [version-json] exit=$ver_code"; head -1 "$WORK/ver.err"
    FAIL=$((FAIL+1))
fi
expect_exit 2 "batch-no-sub"    -- batch
expect_exit 2 "batch-bad-sub"   -- batch frob

# Argument validation (usage = 2)
expect_exit 2 "scan-no-path"      -- batch scan
expect_exit 2 "install-no-path"   -- batch install
expect_exit 2 "install-sd-nand-both" -- batch install --sd --nand /nonexistent
expect_exit 2 "restore-no-arg"    -- restore-saves
expect_exit 2 "album-no-arg"      -- export-album
expect_exit 2 "gamecard-no-arg"    -- dump-gamecard
expect_exit 2 "ls-no-arg"         -- ls
expect_exit 2 "cp-too-few"        -- cp a b
expect_exit 2 "get-local-source"  -- get local.txt ./dir
expect_exit 2 "put-device-source" -- put 65537:/a.txt 65537:/b.txt
expect_exit 1 "put-missing-local" -- put /nonexistent/game.nsp 65537:/games
expect_exit 2 "download-no-dest"  -- download 65537:/a.nsp
expect_exit 2 "upload-no-dest"    -- upload a.nsp

# Zero-argument commands reject trailing arguments.
expect_exit 2 "devices-extra-arg"   -- devices foo
expect_exit 2 "info-extra-arg"      -- info foo
expect_exit 2 "storages-extra-arg"  -- storages foo
expect_exit 2 "doctor-extra-arg"    -- doctor foo

# Mutating-command guards, validated before any device connection.
expect_exit 2 "rm-root"          -- rm 65537:/
expect_exit 2 "rm-cross-storage" -- rm 65537:/a.txt 65538:/b.txt
expect_exit "3|5" "rm-case-insensitive" -- rm sdcard:/a.txt SDCARD:/b.txt
expect_exit 2 "mv-bad-name"      -- mv 65537:/a.txt ../evil.bin
expect_exit 2 "mv-cross-dir"      -- mv 65537:/a/old.nro 65537:/b/new.nro
expect_exit "3|5" "mv-full-dest"    -- mv 65537:/a/old.nro 65537:/a/new.nro
expect_exit 2 "mkdir-root"       -- mkdir 65537:/
expect_exit 2 "install-bad-ext"      -- install "$WORK/bad.txt"
expect_exit 1 "install-missing-local" -- install /nonexistent/game.nsp

# Missing / bad inputs (failure = 1)
expect_exit 1 "scan-missing-path"    -- batch scan /nonexistent/path/xyz
expect_exit 1 "install-missing-path" -- batch install /nonexistent/path/xyz
expect_exit 1 "restore-missing-dir"  -- restore-saves /nonexistent/dir
expect_exit 1 "restore-empty-dir"   -- restore-saves "$EMPTY"

# Empty directory: no crash, zero packages, exit 0
expect_exit 0 "scan-empty-dir" -- batch scan "$EMPTY"

# Bad keyset is only rejected when there is something to verify against.
if [ -d "$FIXTURE" ]; then
    expect_exit 1 "scan-bad-keys" -- batch scan "$FIXTURE" --keys /nonexistent/prod.keys
else
    echo "SKIP  [scan-bad-keys] fixture not found: $FIXTURE"
fi

# JSON well-formedness on the fixture when present.
if [ -d "$FIXTURE" ]; then
    set +e
    "$BIN" batch scan "$FIXTURE" --json >"$WORK/scan.json" 2>"$WORK/scan.err"
    json_code=$?
    set -e
    if [ "$json_code" -ne 0 ]; then
        echo "FAIL  [fixture-scan-json] exit=$json_code"; cat "$WORK/scan.err"
        FAIL=$((FAIL+1))
    elif python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert {"groups","packages","summary"} <= set(d), "missing top-level keys"
for p in d["packages"]:
    for k in ("file","titleId","baseTitleId","contentType","format","size",
              "quickVerdict","deepState","verdict","selectable","notes"):
        assert k in p, f"missing field {k}"
assert d["summary"]["count"] == len(d["packages"])
' "$WORK/scan.json"; then
        echo "PASS  [fixture-scan-json] $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["summary"]["count"],"packages")' "$WORK/scan.json")"
        PASS=$((PASS+1))
    else
        echo "FAIL  [fixture-scan-json] JSON invalid or fields missing"
        FAIL=$((FAIL+1))
    fi
else
    echo "SKIP  [fixture-scan-json] fixture not found: $FIXTURE"
fi

echo
echo "== Result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
