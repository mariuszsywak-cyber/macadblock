#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_ROOT/Build/Release/MacAdBlock.app}"
OUTPUT_DIR="${2:-$PROJECT_ROOT/Build/Installer}"
PACKAGE_URL="${MACADBLOCK_PACKAGE_URL:-https://example.com/downloads/MacAdBlock.pkg}"

if [[ ! -d "$APP_PATH" ]]; then
  print -u2 "Nie znaleziono aplikacji: $APP_PATH"
  print -u2 "Użycie: $0 /ścieżka/MacAdBlock.app [katalog-wynikowy]"
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
PACKAGE_PATH="$OUTPUT_DIR/MacAdBlock-$VERSION-$BUILD.pkg"
MANIFEST_PATH="$OUTPUT_DIR/update-manifest.json"

mkdir -p "$OUTPUT_DIR"
arguments=(
  --component "$APP_PATH"
  --install-location /Applications
  --identifier com.italiano88.MacAdBlock.installer
  --version "$VERSION"
)

if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  arguments+=(--sign "$INSTALLER_SIGN_IDENTITY")
fi

/usr/bin/pkgbuild "${arguments[@]}" "$PACKAGE_PATH"
CHECKSUM=$(/usr/bin/shasum -a 256 "$PACKAGE_PATH" | /usr/bin/awk '{print $1}')

/bin/cat > "$MANIFEST_PATH" <<EOF
{
  "version": "$VERSION",
  "build": $BUILD,
  "packageURL": "$PACKAGE_URL",
  "sha256": "$CHECKSUM",
  "notes": "Nowa wersja MacAdBlock zawiera poprawki ochrony i interfejsu."
}
EOF

print "Utworzono: $PACKAGE_PATH"
print "Utworzono: $MANIFEST_PATH"
print "SHA-256:   $CHECKSUM"
