#!/bin/bash
# Publishes a GitHub release: ./release.sh X.Y.Z [--dry-run] [--skip-notarize]
#
# Bumps the version in Resources/Info.plist, builds the app signed with the Developer ID and Apple's
# timestamp, packs it into a DMG, notarizes and staples the DMG, then commits the bump, tags vX.Y.Z,
# pushes and creates the GitHub release with the DMG and the Sparkle appcast.xml that installed copies
# check for updates (SUFeedURL points at the latest release's appcast.xml). NOTES_FILE adds your own
# notes on top of the generated ones; they also show in the update window.
#
# The update signature uses the Sparkle EdDSA key in the login keychain (made once with
# .build/artifacts/sparkle/Sparkle/bin/generate_keys); its public half must match SUPublicEDKey.
#
# Finally it bumps the Homebrew cask in TAP_REPO (default yxod/homebrew-tap), if that repository exists.
#
# --dry-run stops after the DMG: nothing is committed, tagged or published, and Info.plist is restored.
# --skip-notarize skips Apple's notary service (only sensible together with --dry-run).
#
# One-time setup for notarization; it asks for an app-specific password made at appleid.apple.com:
#   xcrun notarytool store-credentials hidebar-notary --apple-id YOUR_APPLE_ID --team-id 2U5V9VG262
# NOTARY_PROFILE overrides the profile name.
set -euo pipefail
cd "$(dirname "$0")"

usage() { echo "usage: $0 X.Y.Z [--dry-run] [--skip-notarize]" >&2; exit 64; }
step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
shift
DRY_RUN=0
NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --skip-notarize) NOTARIZE=0 ;;
        *) usage ;;
    esac
done
[ "$NOTARIZE" = 1 ] || [ "$DRY_RUN" = 1 ] || fail "--skip-notarize is only for --dry-run; users would get a Gatekeeper warning"

NOTARY_PROFILE="${NOTARY_PROFILE:-hidebar-notary}"
TAG="v$VERSION"
PLIST="Resources/Info.plist"
DMG="build/HideBar-$VERSION.dmg"
APPCAST="build/appcast.xml"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

step "Preflight"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
[ "$(git branch --show-current)" = "main" ] || fail "releases are cut from main"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "tag $TAG already exists"; fi
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n '/Developer ID Application/{s/.*"\(Developer ID Application: [^"]*\)".*/\1/p;q;}')"
[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate in the keychain"
echo "Signing as: $IDENTITY"
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve >/dev/null
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
[ "$KEYCHAIN_KEY" = "$PLIST_KEY" ] \
    || fail "the Sparkle key in the keychain doesn't match SUPublicEDKey; installed copies would reject the update"
if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "no notarytool profile '$NOTARY_PROFILE'; run the setup line at the top of this script"
fi
if [ "$DRY_RUN" = 0 ]; then
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in sync with origin/main"
fi

# The bump is undone if anything fails before it is committed.
COMMITTED=0
cleanup() { [ "$COMMITTED" = 1 ] || git checkout -q -- "$PLIST"; }
trap cleanup EXIT

BUILD="$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))"
step "Version $VERSION ($BUILD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

step "Build"
SIGN_IDENTITY="$IDENTITY" SIGN_TIMESTAMP=1 ./build.sh
codesign --verify --strict --deep --verbose=2 build/HideBar.app

step "Disk image"
STAGE="$(mktemp -d)"
cp -R build/HideBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "HideBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$NOTARIZE" = 1 ]; then
    step "Notarize (a few minutes)"
    RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    STATUS="$(plutil -extract status raw -o - - <<< "$RESULT")"
    SUBMISSION="$(plutil -extract id raw -o - - <<< "$RESULT")"
    if [ "$STATUS" != "Accepted" ]; then
        xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" || true
        fail "notarization finished as $STATUS"
    fi
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

step "Update signature"
# Prints: sparkle:edSignature="…" length="…"
ED_ATTRIBUTES="$("$SPARKLE_BIN/sign_update" "$DMG")"
echo "$ED_ATTRIBUTES"

if [ "$DRY_RUN" = 1 ]; then
    step "Dry run done: $DMG. Nothing committed, tagged or published."
    exit 0
fi

step "Commit, tag, push"
git commit -q -m "Release $VERSION" -- "$PLIST"
COMMITTED=1
git tag -a "$TAG" -m "HideBar $VERSION"
git push -q origin main "$TAG"

step "GitHub release"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
NOTES_ARGS=(--generate-notes)
if [ -n "${NOTES_FILE:-}" ]; then NOTES_ARGS+=(--notes-file "$NOTES_FILE"); fi
# A draft first, so the latest release never lacks the appcast installed copies look for.
gh release create "$TAG" "$DMG" --draft --title "HideBar $VERSION" "${NOTES_ARGS[@]}" >/dev/null

step "Appcast"
NOTES_HTML="$(gh release view "$TAG" --json body -q .body \
    | gh api markdown -F text=@- -f mode=gfm -f context="$REPO")"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>HideBar</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>HideBar $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$DMG")"
                 type="application/octet-stream" $ED_ATTRIBUTES/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
gh release upload "$TAG" "$APPCAST"
gh release edit "$TAG" --draft=false --latest >/dev/null
echo "https://github.com/$REPO/releases/tag/$TAG"

step "Homebrew cask"
TAP_REPO="${TAP_REPO:-yxod/homebrew-tap}"
CASK_PATH="Casks/hidebar.rb"
if CASK_SHA="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq .sha 2>/dev/null)"; then
    DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    CASK="$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq .content | tr -d '\n' | base64 --decode \
        | sed -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$DMG_SHA\"/")"
    gh api -X PUT "repos/$TAP_REPO/contents/$CASK_PATH" -f message="hidebar $VERSION" \
        -f content="$(printf '%s\n' "$CASK" | base64)" -f sha="$CASK_SHA" >/dev/null
    echo "$TAP_REPO: hidebar $VERSION"
else
    echo "No $CASK_PATH in $TAP_REPO; skipped"
fi
