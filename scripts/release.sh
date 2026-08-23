#!/bin/bash
# Full release automation: bumps the version, builds a universal .dmg, signs it and
# regenerates appcast.xml with release notes, then publishes (git push + GitHub Release).
# Usage: scripts/release.sh <version> <build> <notes-file>
#   e.g. scripts/release.sh 1.1 2 /tmp/notes.md
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 <version> <build> <notes-file>" >&2
    echo "  e.g. $0 1.1 2 /tmp/notes.md" >&2
    exit 1
fi
VERSION="$1"
BUILD="$2"
NOTES_FILE="$3"

if [ ! -f "$NOTES_FILE" ]; then
    echo "Notes file not found: $NOTES_FILE" >&2
    exit 1
fi

cd "$(dirname "$0")/.."

# ponytail: DerivedData's hash suffix changes per machine/Xcode version, so the Sparkle CLI
# tools (bundled as a prebuilt artifact of the SPM package) are located dynamically instead
# of hardcoding a path that would break the next time this runs.
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -print -quit)
if [ -z "$GENERATE_APPCAST" ]; then
    echo "Couldn't find generate_appcast. Build the project in Xcode at least once first (resolves the Sparkle package)." >&2
    exit 1
fi

echo "==> Bumping version to $VERSION ($BUILD) in project.yml"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

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

# generate_appcast rejects a folder containing more than one archive for the same bundle
# version (real error hit on the very first real release: leftover 1.0 dmgs sitting in dist/
# from a previous run tripped "Duplicate updates are not supported"). Anything not matching
# THIS version gets moved out of the way instead of deleted.
echo "==> Archiving older .dmg files out of dist/"
mkdir -p dist/archive
find dist -maxdepth 1 -name "BackBlaze2Sync-*.dmg" ! -name "BackBlaze2Sync-$VERSION.dmg" -exec mv {} dist/archive/ \;

echo "==> Generating appcast.xml with release notes"
# --download-url-prefix is required: without it generate_appcast guesses a URL from the
# existing appcast's own <link> (wrong, that's the feed's URL, not where the .dmg lives).
"$GENERATE_APPCAST" --download-url-prefix "https://github.com/delmoralmb-s8/BackBlaze2Sync/releases/download/v$VERSION/" dist/
cp dist/appcast.xml ./appcast.xml

# generate_appcast doesn't know about our release notes text, so this fills in the
# <description> right after <sparkle:minimumSystemVersion>, which generate_appcast always
# emits. sparkle:version is an ELEMENT here (<sparkle:version>2</sparkle:version>), not an
# attribute, a first attempt at this regex assumed the latter and silently matched nothing.
python3 - "$NOTES_FILE" <<'PYEOF'
import sys
notes_file = sys.argv[1]
with open(notes_file, encoding="utf-8") as f:
    notes = f.read().strip()
with open("appcast.xml", encoding="utf-8") as f:
    xml = f.read()
marker = "</sparkle:minimumSystemVersion>"
description = f'{marker}\n            <description><![CDATA[{notes}]]></description>'
if marker not in xml:
    print("WARNING: could not find the appcast item to insert release notes.", file=sys.stderr)
else:
    xml = xml.replace(marker, description, 1)
    with open("appcast.xml", "w", encoding="utf-8") as f:
        f.write(xml)
PYEOF
cp appcast.xml dist/appcast.xml

echo "==> Publishing"
git add project.yml appcast.xml
git commit -m "Release $VERSION ($BUILD)"
git push
gh release create "v$VERSION" "$DMG_PATH" --title "BackBlaze2Sync $VERSION" --notes-file "$NOTES_FILE"

echo ""
echo "Done. v$VERSION is live: existing installs will see it next time they check for updates."
