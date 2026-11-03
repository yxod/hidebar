#!/bin/bash
# Publishes a GitHub release: ./release.sh X.Y.Z [--dry-run] [--skip-notarize]
#
# Bumps the version in Resources/Info.plist, builds the app signed with the Developer ID and Apple's
# timestamp, packs it into a DMG, notarizes and staples the DMG, then commits the bump, tags vX.Y.Z,
# pushes and creates the GitHub release with the DMG attached. NOTES_FILE adds your own notes on top of
# the generated ones.
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

step "Preflight"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
[ "$(git branch --show-current)" = "main" ] || fail "releases are cut from main"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "tag $TAG already exists"; fi
IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n '/Developer ID Application/{s/.*"\(Developer ID Application: [^"]*\)".*/\1/p;q;}')"
[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate in the keychain"
echo "Signing as: $IDENTITY"
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
NOTES_ARGS=(--generate-notes)
if [ -n "${NOTES_FILE:-}" ]; then NOTES_ARGS+=(--notes-file "$NOTES_FILE"); fi
gh release create "$TAG" "$DMG" --title "HideBar $VERSION" "${NOTES_ARGS[@]}"
