#!/bin/bash
# Builds an OFFICIAL Murmur release: the licensed build sold from murmurmac.com, signed with the Developer ID,
# notarized, updating through Sparkle. A build from source (scripts/make_app.sh) never asks for a license; this one
# does — it's the only thing that marks a build `release` (see BuildChannel in Sources/Murmur/License.swift).
#
#   scripts/make_release.sh <version> <build number>        e.g.  scripts/make_release.sh 2.2.0 5
#
# It checks everything it needs before building anything, and lists what's missing:
#   - a "Developer ID Application" signing identity (Apple Developer Program)
#   - notarization credentials, stored once:  xcrun notarytool store-credentials murmur-notary --apple-id … --team-id …
#   - Sparkle's command-line tools (bin/ from the Sparkle 2.x release archive on GitHub) in $SPARKLE_BIN
#   - Sparkle's EdDSA update key in this Mac's Keychain — made once with "$SPARKLE_BIN/generate_keys"; back it up,
#     because without it no installed copy can ever be sent another update
#   - the real license public key in Sources/Murmur/License.swift (node scripts/make-license-keys.js, website repo)
#
# Paid archives are published to a separate place from the source repo's GitHub releases, so the updater in free
# source builds (which watches janisbelozerovs-dev/murmur) never offers them a paid build.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
BUILD="${2:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 <version, like 2.2.0> <build number, like 5>" >&2
    exit 2
fi

FEED_URL="${MURMUR_FEED_URL:-https://www.murmurmac.com/updates/appcast.xml}"
# One place for every archive, so one prefix fits them all (generate_appcast writes one URL prefix for the feed).
DOWNLOAD_PREFIX="${MURMUR_DOWNLOAD_PREFIX:-https://github.com/janisbelozerovs-dev/murmur-releases/releases/download/updates/}"
# Every release archive ever made: generate_appcast builds the feed — and small delta updates — from all of them.
ARCHIVES="${MURMUR_ARCHIVES:-$HOME/Murmur Releases}"
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/Sparkle/bin}"
NOTARY_PROFILE="${MURMUR_NOTARY_PROFILE:-murmur-notary}"
DIST="dist"
APP="$DIST/Murmur.app"

# --- Preflight: everything missing, listed at once --------------------------------------------------------------
missing=()
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || missing+=("a 'Developer ID Application' signing identity (Apple Developer Program, \$99/year)")
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || missing+=("notarization credentials: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id <team>")
ED_KEY=""
if [ -x "$SPARKLE_BIN/generate_appcast" ] && [ -x "$SPARKLE_BIN/generate_keys" ]; then
    ED_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
    [ -n "$ED_KEY" ] || missing+=("Sparkle's update-signing key: run \"$SPARKLE_BIN/generate_keys\" once, then back it up")
else
    missing+=("Sparkle's tools in \$SPARKLE_BIN ($SPARKLE_BIN): bin/ from the Sparkle 2.x release archive")
fi
grep -q 'REPLACE_BEFORE_SHIPPING' Sources/Murmur/License.swift \
    && missing+=("the real license public key in Sources/Murmur/License.swift (productionPublicKey)")
if [ ${#missing[@]} -gt 0 ]; then
    echo "Can't make a release yet. Missing:" >&2
    for item in "${missing[@]}"; do echo "  - $item" >&2; done
    exit 1
fi

# --- Build, then mark it as a release ----------------------------------------------------------------------------
rm -rf "$DIST"
mkdir -p "$DIST"
MURMUR_APP_PATH="$APP" ./scripts/make_app.sh
PLIST="$APP/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
plist "Set :CFBundleShortVersionString $VERSION"
plist "Set :CFBundleVersion $BUILD"
plist "Set :NSHumanReadableCopyright Murmur $VERSION — dictation that never leaves your Mac."
plist "Add :MurmurBuildChannel string release"
plist "Add :MurmurReleaseDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)"
plist "Add :SUFeedURL string $FEED_URL"
plist "Add :SUPublicEDKey string $ED_KEY"
plist "Add :SUEnableAutomaticChecks bool true"

# --- Developer ID: inside-out, hardened runtime, secure timestamp -------------------------------------------------
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
M="$APP/Contents/MacOS"
if [ -d "$M/sherpa_onnx.framework" ]; then
    sign "$M/sherpa_onnx.framework/Versions/A/libonnxruntime.dylib"
    sign "$M/sherpa_onnx.framework"
fi
sign "$M/Sparkle.framework/Versions/B/Autoupdate"
sign "$M/Sparkle.framework/Versions/B/Updater.app"
sign "$M/Sparkle.framework"
sign --entitlements scripts/release.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# --- Notarize and staple the app ----------------------------------------------------------------------------------
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm "$DIST/notarize.zip"

# --- The update archive (Sparkle) and the download (DMG) ----------------------------------------------------------
ZIP="$DIST/Murmur-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
DMG="$DIST/Murmur-$VERSION.dmg"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Murmur.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Murmur" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
# The same file under a name that never changes, so the website can link to one address that's always the latest.
cp "$DMG" "$DIST/Murmur.dmg"

# --- The feed ------------------------------------------------------------------------------------------------------
mkdir -p "$ARCHIVES"
cp "$ZIP" "$ARCHIVES/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "$DOWNLOAD_PREFIX" "$ARCHIVES"
cp "$ARCHIVES/appcast.xml" "$DIST/appcast.xml"

# Any delta updates generate_appcast just made, quoted — the archive folder's name has a space in it.
NEW_FILES=$(find "$ARCHIVES" -newer "$ZIP" -name "*.delta" -print0 | xargs -0 -I{} printf '"%s" ' "{}")
REPO="janisbelozerovs-dev/murmur-releases"

cat <<DONE

Murmur $VERSION ($BUILD) is built, notarized and stapled:
  $ZIP          the update, for Sparkle
  $DMG          the download, for the website (also as $DIST/Murmur.dmg)
  $DIST/appcast.xml     the feed

To publish (nothing above has been uploaded) — the app files go to $REPO, never to the source repo:
  1. gh release view updates --repo $REPO >/dev/null 2>&1 || gh release create updates --repo $REPO \\
       --title "Murmur updates" --notes "Signed, notarized Murmur builds. Get Murmur at https://www.murmurmac.com"
     gh release upload updates --repo $REPO "$ZIP" "$DMG" "$DIST/Murmur.dmg" $NEW_FILES --clobber
  2. Put $DIST/appcast.xml at updates/appcast.xml in the website repo and deploy — installed copies see the update then.
  3. The website's download button: https://github.com/$REPO/releases/download/updates/Murmur.dmg
DONE
