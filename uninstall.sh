#!/bin/zsh
# Removes QuickConvert: quits it, unregisters the Finder extension and Services entry, and deletes the app.
# Converted files you made are left alone.
set -uo pipefail
DEST=~/Applications/QuickConvert.app

pkill -x QuickConvert 2>/dev/null
pluginkit -e ignore -i com.joshgreen.quickconvert.findersync 2>/dev/null
[[ -d $DEST ]] && pluginkit -r "$DEST/Contents/PlugIns/QuickConvertFinder.appex" 2>/dev/null
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$DEST" 2>/dev/null
rm -rf "$DEST"
/System/Library/CoreServices/pbs -update
echo "QuickConvert removed."
