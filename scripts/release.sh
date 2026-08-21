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

echo "==> Generating appcast.xml with release notes"
"$GENERATE_APPCAST" dist/
cp dist/appcast.xml ./appcast.xml

# generate_appcast doesn't know about our release notes text, so this fills in the
# <description> of the item it just created for this version (matched by sparkle:version).
python3 - "$VERSION" "$BUILD" "$NOTES_FILE" <<'PYEOF'
import sys, re
version, build, notes_file = sys.argv[1], sys.argv[2], sys.argv[3]
with open(notes_file, encoding="utf-8") as f:
    notes = f.read().strip()
with open("appcast.xml", encoding="utf-8") as f:
    xml = f.read()

pattern = re.compile(
    r'(<item>(?:(?!</item>).)*?sparkle:version="' + re.escape(build) +
    r'"(?:(?!</item>).)*?)(</item>)',
    re.DOTALL,
)
description = f'\n            <description><![CDATA[{notes}]]></description>'
new_xml, count = pattern.subn(lambda m: m.group(1) + description + m.group(2), xml, count=1)
if count == 0:
    print(f"WARNING: could not find the appcast item for build {build} to insert release notes.", file=sys.stderr)
else:
    with open("appcast.xml", "w", encoding="utf-8") as f:
        f.write(new_xml)
PYEOF

echo "==> Publishing"
git add project.yml appcast.xml
git commit -m "Release $VERSION ($BUILD)"
git push
gh release create "v$VERSION" "$DMG_PATH" --title "BackBlaze2Sync $VERSION" --notes-file "$NOTES_FILE"

echo ""
echo "Done. v$VERSION is live: existing installs will see it next time they check for updates."
