#!/bin/zsh
# Builds QuickAsk.app from the Swift package.
#
#   ./build.sh                    build ./build/QuickAsk.app
#   ./build.sh install            build, copy to /Applications, (re)launch it
#   ./build.sh reset-permissions  forget Screen Recording + Accessibility grants
#
# No Xcode needed: swiftc compiles the code, then this script assembles
# the .app folder structure by hand and signs it.
set -euo pipefail
cd "${0:A:h}"   # run from the project folder, whatever the current directory

APP_NAME="QuickAsk"
BUNDLE_ID="com.guillem.quickask"
# A self-signed certificate in your login keychain. Signing every build with the
# SAME identity is what lets macOS remember permissions (and Keychain access)
# across rebuilds. If it's missing we fall back to ad-hoc signing ("-").
SIGN_ID="QuickAsk Local Signing"
APP="build/$APP_NAME.app"

build() {
  echo "→ Assembling $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp Resources/Info.plist "$APP/Contents/"

  # We call the Swift compiler directly instead of `swift build` (SwiftPM): there are
  # no packages to fetch, and it works with older Command Line Tools too.
  echo "→ Compiling (optimised)…"
  swiftc -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    -module-name "$APP_NAME" \
    Sources/QuickAsk/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

  # Stop rather than fall back to ad-hoc signing: an ad-hoc build would make macOS
  # re-ask for permissions and the Keychain password on every rebuild.
  if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "✗ Signing certificate '$SIGN_ID' not found in your login keychain."
    echo "  See README.md → Troubleshooting → 'Signing certificate missing'."
    exit 1
  fi
  echo "→ Signing with '$SIGN_ID'"
  # --options runtime = "hardened runtime": stops other programs from injecting code
  # into QuickAsk and borrowing its permissions (Screen Recording, Accessibility, Keychain).
  codesign --force --options runtime --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
  echo "✓ Built $APP"
}

case "${1:-build}" in
  build)
    build ;;
  install)
    build
    echo "→ Installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "✓ QuickAsk is running. Look for its icon in the menu bar." ;;
  reset-permissions)
    tccutil reset ScreenCapture "$BUNDLE_ID" || true
    tccutil reset Accessibility "$BUNDLE_ID" || true
    echo "✓ Permissions reset. QuickAsk will ask again next time it needs them." ;;
  *)
    echo "Usage: ./build.sh [build|install|reset-permissions]"; exit 1 ;;
esac
