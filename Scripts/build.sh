#!/bin/zsh
# Builds an arm64 release binary, Barkeep.app, and two installer packages, each with the
# LaunchDaemon that does the work: barkeep-full-<version>.pkg puts the binary in /usr/local/bin,
# Barkeep.app in /Applications and its LaunchAgent in /Library/LaunchAgents, and
# barkeep-cli-<version>.pkg installs only the binary and the daemon.
#
#   Scripts/build.sh [--sign "Developer ID Application: …"] [--pkg-sign "Developer ID Installer: …"]
#                    [--notarize <notarytool keychain profile>]
#
# --notarize submits the signed packages to Apple and staples the tickets. MDMs install packages
# without Gatekeeper, so it is optional, but it lets the package be opened by hand too.
#
# Output: .build/dist/barkeep, .build/dist/Barkeep.app, .build/dist/barkeep-full-<version>.pkg and
# .build/dist/barkeep-cli-<version>.pkg
set -euo pipefail

cd "${0:A:h}/.."
APP_SIGN=""
PKG_SIGN=""
NOTARY_PROFILE=""
while (( $# )); do
    case "$1" in
        --sign) APP_SIGN="$2"; shift 2 ;;
        --pkg-sign) PKG_SIGN="$2"; shift 2 ;;
        --notarize) NOTARY_PROFILE="$2"; shift 2 ;;
        *) echo "Unknown option $1" >&2; exit 64 ;;
    esac
done
if [[ -n "$NOTARY_PROFILE" && ( -z "$APP_SIGN" || -z "$PKG_SIGN" ) ]]; then
    echo "--notarize needs --sign and --pkg-sign" >&2; exit 64
fi

# Apple silicon only: macOS 27 runs on nothing else.
swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)
DIST=.build/dist
IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Support/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Support/Info.plist)
rm -rf "$DIST"; mkdir -p "$DIST"
cp "$BIN/barkeep" "$DIST/barkeep"

# Barkeep.app: the GUI, versioned from Support/Info.plist.
APP="$DIST/Barkeep.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BarkeepApp" "$APP/Contents/MacOS/Barkeep"
cp Support/App-Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
    -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Design/logo/menubar/barkeepTemplate.png Design/logo/menubar/barkeepTemplate@2x.png "$APP/Contents/Resources/"
# The Icon Composer icon becomes Assets.car (light, dark and tinted) and AppIcon.icns.
xcrun actool Design/logo/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 27.0 \
    --output-partial-info-plist "$DIST/icon-info.plist" > /dev/null
test -f "$APP/Contents/Resources/Assets.car" -a -f "$APP/Contents/Resources/AppIcon.icns"
rm "$DIST/icon-info.plist"
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")

if [[ -n "$APP_SIGN" ]]; then
    codesign --force --options runtime --timestamp --identifier "$IDENTIFIER" --sign "$APP_SIGN" "$DIST/barkeep"
    codesign --force --options runtime --timestamp --identifier "$APP_IDENTIFIER" --sign "$APP_SIGN" "$APP"
else
    codesign --force --identifier "$IDENTIFIER" --sign - "$DIST/barkeep"
    codesign --force --identifier "$APP_IDENTIFIER" --sign - "$APP"
fi
codesign --verify --strict "$APP"

# Builds a package of the folder $1 at $2. Both packages have the identifier uk.street365.barkeep, so
# the receipt is the last one installed; the daemon reads it to choose which to install when it updates itself.
build_pkg() {
    local root=$1 pkg=$2
    install -d -m 755 "$root/usr/local/bin" "$root/Library/LaunchDaemons"
    install -m 755 "$DIST/barkeep" "$root/usr/local/bin/barkeep"
    install -m 644 Support/uk.street365.barkeep.daemon.plist "$root/Library/LaunchDaemons/"
    plutil -lint "$root/Library/LaunchDaemons/"*.plist > /dev/null
    # Install the app where the package says, not wherever the user may have moved an older copy.
    pkgbuild --analyze --root "$root" "$DIST/components.plist"
    for (( i = 0; ; i++ )); do
        /usr/libexec/PlistBuddy -c "Print :$i" "$DIST/components.plist" > /dev/null 2>&1 || break
        /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$DIST/components.plist" > /dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$DIST/components.plist"
    done
    pkgbuild --root "$root" --component-plist "$DIST/components.plist" --identifier "$IDENTIFIER" \
        --scripts Support/scripts \
        --version "$VERSION" --install-location / "$DIST/unclean.pkg"

    # pkgbuild archives extended attributes as ._ AppleDouble files, and com.apple.provenance cannot be
    # cleared from files this build created. Drop those entries from the payload and Bom, keeping
    # pkgbuild's root:wheel ownership, and sign only afterwards.
    pkgutil --expand "$DIST/unclean.pkg" "$DIST/expanded"
    gzip -dc "$DIST/expanded/Payload" | bsdtar -cf - --format odc --exclude '._*' @- | gzip -9 > "$DIST/Payload"
    mv "$DIST/Payload" "$DIST/expanded/Payload"
    lsbom "$DIST/expanded/Bom" | grep -v '/\._' > "$DIST/bom.txt"
    mkbom -i "$DIST/bom.txt" "$DIST/expanded/Bom"
    sed -i '' "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$(wc -l < "$DIST/bom.txt" | tr -d ' ')\"/" "$DIST/expanded/PackageInfo"
    if [[ -n "$PKG_SIGN" ]]; then
        pkgutil --flatten "$DIST/expanded" "$DIST/unsigned.pkg"
        productsign --sign "$PKG_SIGN" --timestamp "$DIST/unsigned.pkg" "$pkg"
    else
        pkgutil --flatten "$DIST/expanded" "$pkg"
    fi
    rm -rf "$DIST/unclean.pkg" "$DIST/unsigned.pkg" "$DIST/expanded" "$DIST/bom.txt" "$DIST/components.plist"
    if pkgutil --payload-files "$pkg" | grep -q '/\._'; then
        echo "AppleDouble files remain in $pkg" >&2; exit 1
    fi
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$pkg"
    fi
    rm -rf "$root"
}

PKG="$DIST/barkeep-full-$VERSION.pkg"
CLI_PKG="$DIST/barkeep-cli-$VERSION.pkg"
mkdir -p "$DIST/root/Applications" "$DIST/root/Library/LaunchAgents"
ditto "$APP" "$DIST/root/Applications/Barkeep.app"
install -m 644 Support/uk.street365.barkeep.agent.plist "$DIST/root/Library/LaunchAgents/"
build_pkg "$DIST/root" "$PKG"
build_pkg "$DIST/root-cli" "$CLI_PKG"
if pkgutil --payload-files "$CLI_PKG" | grep -q 'Barkeep\.app'; then
    echo "$CLI_PKG contains Barkeep.app" >&2; exit 1
fi
echo "Built $DIST/barkeep, $APP, $PKG and $CLI_PKG"
