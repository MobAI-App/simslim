#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
APP_PATH="$BUILD_DIR/SimSlim.app"
ICON_SOURCE="$ROOT_DIR/gui/Assets/AppIcon.png"
MACHINE_ARCH="$(uname -m)"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always --dirty)}"
APP_VERSION="${VERSION#v}"
APP_VERSION="${APP_VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if ! print -r -- "$APP_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
  APP_VERSION="0.0.0"
fi
if ! print -r -- "$BUILD_NUMBER" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$'; then
  echo "BUILD_NUMBER must contain one to three dot-separated integers." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The SimSlim app can only be built on macOS." >&2
  exit 1
fi

if ! command -v go >/dev/null 2>&1; then
  echo "Go is required. Install it with: brew install go" >&2
  exit 1
fi

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "App icon source is missing: $ICON_SOURCE" >&2
  exit 1
fi

case "$MACHINE_ARCH" in
  arm64) GO_ARCH="arm64" ;;
  x86_64) GO_ARCH="amd64" ;;
  *)
    echo "Unsupported Mac architecture: $MACHINE_ARCH" >&2
    exit 1
    ;;
esac

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/simslim-app.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/SimSlim.app"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$ROOT_DIR/gui/Info.plist" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"

echo "Building macOS app icon…"
ICONSET_DIR="$STAGING_DIR/SimSlim.iconset"
mkdir -p "$ICONSET_DIR"
ICON_VARIANTS=(
  "16 icon_16x16.png"
  "32 icon_16x16@2x.png"
  "32 icon_32x32.png"
  "64 icon_32x32@2x.png"
  "128 icon_128x128.png"
  "256 icon_128x128@2x.png"
  "256 icon_256x256.png"
  "512 icon_256x256@2x.png"
  "512 icon_512x512.png"
  "1024 icon_512x512@2x.png"
)
for variant in "${ICON_VARIANTS[@]}"; do
  size="${variant%% *}"
  filename="${variant#* }"
  sips -s format png -z "$size" "$size" "$ICON_SOURCE" \
    --out "$ICONSET_DIR/$filename" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$STAGED_APP/Contents/Resources/SimSlim.icns"

echo "Building bundled simslim CLI ($MACHINE_ARCH)…"
(
  cd "$ROOT_DIR"
  CGO_ENABLED=0 GOOS=darwin GOARCH="$GO_ARCH" \
    go build -trimpath -ldflags "-s -w -X main.version=$VERSION" \
    -o "$STAGED_APP/Contents/Resources/simslim" ./cmd/simslim
)

echo "Building SwiftUI app ($MACHINE_ARCH)…"
xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -parse-as-library \
  -O \
  -target "$MACHINE_ARCH-apple-macos14.0" \
  -module-name SimSlimApp \
  -framework AppKit \
  -framework SwiftUI \
  "$ROOT_DIR/gui/Models.swift" \
  "$ROOT_DIR/gui/Backend.swift" \
  "$ROOT_DIR/gui/AppModel.swift" \
  "$ROOT_DIR/gui/SimulatorManagementViews.swift" \
  "$ROOT_DIR/gui/ContentView.swift" \
  "$ROOT_DIR/gui/SimSlimApp.swift" \
  -o "$STAGED_APP/Contents/MacOS/SimSlim"

chmod +x "$STAGED_APP/Contents/MacOS/SimSlim" "$STAGED_APP/Contents/Resources/simslim"
codesign --force --deep --sign - "$STAGED_APP" >/dev/null

mkdir -p "$BUILD_DIR"
if [[ -e "$APP_PATH" ]]; then
  rm -rf "$APP_PATH"
fi
mv "$STAGED_APP" "$APP_PATH"

echo "Built $APP_PATH"
