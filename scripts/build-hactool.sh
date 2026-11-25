#!/usr/bin/env bash
# Rebuilds the patched hactool that the app bundles under Contents/Resources/bin.
#
# The sources live in third_party/hactool/ (vendored, with our patches applied —
# see third_party/hactool/PATCHES.md). Building here keeps the shipped binary
# reproducible instead of depending on whatever was left in a scratch folder.
#
# Usage: ./scripts/build-hactool.sh [--clean]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/third_party/hactool"
OUT_DIR="${ROOT}/tools/hactool"

if [[ ! -f "${SRC}/Makefile" ]]; then
  echo "error: ${SRC}/Makefile not found" >&2
  exit 1
fi

if [[ "${1:-}" == "--clean" ]]; then
  make -C "${SRC}" clean >/dev/null 2>&1 || true
fi

make -C "${SRC}" -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null

mkdir -p "${OUT_DIR}"
cp "${SRC}/hactool" "${OUT_DIR}/hactool"
cp "${SRC}/LICENSE" "${OUT_DIR}/LICENSE"
chmod +x "${OUT_DIR}/hactool"

echo "built ${OUT_DIR}/hactool ($(shasum "${OUT_DIR}/hactool" | cut -c1-12))"
