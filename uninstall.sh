#!/bin/zsh
# Removes QuickConvert: quits it, unregisters the Finder extension and Services entry, and deletes the app.
# Converted files you made are left alone. (Same as `quickconvert uninstall`.)
exec "${0:A:h}/bin/quickconvert" uninstall
