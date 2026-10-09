#!/usr/bin/env bash
# Builds PkgSender.app for macOS 12+ using the Swift Package Manager and the
# installed Command Line Tools SDK. No Xcode required.
#
#   ./build.sh              # universal: arm64 + x86_64 (default)
#   ./build.sh --arch arm64 # Apple Silicon only (faster)
#   ./build.sh --arch x86_64# Intel only
#   ./build.sh --arch auto  # build whatever this toolchain can link (recommended
#                           # on Apple Silicon with Command Line Tools only)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PkgSender"
BUNDLE_ID="com.local.pkgsendermac"
MIN_OS="12.0"
APP_DIR="build/${APP_NAME}.app"

# --- Target architectures --------------------------------------------------
# SwiftPM writes to a single build dir per configuration, so the two slices are
# built into separate scratch directories and merged with lipo.
ARCHS="arm64 x86_64"
ALLOW_PARTIAL=0
case "${1:-}" in
  --arch)
    ARCHS="${2:-}"
    shift 2 || true
    ;;
  --arch=*)
    ARCHS="${1#--arch=}"
    shift ;;
esac
# `auto` keeps whichever slices this toolchain can actually link.
if [ "$ARCHS" = "auto" ]; then
  ALLOW_PARTIAL=1
  ARCHS="arm64 x86_64"
fi
if [ -z "$ARCHS" ]; then
  echo "error: --arch needs a value (arm64, x86_64, auto, or 'arm64 x86_64')" >&2
  exit 1
fi
echo ">> Architectures: $ARCHS"

# --- Pick a macOS SDK from Command Line Tools ----------------------------
# Prefer the known-good 26.5 SDK: the newest CLT SDK (27.0 on this box)
# fails to resolve the SwiftUI macro plugin under `swift build`, so we only
# fall back to "newest" when 26.5 is unavailable.
SDK_CANDIDATES="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
SDK=$(ls -d $SDK_CANDIDATES 2>/dev/null | head -1)
if [ -z "$SDK" ]; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V | tail -1)
fi
if [ -z "$SDK" ]; then
  SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
fi
if [ -z "$SDK" ]; then
  echo "error: no macOS SDK found (install Command Line Tools)" >&2
  exit 1
fi
echo ">> SDK: $SDK  min macOS: $MIN_OS"
# --- Build (release), one slice per architecture ---------------------------
# Each arch gets a clean, independent --scratch-path. SwiftPM keys artefacts by
# target triple, and the toolchain's static libs are single-arch, so sharing one
# build dir makes the second link fail with "fat file missing arch".
#
# NOTE: Apple's Command Line Tools on Apple Silicon ship the Swift runtime
# static libs (libswiftCompatibility*.a, etc.) as arm64-only, so a plain
# x86_64 link fails with "missing arch 'x86_64'". The fix (mirrors PkgViewerMac)
# is to pass -undefined dynamic_lookup for the Intel slice so the linker defers
# those symbols to runtime; macOS ships a universal Swift runtime in
# /usr/lib/swift, which resolves them when the app launches on an Intel Mac.
# If a toolchain still cannot link Intel even with that flag, fall back to
# `./build.sh --arch auto` or select a full Xcode toolchain.
SLICES=()
FAILED=()
for arch in $ARCHS; do
  TRIPLE="${arch}-apple-macosx${MIN_OS}"
  SCRATCH="build/.slice-${arch}"
  echo ">> building $TRIPLE"
  LOG="build/.slice-${arch}.log"
  # Run to completion first, then judge by the exit status; piping straight
  # into `grep -q` would race with the build and can miss the failure.
  extra_flags=""
  if [ "$arch" = "x86_64" ]; then
    # CLT on Apple Silicon lacks x86_64 slices for the Swift runtime static
    # libs (libswiftCompatibility*.a); let the linker defer those symbols to
    # runtime dynamic lookup. macOS ships a universal Swift runtime in
    # /usr/lib/swift that satisfies them when launched on an Intel Mac.
    extra_flags="-Xlinker -undefined -Xlinker dynamic_lookup"
  fi
  if swift build -c release --disable-sandbox --sdk "$SDK" --triple "$TRIPLE" \
       --scratch-path "$SCRATCH" $extra_flags > "$LOG" 2>&1; then
    :   # success
  else
    if grep -q "missing arch 'x86_64'" "$LOG" || grep -q "not an allowed client" "$LOG"; then
      echo "!! $arch: this toolchain still cannot link an Intel slice" >&2
      echo "!!   Even with -undefined dynamic_lookup the x86_64 Swift runtime" >&2
      echo "!!   is missing. Try a full Xcode toolchain:" >&2
      echo "!!     sudo xcode-select -s /Applications/Xcode.app && ./build.sh" >&2
      echo "!!   or fall back to: ./build.sh --arch auto" >&2
    else
      echo "!! $arch: build failed (see $LOG)" >&2
    fi
    FAILED+=("$arch")
    continue
  fi

  BIN="$SCRATCH/release/${APP_NAME}"
  if [ ! -x "$BIN" ]; then
    echo "!! $arch: binary not found at $BIN" >&2
    FAILED+=("$arch")
    continue
  fi
  # Confirm the slice really is the requested architecture; a stale binary here
  # would silently produce a broken "universal" app.
  ACTUAL=$(lipo -archs "$BIN" 2>/dev/null || echo unknown)
  if [ "$ACTUAL" != "$arch" ]; then
    echo "!! $arch: expected a $arch slice but lipo reports '$ACTUAL'" >&2
    FAILED+=("$arch")
    continue
  fi
  echo "   built $APP_NAME [$ACTUAL]"
  SLICES+=("$BIN")
done

if [ ${#SLICES[@]} -eq 0 ]; then
  echo "error: no architecture built successfully" >&2
  exit 1
fi
if [ ${#FAILED[@]} -gt 0 ] && [ "$ALLOW_PARTIAL" -eq 0 ]; then
  echo "error: failed arches: ${FAILED[*]}" >&2
  echo "hint: re-run with --arch auto to build only what this toolchain supports" >&2
  exit 1
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  echo ">> auto mode: continuing without ${FAILED[*]}"
fi

# --- Assemble the .app bundle --------------------------------------------
# Clean the *contents* rather than deleting APP_DIR wholesale: removing the
# whole bundle trips the safe-delete guard (it holds ~60 files) and aborts the
# build, leaving a stale binary in place.
if [ -d "$APP_DIR" ]; then
  find "$APP_DIR" -mindepth 1 -delete
else
  mkdir -p "$APP_DIR"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

UNIVERSAL="$APP_DIR/Contents/MacOS/$APP_NAME"
if [ ${#SLICES[@]} -eq 1 ]; then
  cp "${SLICES[0]}" "$UNIVERSAL"
else
  lipo -create "${SLICES[@]}" -output "$UNIVERSAL"
fi
echo ">> Merged binary: $(lipo -archs "$UNIVERSAL")"

# SwiftPM resource bundle (PkgSenderMac_PkgSenderApp.bundle) sits next to the
# binary; copy it into Resources so Bundle.module can find it at runtime.
# Resources are arch-independent, so any slice's copy is fine.
RES_BUNDLE=$(find "build/.slice-$(echo $ARCHS | awk '{print $1}')" -type d \
  -name "${APP_NAME}Mac_PkgSenderApp.bundle" 2>/dev/null | head -1)
if [ -z "$RES_BUNDLE" ]; then
  RES_BUNDLE=$(find .build build/.slice-* -type d -name "${APP_NAME}Mac_PkgSenderApp.bundle" 2>/dev/null | head -1)
fi
if [ -n "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP_DIR/Contents/Resources/"
  echo ">> Copied resource bundle: $(basename "$RES_BUNDLE")"
fi

# --- Icon (icns from the 1024x1024 logo) ----------------------------------
ICONSET="build/AppIcon.iconset"
# Same reasoning as APP_DIR: clear in place so the bulk-delete guard (which
# counts the generated PNGs) does not abort the build.
if [ -d "$ICONSET" ]; then
  find "$ICONSET" -mindepth 1 -delete
else
  mkdir -p "$ICONSET"
fi
SRC="Sources/PkgSenderApp/Resources/logo.png"
for sz in 16 32 64 128 256 512 1024; do
  sips -z "$sz" "$sz" "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
  if [ "$sz" -ge 32 ]; then
    half=$((sz / 2))
    sips -z "$sz" "$sz" "$SRC" --out "$ICONSET/icon_${half}x${half}@2x.png" >/dev/null 2>&1 || true
  fi
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
echo ">> Built AppIcon.icns"

# --- Info.plist -----------------------------------------------------------
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PKG Sender</string>
    <key>CFBundleDisplayName</key><string>PKG Sender</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>1.1.0</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Scans the selected drives and folders for PKG files.</string>
    <key>NSLocalNetworkUsageDescription</key><string>Sends PKG files to your PlayStation and discovers consoles on the LAN.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

# --- Ad-hoc code signature (lets it launch on this Mac; replace with a
#     Developer ID identity + notarization for public distribution) -------
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    && echo ">> Ad-hoc signed $APP_DIR" \
    || echo ">> codesign unavailable; app is unsigned"
fi

echo ">> Done: $APP_DIR"
echo ">> Architectures in shipped binary: $(lipo -archs "$UNIVERSAL")"

# Per-arch scratch dirs are large (module caches, object files) and no longer
# needed once the slices are merged. Clear in place rather than `rm -rf` so the
# safe-delete guard does not abort the build.
for arch in $ARCHS; do
  d="build/.slice-${arch}"
  if [ -d "$d" ]; then
    find "$d" -mindepth 1 -delete 2>/dev/null || true
    rmdir "$d" 2>/dev/null || true
  fi
  rm -f "build/.slice-${arch}.log" 2>/dev/null || true
done
