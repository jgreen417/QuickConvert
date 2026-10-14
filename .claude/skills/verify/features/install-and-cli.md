# Install and command line

Users install QuickConvert with Homebrew (`brew install jgreen417/tap/quickconvert`, then `quickconvert setup`) or from source (`./build.sh`). Setup copies the app to `~/Applications`, registers and enables the Finder extension, and relaunches Finder. `quickconvert uninstall` removes the app, the extension and the Services entry, and leaves converted files alone.

## Sub-features

- `install-source` makes `./build.sh` build universal binaries, sign them (Apple Development, or ad-hoc), install, and enable.
- `install-brew` has Homebrew build ad-hoc for the native architecture. `quickconvert setup` installs that copy.
- `install-register` waits until the extension reports `+` before relaunching Finder.
- `install-uninstall` removes the app and the extension registration.
- `install-help` prints usage from `quickconvert --help`.

## How to get to it (user POV)

- `brew install jgreen417/tap/quickconvert && quickconvert setup`
- `git clone … && ./build.sh`
- `quickconvert uninstall`

## Driving it with qc-session

Preconditions:

- You accept that these steps replace the installed app and relaunch Finder (the user's Finder windows reopen).
- No QuickConvert instance is running (`qc-doctor`).

- **Source install.** Run `./build.sh`. Output ends with `QuickConvert is installed in ~/Applications.`, `qc-doctor` shows "installed app is this checkout's build", "registered and enabled" and "Finder has the extension loaded".
- **Uninstall.** Run `quickconvert uninstall` (or `bin/quickconvert uninstall`). It prints `QuickConvert removed.`, `~/Applications/QuickConvert.app` is gone, and `pluginkit -m -i io.github.jgreen417.quickconvert.findersync` prints nothing. Reinstall afterwards with `./build.sh`.
- **Homebrew.** Run `brew upgrade jgreen417/tap/quickconvert`, or `brew reinstall` at the same version, then `quickconvert setup`. `qc-doctor` shows `Signature=adhoc`, and an end-to-end conversion through `QS job jpg <file>` produces the file.
- **Help.** `quickconvert --help` exits 1 and prints both `setup` and `uninstall` usage lines.

## Gotchas

- Installing the formula can unlink a user's `imagemagick-full` in favour of the `imagemagick` dependency. Check `readlink /opt/homebrew/bin/magick` before and after, and relink with `brew unlink imagemagick && brew link imagemagick-full` if you changed it.
- `quickconvert setup` from Homebrew installs the Homebrew build, not this checkout. `qc-doctor` flags the mismatch.
- If Finder still lacks the menu after setup, run `killall Finder` once. Setup already does this; repeated misses are a bug.
