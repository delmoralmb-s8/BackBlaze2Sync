#!/bin/bash
# Builds a universal .dmg release and regenerates appcast.xml for Sparkle.
# Usage: scripts/release.sh <version>   (e.g. scripts/release.sh 1.1)
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi
VERSION="$1"

cd "$(dirname "$0")/.."

# ponytail: DerivedData's hash suffix changes per machine/Xcode version, so the Sparkle CLI
# tools (bundled as a prebuilt artifact of the SPM package) are located dynamically instead
# of hardcoding a path that would break the next time this runs.
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -print -quit)
if [ -z "$GENERATE_APPCAST" ]; then
    echo "Couldn't find generate_appcast. Build the project in Xcode at least once first (resolves the Sparkle package)." >&2
    exit 1
fi

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Building universal Release"
rm -rf dist/build
xcodebuild -project BackBlaze2Sync.xcodeproj -scheme BackBlaze2Sync -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath dist/build clean build

BUILT_APP="dist/build/Build/Products/Release/BackBlaze2Sync.app"
lipo -info "$BUILT_APP/Contents/MacOS/BackBlaze2Sync"

echo "==> Packaging .dmg"
STAGE=dist/stage
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BUILT_APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG_PATH="dist/BackBlaze2Sync-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "BackBlaze2Sync" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"

echo "==> Generating appcast.xml"
"$GENERATE_APPCAST" dist/
cp dist/appcast.xml ./appcast.xml

echo ""
echo "Done. Next steps:"
echo "  1. git add appcast.xml && git commit -m 'Release $VERSION' && git push"
echo "  2. gh release create v$VERSION '$DMG_PATH' --title 'BackBlaze2Sync $VERSION'"
