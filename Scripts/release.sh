#!/bin/zsh
set -euo pipefail

# Buduje aplikację, pakuje ją w .pkg + manifest aktualizacji i publikuje jako
# GitHub Release jedną komendą. Wymaga zainstalowanego i zalogowanego `gh`
# (GitHub CLI): brew install gh && gh auth login
#
# Użycie:
#   Scripts/release.sh [Debug|Release]
#
# Domyślnie buduje konfigurację Debug (nie wymaga nowych App ID od Apple —
# certyfikaty już zarejestrowane z codziennego uruchamiania w Xcode).
# Użyj "Release" gdy tygodniowy limit App ID się odnowi albo przejdziesz
# na płatne konto Apple Developer.

CONFIGURATION="${1:-Debug}"
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"

REPO="mariuszsywak-cyber/macadblock"
DERIVED_DATA="Build/DerivedData-$CONFIGURATION"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MacAdBlock.app"

if ! command -v gh >/dev/null 2>&1; then
  echo "Brak GitHub CLI. Zainstaluj: brew install gh    (potem: gh auth login)" >&2
  exit 1
fi

echo "==> Buduję konfigurację $CONFIGURATION..."
xcodebuild -project MacAdBlock.xcodeproj -scheme MacAdBlock \
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Nie znaleziono zbudowanej aplikacji: $APP_PATH" >&2
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
TAG="v$VERSION.$BUILD"
PKG_NAME="MacAdBlock-$VERSION-$BUILD.pkg"

echo "==> Wersja: $VERSION (build $BUILD) -> tag $TAG"

export MACADBLOCK_PACKAGE_URL="https://github.com/$REPO/releases/latest/download/$PKG_NAME"
echo "==> Buduję paczkę instalacyjną..."
Scripts/build-installer.sh "$APP_PATH"

echo "==> Publikuję release $TAG na GitHubie..."
gh release create "$TAG" \
  "Build/Installer/$PKG_NAME" \
  "Build/Installer/update-manifest.json" \
  --repo "$REPO" \
  --title "$TAG" \
  --notes "Automatyczny release ($CONFIGURATION, build $BUILD)."

echo "==> Gotowe: https://github.com/$REPO/releases/tag/$TAG"
