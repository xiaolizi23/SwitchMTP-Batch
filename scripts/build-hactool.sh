#!/usr/bin/env bash
# Rebuilds the patched hactool that the app bundles under Contents/Resources/bin.
#
# The sources live in third_party/hactool/ (vendored, with our patches applied —
# see third_party/hactool/PATCHES.md). Building here keeps the shipped binary
# reproducible instead of depending on whatever was left in a scratch folder.
#
# The vendored mbedtls has its x86_64 inline asm disabled (see config.h): that
# asm path computes a wrong RSA modexp on x86, which made genuine signatures
# report FAIL. With the generic C path the RSA result is byte-identical on
# arm64 and x86_64, so the bundled binary is universal again.
#
# Usage: ./scripts/build-hactool.sh [--clean] [ARCHS="arm64 x86_64"]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/third_party/hactool"
OUT_DIR="${ROOT}/tools/hactool"
ARCHS="${ARCHS:-arm64 x86_64}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ ! -f "${SRC}/Makefile" ]]; then
  echo "error: ${SRC}/Makefile not found" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

clean_src() {
  make -C "${SRC}" clean >/dev/null 2>&1 || true
  make -C "${SRC}/mbedtls" clean >/dev/null 2>&1 || true
  rm -f "${SRC}"/*.o "${SRC}"/hactool \
        "${SRC}/mbedtls/library/"*.o "${SRC}/mbedtls/library/"*.a
}

if [[ "${1:-}" == "--clean" ]]; then
  clean_src
fi

SLICES=()
for arch in ${ARCHS}; do
  clean_src
  echo "==> hactool ${arch}"
  make -C "${SRC}" CC="clang -arch ${arch}" -j"${JOBS}" >/dev/null
  file "${SRC}/hactool" | grep -q "${arch}" || { echo "error: ${arch} build did not produce a ${arch} binary" >&2; exit 1; }
  cp "${SRC}/hactool" "${TMP}/hactool-${arch}"
  SLICES+=("${TMP}/hactool-${arch}")
done

mkdir -p "${OUT_DIR}"
if [[ ${#SLICES[@]} -gt 1 ]]; then
  lipo -create "${SLICES[@]}" -output "${OUT_DIR}/hactool"
else
  cp "${SLICES[0]}" "${OUT_DIR}/hactool"
fi
cp "${SRC}/LICENSE" "${OUT_DIR}/LICENSE"
chmod +x "${OUT_DIR}/hactool"

echo "built ${OUT_DIR}/hactool ($(lipo -info "${OUT_DIR}/hactool" 2>/dev/null || file "${OUT_DIR}/hactool"); sha $(shasum "${OUT_DIR}/hactool" | cut -c1-12))"
