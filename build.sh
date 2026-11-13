#!/bin/zsh
# Builds QuickAsk.app from the Swift sources.
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
# across rebuilds. The first build creates it if it's missing.
SIGN_ID="QuickAsk Local Signing"
APP="build/$APP_NAME.app"

check_tools() {
  if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    echo "✗ Apple's Command Line Tools aren't installed. Run this, then try again:"
    echo "    xcode-select --install"
    exit 1
  fi
}

# Creates the "QuickAsk Local Signing" certificate in your login keychain, once.
# It's self-signed and only used to sign the QuickAsk you build on this Mac.
# It never needs to be trusted system-wide, so no password is asked for here.
ensure_certificate() {
  security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 && return
  echo "→ Creating the '$SIGN_ID' certificate in your login keychain (one time only)"
  local tmp; tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" EXIT
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -subj "/CN=$SIGN_ID" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # A throwaway password: the .p12 file only exists for the import and is deleted after.
  local pass; pass=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$SIGN_ID" -out "$tmp/id.p12" -passout "pass:$pass"
  # -T lets codesign use the key without asking each time.
  security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$pass" -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"; trap - EXIT
  echo "  If macOS asks whether codesign may use the key, click \"Always Allow\"."
}

build() {
  check_tools
  ensure_certificate
  echo "→ Assembling $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp Resources/Info.plist "$APP/Contents/"
  cp -R Resources/Duck "$APP/Contents/Resources/"   # the duck's animation frames

  # We call the Swift compiler directly instead of `swift build` (SwiftPM): there are
  # no packages to fetch. It builds for this Mac's chip (Apple Silicon or Intel).
  echo "→ Compiling (optimised)…"
  swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -module-name "$APP_NAME" \
    Sources/QuickAsk/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

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
