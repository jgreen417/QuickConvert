# Format picker

Opening files with QuickConvert (dropping them on the app, Services › Convert with QuickConvert…, or Choose Files… in the welcome window) shows a dialog. It names what was selected ("3 images", "2 images and 1 video"), offers a labeled **Format:** pop-up of the formats all of them can become, and converts on **Convert**.

## Sub-features

- `picker-single` shows `Convert <file>` and "The result is saved next to the original."
- `picker-multi` shows `Convert N files` with a summary of the selected types.
- `picker-default` preselects the most common format for the first file's type.
- `picker-none` shows `Nothing to convert` when the selection shares no format (an image plus an audio file, for example).
- `picker-limit` shows `Too many files` above 500 files, and converts nothing.
- `picker-welcome` opens a welcome dialog on a plain launch, with **Choose Files…** and **Done**.

## How to get to it (user POV)

- Drag files onto QuickConvert.app.
- In Finder (including iCloud Drive): right-click › **Services** › **Convert with QuickConvert…**
- Open QuickConvert.app › **Choose Files…**

## Driving it with qc-session

Preconditions:

- `qc-doctor` exits 0.
- A fixture folder holds `photo.png`, `second.png` and `song.mp3` (`ffmpeg -f lavfi -i sine=d=1 song.mp3`).

- **Single file.** Drop one image. Run `QS start 20 -- <dir>/photo.png`, then `QS wait '^dialog: Convert photo.png$'` and `QS capture picker-single`. The screenshot shows `Convert photo.png`, `Format:` and `JPEG`. After 20 s, `QS wait '^finished: photo.png ok$'` returns and `photo.jpg` exists.
- **Multiple files.** Drop two images. Run `QS start 20 -- <dir>/photo.png <dir>/second.png`, then `QS wait '^dialog: Convert 2 files$'` and `QS capture picker-multi`. The dialog reads "2 images. Results are saved next to the originals." Both `.jpg` files appear.
- **No shared format.** Drop an image and an audio file. Run `QS start 1 -- <dir>/photo.png <dir>/song.mp3`, then `QS wait '^dialog: Nothing to convert$'`. No file is written, and `QS wait '^quit$' 15` returns.
- **Too many.** Drop 501 images. Create them with `for i in {1..501}; do cp photo.png many/p$i.png; done`, then run `QS start 1 -- <dir>/many/*.png` and `QS wait '^dialog: Too many files$'`. `many/` contains no `.jpg`.
- **Welcome.** Run `QS start 15` with no files, then `QS wait '^dialog: QuickConvert$'` and `QS capture welcome`. The window shows **Choose Files…** and **Done** and mentions Services for iCloud Drive.

## Gotchas

- Test mode can only accept the default format. To prove a different target, use `QS job <ext>` (see [Finder Convert to menu](./finder-convert-menu.md)), and report it as the handoff entry point, not the picker.
- The picker lists formats in the first file's order. With mixed types, the default can differ from what you'd get by selecting the other file first.
- Choose Files… opens a system file dialog that test mode doesn't answer. Drive selection through `start -- files` and report Choose Files itself as not verified unless a person used it.
