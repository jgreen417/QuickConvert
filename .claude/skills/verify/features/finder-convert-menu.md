# Finder Convert to menu

Right-clicking files in Finder shows **Convert to ›** with the formats every selected file can become. The most common format comes first, and the files' own format is hidden. Choosing one converts the files, and the results appear next to the originals.

## Sub-features

- `menu-list` lists formats per file type: images start JPEG, PNG…; video starts MP4; audio starts MP3; documents start PDF when LibreOffice is installed.
- `menu-hide-source` hides the selection's own format when all selected files share it.
- `menu-multi` offers only the formats common to a multi-selection, and no item at all when there are none.
- `menu-handoff` converts the chosen files after a menu choice, with no dialog.
- `menu-cloud` hides **Convert to** in iCloud Drive (macOS hides Finder extension menus there). **Services › Convert with QuickConvert…** stays available.

## How to get to it (user POV)

- Right-click (or Control-click) one or more files in a Finder window › **Convert to** › a format.
- In iCloud Drive folders: right-click › **Services** › **Convert with QuickConvert…**, which opens the [format picker](./format-picker.md).

## Driving it with qc-session

Preconditions:

- `qc-doctor` shows "Finder extension registered and enabled" and "Finder has the extension loaded".
- A fixture folder holds `photo.png`, `clip.mov` (from `ffmpeg -f lavfi -i testsrc2=d=2:s=320x240 -c:v libx264 -pix_fmt yuv420p clip.mov`) and `memo.docx` (from `textutil -convert docx`).

- **Open the menu (needs a person or computer use).** Start the watcher with `.claude/skills/verify/scripts/qc-finder-watch "$EVIDENCE/finder" 600`. Run `open -a Finder <fixture-dir>` and ask the user to right-click `photo.png` and hover **Convert to**. The watcher prints `captured into …`. `finder-*.png` shows the submenu listing JPEG, WEBP, HEIC, AVIF, GIF, TIFF, BMP, ICO and PDF, with PNG absent.
- **Choose a format (person).** The user clicks **JPEG**. `photo.jpg` appears next to `photo.png`, and `file photo.jpg` reports JPEG image data.
- **Handoff without the click (scriptable).** This reproduces exactly what the extension sends. Run `QS start 1`, then `QS job webp <dir>/photo.png` and `QS wait '^finished: photo.png ok$'`. The log has no `dialog: Convert` line, and `photo.webp` exists.
- **Per-type ordering.** Open the submenu on `clip.mov`. The first item is `MP4` and `MOV` is absent. On `memo.docx` with LibreOffice installed, the first item is `PDF`.
- **Forged link does nothing.** Run `QS start 1`, then `QS url "quickconvert://job/$(uuidgen)"` and `QS wait '^quit$' 15`. The log has no `dialog:` lines, and no file was written.

## Gotchas

- A menu entry missing right after `./build.sh` or `quickconvert setup` usually means Finder hasn't picked up the new extension yet. Rerun `qc-doctor` or `killall Finder`. It isn't a code failure until doctor shows the extension loaded.
- On multi-monitor Macs, computer use's right-click and Control-click have landed in the wrong place (they opened the desktop menu), while left-click is accurate. Prefer asking the user. If using computer use, check with a screenshot that the menu belongs to the file (`Compress "<file>"` is in it), then hover **Convert to** and press Return on the highlighted item instead of clicking.
- Computer use can't see QuickConvert's own windows (it's a background app). Capture those with `QS capture`.
- `QS job` proves the app side of the handoff, not that the extension builds the menu or writes the job. Only a real right-click proves those.
