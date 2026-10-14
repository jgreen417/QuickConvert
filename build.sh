#!/bin/zsh
# Builds QuickConvert.app (host app + Finder Sync extension) into build/, signs it, and installs it.
#
#   ./build.sh                 build, then install to ~/Applications (via bin/quickconvert setup)
#   ./build.sh --no-install    build only (used by the Homebrew formula)
#
# IDENTITY   signing identity; defaults to your Apple Development certificate, or ad-hoc ("-") without one
# ARCHS      architectures to build; defaults to "arm64 x86_64" (universal)
set -euo pipefail
cd "${0:A:h}"

APP=build/QuickConvert.app
EXT=$APP/Contents/PlugIns/QuickConvertFinder.appex
ARCHS=(${=ARCHS:-arm64 x86_64})
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $EXT/Contents/MacOS

for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -module-name QuickConvert \
    App/*.swift Shared/*.swift -o build/QuickConvert-$arch
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -module-name QuickConvertFinder -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync \
    Extension/*.swift Shared/*.swift -o build/QuickConvertFinder-$arch
done
lipo -create build/QuickConvert-${^ARCHS} -output $APP/Contents/MacOS/QuickConvert
lipo -create build/QuickConvertFinder-${^ARCHS} -output $EXT/Contents/MacOS/QuickConvertFinder

cp App/Info.plist $APP/Contents/Info.plist
cp App/AppIcon.icns $APP/Contents/Resources/
cp Extension/Info.plist $EXT/Contents/Info.plist

codesign --force --options runtime --sign "$IDENTITY" --entitlements Extension/Extension.entitlements $EXT
codesign --force --options runtime --sign "$IDENTITY" $APP
codesign --verify --deep --strict $APP
print "Built $APP ($ARCHS, signed with ${IDENTITY/#-/ad-hoc signature})"

[[ ${1:-} == --no-install ]] || bin/quickconvert setup $APP
