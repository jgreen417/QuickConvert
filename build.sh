#!/bin/zsh
# Builds QuickConvert.app (host app + Finder Sync extension), signs it, installs to ~/Applications
# and enables the extension.
set -euo pipefail
cd "${0:A:h}"

APP=build/QuickConvert.app
EXT=$APP/Contents/PlugIns/QuickConvertFinder.appex
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
: "${IDENTITY:?No Apple Development signing identity found}"

rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $EXT/Contents/MacOS

# Universal binaries: Apple silicon + Intel.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -module-name QuickConvert \
    App/*.swift Shared/*.swift -o build/QuickConvert-$arch
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -module-name QuickConvertFinder -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync \
    Extension/*.swift Shared/*.swift -o build/QuickConvertFinder-$arch
done
lipo -create build/QuickConvert-{arm64,x86_64} -output $APP/Contents/MacOS/QuickConvert
lipo -create build/QuickConvertFinder-{arm64,x86_64} -output $EXT/Contents/MacOS/QuickConvertFinder

cp App/Info.plist $APP/Contents/Info.plist
cp App/AppIcon.icns $APP/Contents/Resources/
cp Extension/Info.plist $EXT/Contents/Info.plist

codesign --force --options runtime --sign "$IDENTITY" --entitlements Extension/Extension.entitlements $EXT
codesign --force --options runtime --sign "$IDENTITY" $APP

DEST=~/Applications/QuickConvert.app
mkdir -p ~/Applications
# Stage the new bundle next to the old one and verify it before swapping, so a bad build never leaves you with nothing.
rm -rf $DEST.new  # not a .app name, so Launch Services never registers the staged copy
cp -R $APP $DEST.new
codesign --verify --deep --strict $DEST.new
pkill -x QuickConvert || true
rm -rf $DEST.old
[[ -e $DEST ]] && mv $DEST $DEST.old
mv $DEST.new $DEST
rm -rf $DEST.old

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $DEST
pluginkit -a $DEST/Contents/PlugIns/QuickConvertFinder.appex
pluginkit -e use -i io.github.jgreen417.quickconvert.findersync
/System/Library/CoreServices/pbs -update  # pick up the Services menu entry
echo "Installed $DEST"
pluginkit -m -v -i io.github.jgreen417.quickconvert.findersync
