#!/usr/bin/env bash
#
# Builds tools/nszunpack/nszunpack — the NSZ → NSP converter bundled with
# SwitchMTP Batch.
#
# It needs two crypto/decompression libraries and both are already in the tree
# or in the Homebrew prefix:
#
#   * mbedtls (AES-XTS) — vendored under third_party/hactool/mbedtls, built
#     static here so the tool has no runtime dependency on it;
#   * zstd — Homebrew's static libzstd (BSD-3). Listed in THIRD_PARTY.md.
#
# The resulting binary is arm64-only, because the Homebrew library it links is
# arm64-only. The app itself is arm64-only for the same reason.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/tools/nszunpack/nszunpack.c"
OUT="${ROOT}/tools/nszunpack/nszunpack"
MBEDTLS="${ROOT}/third_party/hactool/mbedtls"
ZSTD_PREFIX="${ZSTD_PREFIX:-/opt/homebrew}"
ARCHS="${ARCHS:-arm64}"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f "${SRC}" ]] || die "source missing: ${SRC}"
[[ -f "${ZSTD_PREFIX}/include/zstd.h" ]] || die "zstd headers not found under ${ZSTD_PREFIX}"
[[ -f "${ZSTD_PREFIX}/lib/libzstd.a" ]] || die "static libzstd not found under ${ZSTD_PREFIX}"

if [[ ! -f "${MBEDTLS}/library/libmbedcrypto.a" ]]; then
  info "building vendored mbedtls (libmbedcrypto)"
  make -C "${MBEDTLS}/library" -j"$(sysctl -n hw.ncpu)" >/dev/null
fi

FLAGS=(-O2 -std=c99 -Wall -Wextra -Wno-unused-parameter
       -I "${MBEDTLS}/include" -I "${ZSTD_PREFIX}/include")
for arch in ${ARCHS}; do FLAGS+=(-arch "${arch}"); done

info "compiling ${SRC##*/}"
clang "${FLAGS[@]}" "${SRC}" \
  "${ZSTD_PREFIX}/lib/libzstd.a" "${MBEDTLS}/library/libmbedcrypto.a" \
  -o "${OUT}"

info "built ${OUT}"
"${OUT}" 2>&1 | head -3 || true
