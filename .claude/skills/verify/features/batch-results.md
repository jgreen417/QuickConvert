# Batch results

When everything converts, QuickConvert chimes and quits. When anything fails or the user cancels, a summary dialog gives exact counts, every error in full (naming the user's file, never internal temporary paths), **Show Converted Files**, and **Try Again** for retryable failures and cancelled files.

## Sub-features

- `results-success` plays a sound with no dialog, and logs `summary: converted=N failed=0 cancelled=0`.
- `results-mixed` shows `X of N conversions failed` with "N converted · X failed" and the errors.
- `results-show` reveals the converted files in Finder.
- `results-retry` re-runs only failures that can succeed on retry, plus cancelled files. Input problems aren't offered.
- `results-cancel` turns Cancel All in the menu bar into a `Conversion cancelled` summary, with nothing half-written on disk.
- `results-friendly-errors` names the user's file in errors, with no `/var/folders/…/QuickConvert-…` paths.

## How to get to it (user POV)

- Convert several files where some fail (a damaged image, for example).
- During a long conversion, click the menu-bar icon › **Cancel All**.

## Driving it with qc-session

Preconditions:

- `qc-doctor` exits 0.
- A fixture folder holds `good.png` (a real image), `bad.png` (`printf 'not an image' > bad.png`), `flaky.png` (same as bad) and `long.mov` (`ffmpeg -f lavfi -i testsrc2=d=30:s=1920x1080:r=30 -c:v prores long.mov`).

- **Mixed batch and Show.** Run `QS start 2 QC_TEST_SUMMARY_ANSWER=show -- <dir>/good.png <dir>/bad.png`, then `QS wait '^dialog: 1 of 2 conversions failed$'` and immediately `QS capture summary`. The screenshot shows `1 converted · 1 failed`, an error starting `bad.png:` with no temporary path, and **Show Converted File** and **Try Again**. `QS wait '^reveal: good.jpg$'` returns, and `good.jpg` exists.
- **Try Again after a fix.** Run `QS start 4 QC_TEST_SUMMARY_ANSWER=retry -- <dir>/flaky.png`, then `QS wait '^dialog: Conversion failed$'`. Fix the file with `cp good.png flaky.png` while the summary is open. `QS wait '^retry: flaky.png$'` and then `QS wait '^finished: flaky.png ok$'` return, `flaky.jpg` exists, and the second `summary:` line shows `failed=0`.
- **Cancel All.** Run `QS start 0.5 QC_TEST_CANCEL_AFTER=3 -- <dir>/long.mov`, then `QS wait '^finished: long.mov cancelled$' 60` and `QS wait '^summary: converted=0 failed=0 cancelled=1'`. The log has `dialog: Conversion cancelled`, `long.mp4` doesn't exist, and once the app has quit, `ls $TMPDIR | grep QuickConvert-` is empty.
- **Success is quiet.** Run `QS start 1 -- <dir>/good.png` after removing `good.jpg`, then `QS wait '^summary: converted=1 failed=0'`. The log has no `dialog:` line after the picker's.

## Gotchas

- Capture the summary within `<dwell>` seconds of its `dialog:` line. Test mode closes it after the dwell.
- Under test mode, Show logs `reveal:` instead of opening Finder windows. Say so in the proof.
- `QC_TEST_CANCEL_AFTER` exercises the same action as the menu-bar **Cancel All**, not the click on the menu item. Report the menu click as not verified unless a person or computer use clicked it.
- A file that fails validation (deleted mid-run, an unsupported pair) is deliberately not offered for **Try Again**.
