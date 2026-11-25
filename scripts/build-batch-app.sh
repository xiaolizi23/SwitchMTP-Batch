#!/usr/bin/env bash
#
# Builds SwitchMTP Batch.app on machines that have only the Xcode Command Line
# Tools (no Xcode, no xcodebuild, no xcodegen).
#
# The upstream project builds with `xcodebuild` + an XcodeGen spec. That is
# unavailable here, so this script drives the same sources with `swiftc`
# directly and assembles the bundle by hand. Everything it does mirrors
# scripts/build-app.sh: universal Go backend, embedded dylibs, ad-hoc signing.
#
# One Command Line Tools defect is worked around: CLT 16.x ships two module
# maps that both declare `SwiftBridging`, which makes `swiftc` fail before
# compiling a single line. A private resource directory is created whose
# `include/swift` contains only one of them, and `-resource-dir` points there.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SRC="${ROOT}/app/SwitchMTP"
SHIM_DIR="${ROOT}/app/Shim"
BUILD="${ROOT}/build"
PRODUCTS="${BUILD}/products"
APP="${PRODUCTS}/SwitchMTP Batch.app"
MACOS_DIR="${APP}/Contents/MacOS"
FRAMEWORKS="${APP}/Contents/Frameworks"
RESOURCES="${APP}/Contents/Resources"
BINARY="${MACOS_DIR}/SwitchMTPBatch"

VERSION="${VERSION:-1.7.3}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-me.fratei.switchmtp.batch}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
ARCHS="${ARCHS:-arm64}"

info() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v swiftc >/dev/null || die "swiftc not found"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# ---------------------------------------------------------------- Swift overlay
prepare_swift_resource_dir() {
  local dir="${BUILD}/swift-resource"
  rm -rf "${dir}"
  mkdir -p "${dir}/include/swift"
  local clt="/Library/Developer/CommandLineTools"
  cp "${clt}/usr/include/swift/bridging" "${dir}/include/swift/" 2>/dev/null \
    || cp -R "${clt}/usr/include/swift/bridging" "${dir}/include/swift/bridging"
  cp "${clt}/usr/include/swift/bridging.modulemap" "${dir}/include/swift/"
  # Only the module map that Swift actually needs, deliberately omitting the
  # duplicate `module.modulemap`.
  ln -sfn "${clt}/usr/lib" "${dir}/lib"
  if [[ -d "${clt}/usr/lib/clang/16" ]]; then
    ln -sfn "${clt}/usr/lib/clang/16" "${dir}/clang"
  fi
  # The linker resolves the back-deployment libraries (swiftCompatibility56 and
  # friends) relative to `<resource-dir>/macosx`, not `<resource-dir>/lib`.
  ln -sfn "${clt}/usr/lib/swift/macosx" "${dir}/macosx"
  info "Swift resource overlay ready: ${dir}"
}

# ---------------------------------------------------------------- Backend
build_backend() {
  if [[ -f "${ROOT}/backend/build/nxmtp.dylib" && -f "${ROOT}/backend/build/nxmtp.h" ]]; then
    info "Backend already built"
    return
  fi
  info "Building Go backend + libusb (universal)"
  "${ROOT}/scripts/build-backend.sh"
}

# ---------------------------------------------------------------- Compile
build_binary() {
  info "Compiling C shim"
  local shim_obj="${BUILD}/NxmtpShim.o"
  clang -c "${SHIM_DIR}/NxmtpShim.c" -o "${shim_obj}" \
    -I "${SHIM_DIR}" -I "${ROOT}/backend/build" \
    -mmacosx-version-min="${DEPLOYMENT_TARGET}" \
    -arch "${ARCHS%% *}"

  mkdir -p "$(dirname "${BINARY}")"
  info "Compiling Swift (${ARCHS})"
  # swiftc takes -target, not -arch; one architecture per invocation. A
  # universal build would need a second pass and lipo, which is only worth it
  # when shipping to Intel Macs as well.
  local first_arch="${ARCHS%% *}"

  local sources=()
  while IFS= read -r -d '' file; do sources+=("${file}"); done \
    < <(find "${APP_SRC}" -name '*.swift' -not -path '*/.*' -print0)

  swiftc \
    -O -swift-version 5 -parse-as-library \
    -target "${first_arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -sdk "${SDK}" \
    -resource-dir "${BUILD}/swift-resource" \
    -module-name SwitchMTPBatch \
    -import-objc-header "${APP_SRC}/SwitchMTP-Bridging-Header.h" \
    -I "${SHIM_DIR}" -I "${ROOT}/backend/build" \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    "${ROOT}/backend/build/nxmtp.dylib" \
    "${ROOT}/third_party/libusb/lib/libusb-1.0.0.dylib" \
    -framework IOKit -framework UniformTypeIdentifiers \
    "${sources[@]}" "${shim_obj}" \
    -o "${BUILD}/SwitchMTPBatch"
}

# ---------------------------------------------------------------- Bundle
assemble_bundle() {
  info "Assembling app bundle"
  rm -rf "${APP}"
  mkdir -p "${MACOS_DIR}" "${FRAMEWORKS}" "${RESOURCES}/bin"
  # The linker writes outside the bundle: assemble_bundle wipes the bundle first.
  cp "${BUILD}/SwitchMTPBatch" "${BINARY}"

  cp "${ROOT}/backend/build/nxmtp.dylib" "${FRAMEWORKS}/nxmtp.dylib"
  cp "${ROOT}/third_party/libusb/lib/libusb-1.0.0.dylib" "${FRAMEWORKS}/libusb-1.0.0.dylib"
  chmod u+w "${BINARY}" "${FRAMEWORKS}/nxmtp.dylib" "${FRAMEWORKS}/libusb-1.0.0.dylib"

  install_name_tool -id "@rpath/nxmtp.dylib" "${FRAMEWORKS}/nxmtp.dylib"
  install_name_tool -id "@rpath/libusb-1.0.0.dylib" "${FRAMEWORKS}/libusb-1.0.0.dylib"
  if otool -L "${FRAMEWORKS}/nxmtp.dylib" | grep -q "@rpath/libusb-1.0.0.dylib"; then
    install_name_tool -change "@rpath/libusb-1.0.0.dylib" "@loader_path/libusb-1.0.0.dylib" "${FRAMEWORKS}/nxmtp.dylib"
  fi
  # The Swift binary linked against absolute paths in the build tree; repoint
  # everything at the bundle-relative location.
  for dylib in nxmtp libusb-1.0.0; do
    if otool -L "${BINARY}" | grep -q "${ROOT}/backend/build/${dylib}.dylib"; then
      install_name_tool -change "${ROOT}/backend/build/${dylib}.dylib" "@rpath/${dylib}.dylib" "${BINARY}"
    fi
    if otool -L "${BINARY}" | grep -q "${ROOT}/third_party/libusb/lib/${dylib}.dylib"; then
      install_name_tool -change "${ROOT}/third_party/libusb/lib/${dylib}.dylib" "@rpath/${dylib}.dylib" "${BINARY}"
    fi
  done

  # Verification engine. ISC licensed; the licence is bundled beside it.
  if [[ -x "${ROOT}/tools/hactool/hactool" ]]; then
    cp "${ROOT}/tools/hactool/hactool" "${RESOURCES}/bin/hactool"
    cp "${ROOT}/tools/hactool/LICENSE" "${RESOURCES}/bin/hactool-LICENSE.txt"
    chmod +x "${RESOURCES}/bin/hactool"
  else
    info "WARNING: tools/hactool/hactool missing; deep checks will report 'engine unavailable'"
  fi

  # NSZ unpacker. Links Homebrew's static zstd and the vendored mbedtls;
  # arm64-only, same as the rest of the bundle.
  if [[ -x "${ROOT}/tools/nszunpack/nszunpack" ]]; then
    cp "${ROOT}/tools/nszunpack/nszunpack" "${RESOURCES}/bin/nszunpack"
    chmod +x "${RESOURCES}/bin/nszunpack"
    cp /opt/homebrew/opt/zstd/LICENSE "${RESOURCES}/bin/nszunpack-LICENSE.txt" 2>/dev/null || true
  else
    info "WARNING: tools/nszunpack/nszunpack missing; run scripts/build-nszunpack.sh (NSZ deep checks will be unavailable)"
  fi

  compile_localizations

  cp "${ROOT}/app/Resources/Credits.html" "${RESOURCES}/Credits.html" 2>/dev/null || true
  cp "${ROOT}/THIRD_PARTY.md" "${RESOURCES}/THIRD_PARTY.md" 2>/dev/null || true
  cp "${ROOT}/LICENSE" "${RESOURCES}/LICENSE.txt" 2>/dev/null || true

  build_icon

  cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SwitchMTP Batch</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>ja</string>
        <string>es</string>
        <string>ru</string>
    </array>
    <key>CFBundleDisplayName</key><string>SwitchMTP Batch</string>
    <key>CFBundleExecutable</key><string>SwitchMTPBatch</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2024 Neighbor_Z. Copyright © 2025 fratei. GPL-2.0. Batch workspace added 2026.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

  # Ad-hoc signature: no Developer ID here, and the app is distributed as source
  # plus a locally built bundle. Deep signing keeps the nested dylibs and the
  # helper binary valid after install_name_tool edits them.
  codesign --force --deep --sign - --timestamp=none "${APP}" >/dev/null 2>&1 || \
    info "WARNING: codesign failed; the bundle may need xattr -dr com.apple.quarantine before launch"

  info "Verifying bundle"
  otool -L "${BINARY}" | sed -n '2,8p'
  lipo -info "${BINARY}"
  "${RESOURCES}/bin/hactool" 2>&1 | head -2 || true
}

# Xcode compiles the String Catalog into <lang>.lproj/Localizable.strings as part
# of the build. swiftc does not, and a bundle with no localisations falls back
# to the English source keys no matter what the system language is.
compile_localizations() {
  local catalog="${ROOT}/app/Resources/Localizable.xcstrings"
  [[ -f "${catalog}" ]] || return 0
  local tool
  tool="$(xcrun --find xcstringstool 2>/dev/null || true)"
  if [[ -z "${tool}" ]]; then
    info "WARNING: xcstringstool not found; the UI will stay in English"
    return 0
  fi
  "${tool}" compile "${catalog}" --output-directory "${RESOURCES}" >/dev/null
  info "Compiled localisations: $(ls -d "${RESOURCES}"/*.lproj 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
}

build_icon() {
  local iconset="${BUILD}/AppIcon.iconset"
  local src="${ROOT}/app/Resources/Assets.xcassets/AppIcon.appiconset"
  [[ -f "${src}/icon_512x512@2x.png" ]] || return 0
  rm -rf "${iconset}"; mkdir -p "${iconset}"
  for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${src}/icon_${size}x${size}.png" \
      --out "${iconset}/icon_${size}x${size}.png" >/dev/null 2>&1 || true
    sips -z $((size * 2)) $((size * 2)) "${src}/icon_${size}x${size}@2x.png" \
      --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "${iconset}" -o "${RESOURCES}/AppIcon.icns" >/dev/null 2>&1 || \
    info "WARNING: iconutil failed; bundle will use the default icon"
}

# ---------------------------------------------------------------- Main
prepare_swift_resource_dir
build_backend
mkdir -p "${BUILD}"
build_binary
assemble_bundle

info "Built ${APP}"
du -sh "${APP}"
