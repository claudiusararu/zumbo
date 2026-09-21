#!/bin/bash
#
# Cuts a Zumbo release: build, bundle the speech models, sign inside-out,
# make the DMG, notarize, staple, sign the appcast entry, upload to R2.
#
# One pass, no retries, no loops: every step prints its name and the script
# stops on the first failure so the reason is the last thing on screen.
#
#   scripts/release.sh                    full release, uploads to R2
#   scripts/release.sh --no-upload        everything including notarization, no upload
#   scripts/release.sh --skip-notarize    dry run, stops after the DMG
#   scripts/release.sh --allow-existing-tag
#       skip the "tag already exists" guard, to knowingly re-cut a version
#       that was already tagged and shipped (e.g. re-signing the same
#       version after a packaging fix). Never bumps the tag itself.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

SKIP_NOTARIZE=0
NO_UPLOAD=0
ALLOW_EXISTING_TAG=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --no-upload) NO_UPLOAD=1 ;;
        --allow-existing-tag) ALLOW_EXISTING_TAG=1 ;;
        *) echo "unknown flag: $arg"; exit 1 ;;
    esac
done

IDENTITY="Developer ID Application"
NOTARY_PROFILE="motificons-notary"
ZONE_ID="9f9a6a9860a445640b063d29c7134bdc"
BUCKET="zumbo-updates"
DOMAIN="updates.zumbo.app"
WRANGLER="${WRANGLER:-$(command -v wrangler || echo npx wrangler)}"
SAFE_RUN="$ROOT/../hooppaper/scripts/safe-run.sh"
SPARKLE_BIN="$ROOT/build/sparkle-tools/bin"
FLUID_CACHE="$HOME/Library/Application Support/FluidAudio/Models"

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- 1. preflight

step "Reading version from project.yml"
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
[ -n "$VERSION" ] || { echo "could not read MARKETING_VERSION"; exit 1; }
[ -n "$BUILD" ] || { echo "could not read CURRENT_PROJECT_VERSION"; exit 1; }
echo "    Zumbo $VERSION (build $BUILD)"

step "Checking the working tree is clean"
# Engine/Package.resolved is excluded on purpose: xcodebuild writes Sparkle's
# pin into it and `swift test` writes it back out again, so it flips on its
# own between the two tools and would fail this check after every build. The
# pin that matters (FluidAudio, exact 0.15.7) lives in Engine/Package.swift.
DIRTY=$(git status --porcelain | grep -v 'Engine/Package.resolved' || true)
if [ -n "$DIRTY" ]; then
    echo "working tree is dirty; commit or stash first:"
    echo "$DIRTY"
    exit 1
fi

step "Checking tag v$VERSION does not exist yet"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    if [ "$ALLOW_EXISTING_TAG" -eq 1 ]; then
        echo "    tag v$VERSION already exists; continuing (--allow-existing-tag), re-cutting the same version"
    else
        echo "tag v$VERSION already exists; bump MARKETING_VERSION in project.yml, or pass --allow-existing-tag to knowingly re-cut it"
        exit 1
    fi
fi

step "Checking the signing identity is available"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
    echo "no \"$IDENTITY\" identity in the keychain"; exit 1; }

# ------------------------------------------------------------------- 2. build

step "Generating the Xcode project"
xcodegen generate -q

step "Building Release"
DERIVED="build/Release-dist"
rm -rf "$DERIVED/Build/Products/Release/Zumbo.app"
"$SAFE_RUN" -m 12288 -t 900 xcodebuild \
    -project Zumbo.xcodeproj -scheme Zumbo -configuration Release \
    -derivedDataPath "$DERIVED" build

APP="$DERIVED/Build/Products/Release/Zumbo.app"
[ -d "$APP" ] || { echo "build produced no app at $APP"; exit 1; }

step "Verifying the app's resources"
[ -f "$APP/Contents/Info.plist" ] || { echo "no Info.plist"; exit 1; }
[ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || { echo "Sparkle.framework was not embedded"; exit 1; }
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist")
EDKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist")
echo "    feed $FEED"
echo "    public key $EDKEY"

# ------------------------------------------------------- 3. bundle the models
#
# The DMG carries the speech engine so dictation works offline from the first
# launch. `BundledModels.installIfNeeded` copies these into FluidAudio's own
# cache on first run; the folder names here are FluidAudio 0.15.7's
# `Repo.folderName` values, which is why silero is renamed on the way in (it
# sits in the local cache under its pre-0.15 name).
#
# Speaker labels (sortformer) are NOT bundled: that stays an add-on download
# from models.zumbo.app, started only by Settings > Models.

step "Bundling the speech models"
MODELS_DEST="$APP/Contents/Resources/Models"
rm -rf "$MODELS_DEST"
mkdir -p "$MODELS_DEST"
copy_model() {
    local src="$FLUID_CACHE/$1"
    local dest="$MODELS_DEST/$2"
    [ -d "$src" ] || { echo "missing model in the FluidAudio cache: $src"; exit 1; }
    echo "    $1 -> Resources/Models/$2"
    ditto "$src" "$dest"
}
copy_model "parakeet-tdt-0.6b-v3-coreml" "parakeet-tdt-0.6b-v3-coreml"
copy_model "parakeet-ctc-110m-coreml" "parakeet-ctc-110m-coreml"
copy_model "silero-vad" "silero-vad-coreml"
echo "    bundled $(du -sh "$MODELS_DEST" | cut -f1)"

# -------------------------------------------------------------- 4. sign it all
#
# Inside-out: Sparkle's helpers and XPC services first, then the framework,
# then the app. The hardened runtime everywhere, a secure timestamp
# everywhere, entitlements on the outer app only.

step "Signing inside-out"
sign() {
    echo "    $(basename "$1")"
    codesign --force --options runtime --sign "$IDENTITY" --timestamp "$1"
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_V="$SPARKLE/Versions/B"
for service in "$SPARKLE_V"/XPCServices/*.xpc; do
    [ -e "$service" ] || continue
    sign "$service"
done
if [ -e "$SPARKLE_V/Updater.app" ]; then sign "$SPARKLE_V/Updater.app"; fi
if [ -e "$SPARKLE_V/Autoupdate" ]; then sign "$SPARKLE_V/Autoupdate"; fi
sign "$SPARKLE"
for framework in "$APP"/Contents/Frameworks/*.framework; do
    [ "$framework" = "$SPARKLE" ] && continue
    [ -e "$framework" ] || continue
    sign "$framework"
done
echo "    Zumbo.app"
codesign --force --options runtime --sign "$IDENTITY" --timestamp \
    --entitlements Support/Zumbo.entitlements "$APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- 5. the DMG

step "Building the DMG"
mkdir -p dist
DMG="dist/Zumbo-$VERSION.dmg"
STAGE="build/dmg-stage"
rm -rf "$STAGE" "$DMG" "build/Zumbo-rw.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zumbo.app"
ln -s /Applications "$STAGE/Applications"

# Background art: design/dmg/background.png (1320x800 px, 144 dpi -> reads as
# 660x400 pt), rendered by design/dmg/render-background.swift. The dot-folder
# keeps it hidden from the Finder window itself.
BACKGROUND_PNG="design/dmg/background.png"
if [ ! -f "$BACKGROUND_PNG" ]; then
    echo "error: $BACKGROUND_PNG is missing - run: swift design/dmg/render-background.swift $BACKGROUND_PNG" >&2
    exit 1
fi
mkdir -p "$STAGE/.background"
cp "$BACKGROUND_PNG" "$STAGE/.background/background.png"

# Two steps, as in motificons/desktop/scripts/make-dmg.sh: a writable image
# the Finder can lay out, then a compressed read-only one to ship.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 200 ))
hdiutil create -srcfolder "$STAGE" -volname "Zumbo" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_MB}m" build/Zumbo-rw.dmg

DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen build/Zumbo-rw.dmg | \
    egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 3
osascript <<'APPLESCRIPT' || echo "    (Finder layout skipped)"
tell application "Finder"
    tell disk "Zumbo"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Zumbo.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        set the bounds of container window to {200, 120, 860, 520}
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
# "toolbar visible" / "statusbar visible" above only cover the classic
# toolbar and status bar. Modern Finder also shows a tab bar (with a "+"
# pill) and a path bar at the bottom by default on a fresh DMG window;
# neither has an AppleScript property, so toggle them off via the View menu
# through System Events while the window is still open. Idempotent: only
# clicks "Hide X" when the menu item says "Hide" (the bar is currently shown).
osascript <<'APPLESCRIPT' || echo "    (tab bar / path bar toggle skipped)"
tell application "Finder" to activate
delay 1
tell application "System Events"
    tell process "Finder"
        set frontmost to true
        tell menu 1 of menu bar item "View" of menu bar 1
            repeat with barName in {"Tab Bar", "Path Bar", "Toolbar", "Status Bar", "Sidebar"}
                set hideItem to "Hide " & barName
                if exists (menu item hideItem) then
                    click menu item hideItem
                    delay 0.3
                end if
            end repeat
        end tell
    end tell
end tell
APPLESCRIPT
osascript -e 'tell application "Finder" to close container window of disk "Zumbo"' || true
sync
hdiutil detach "$DEVICE"
hdiutil convert build/Zumbo-rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f build/Zumbo-rw.dmg
rm -rf "$STAGE"

# The DMG container itself is signed too: without it spctl's
# primary-signature check on the disk image is rejected even when the app
# inside is fine.
step "Signing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo
    echo "==> Dry run: $DMG built but NOT notarized and NOT published."
    echo "    Do not give this DMG to anyone; Gatekeeper will refuse it."
    ls -lh "$DMG"
    exit 0
fi

# ------------------------------------------------------------ 6. notarization

step "Notarizing (this takes a few minutes for a ~570 MB image)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

step "Stapling the ticket"
xcrun stapler staple "$DMG"

step "Checking Gatekeeper accepts the DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

step "Checking Gatekeeper accepts the app inside"
# The mount point is on the last /dev/ line, not the first: the first is the
# partition scheme, which has no mount point at all and left this checking
# "/Zumbo.app" the first time round.
MOUNT=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -o '/Volumes/.*' | tail -1)
[ -n "$MOUNT" ] || { echo "could not work out where the DMG mounted"; exit 1; }
spctl -a -vv "$MOUNT/Zumbo.app" || { hdiutil detach "$MOUNT"; exit 1; }
hdiutil detach "$MOUNT"

# --------------------------------------------------------------- 7. appcast

step "Signing the DMG for Sparkle"
[ -x "$SPARKLE_BIN/sign_update" ] || {
    echo "no sign_update at $SPARKLE_BIN; re-download the Sparkle release into build/sparkle-tools/"
    exit 1; }
SIGN_OUTPUT=$("$SPARKLE_BIN/sign_update" "$DMG")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -n "$ED_SIGNATURE" ] || { echo "sign_update produced no signature: $SIGN_OUTPUT"; exit 1; }
echo "    length $LENGTH bytes"

step "Writing dist/appcast.xml"
APPCAST="dist/appcast.xml"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM="        <item>
            <title>Zumbo $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url=\"https://$DOMAIN/Zumbo-$VERSION.dmg\" length=\"$LENGTH\" type=\"application/octet-stream\" sparkle:edSignature=\"$ED_SIGNATURE\"/>
        </item>"
if [ -f "$APPCAST" ]; then
    # Keep every older <item> for a DIFFERENT version: Sparkle picks the
    # newest one it can run, and dropping the history would strand anyone
    # on an older macOS. An item for the SAME version is dropped instead of
    # kept alongside the new one - this is a re-cut (packaging fix, same
    # marketing version and build), and the file at the enclosure URL was
    # just overwritten, so the old item's length/signature no longer match
    # anything downloadable.
    OLD_ITEMS=$(awk -v ver="$VERSION" '
        /<item>/ { buf = $0; inItem = 1; skip = 0; next }
        inItem {
            buf = buf "\n" $0
            if ($0 ~ "<sparkle:shortVersionString>" ver "</sparkle:shortVersionString>") skip = 1
            if ($0 ~ "</item>") {
                inItem = 0
                if (!skip) print buf
            }
            next
        }
    ' "$APPCAST")
else
    OLD_ITEMS=""
fi
{
    echo '<?xml version="1.0" standalone="yes"?>'
    echo '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
    echo '    <channel>'
    echo '        <title>Zumbo</title>'
    echo "        <link>https://$DOMAIN/appcast.xml</link>"
    echo '        <description>Updates for Zumbo, local dictation for the Mac.</description>'
    echo '        <language>en</language>'
    echo "$ITEM"
    if [ -n "$OLD_ITEMS" ]; then echo "$OLD_ITEMS"; fi
    echo '    </channel>'
    echo '</rss>'
} > "$APPCAST"
echo "    wrote $APPCAST"

if [ "$NO_UPLOAD" -eq 1 ]; then
    echo
    echo "==> --no-upload: notarized and stapled, appcast written, nothing published."
fi

# ---------------------------------------------------------------- 8. upload

if [ "$NO_UPLOAD" -eq 0 ]; then
    step "Making sure the R2 bucket exists"
    "$WRANGLER" r2 bucket create "$BUCKET" --location weur 2>&1 | tail -3 || true

    step "Making sure $DOMAIN points at it"
    "$WRANGLER" r2 bucket domain add "$BUCKET" --domain "$DOMAIN" \
        --zone-id "$ZONE_ID" --min-tls 1.2 -y 2>&1 | tail -3 || true

    # wrangler refuses any file over 300 MiB (a hard client-side check - it
    # uploads in one PUT, it has no multipart path). A Zumbo DMG is ~550 MiB
    # because the speech engine is bundled, so it always needs the S3 API
    # instead, which means an R2 API token rclone can use. Set that up once:
    #   Cloudflare dashboard > R2 > API > Create API token (Object Read+Write)
    #   rclone config: type s3, provider Cloudflare, endpoint
    #     https://<account id>.r2.cloudflarestorage.com
    #   remote name: zumbo-r2
    step "Uploading the DMG"
    DMG_BYTES=$(stat -f%z "$DMG")
    if [ "$DMG_BYTES" -gt 314572800 ]; then
        if command -v rclone >/dev/null && rclone listremotes | grep -q '^zumbo-r2:'; then
            rclone copyto "$DMG" "zumbo-r2:$BUCKET/Zumbo-$VERSION.dmg" --progress
        else
            echo "the DMG is $((DMG_BYTES / 1048576)) MiB; wrangler caps uploads at 300 MiB"
            echo "and no rclone remote 'zumbo-r2' is configured (see the comment above)."
            echo "Upload it by hand, then rerun this script - the appcast is NOT published"
            echo "yet, so nothing points at a missing file."
            exit 1
        fi
    else
        "$WRANGLER" r2 object put --remote "$BUCKET/Zumbo-$VERSION.dmg" \
            --file="$DMG" --content-type=application/x-apple-diskimage
    fi

    step "Uploading the appcast"
    "$WRANGLER" r2 object put --remote "$BUCKET/appcast.xml" \
        --file="$APPCAST" --content-type=application/xml

    step "Checking both are served"
    curl -sI "https://$DOMAIN/Zumbo-$VERSION.dmg" | head -6
    curl -sI "https://$DOMAIN/appcast.xml" | head -6
    echo "    local DMG is $(stat -f%z "$DMG") bytes, appcast $(stat -f%z "$APPCAST") bytes"
fi

# ------------------------------------------------------------------ 9. done

step "Done"
echo "    $DMG"
echo "    $(du -m "$DMG" | cut -f1) MB"
echo "    sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "    Tag it yourself when you are happy with it:"
echo "        git tag v$VERSION && git push origin v$VERSION"
