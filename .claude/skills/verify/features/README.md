# QuickConvert verification map

This directory is the maintained source for verifying QuickConvert's user-facing behavior. Read this index before driving the app, then use the matching feature file as the recipe. `QS` below means `.claude/skills/verify/scripts/qc-session`.

## Baseline preconditions

- This checkout is built and installed with `./build.sh`, or Homebrew's build with `quickconvert setup`.
- `.claude/skills/verify/scripts/qc-doctor` exits 0. Its signature and build lines match what you mean to test.
- No QuickConvert instance is running that you didn't start.
- Fixtures are generated per run in a fresh `mktemp -d` folder and never taken from the user's files. Images come from `magick -size 64x48 plasma:fractal -depth 8 photo.png`, video from `ffmpeg -f lavfi -i testsrc2=...`, and protected Office files from `Tests/make-protected.sh <dir>`.

## Driving conventions

- One scenario is one session: `QS start <dwell> [K=V ...] -- <files>`, then `QS wait …`, then `QS stop`. The app quits ~5 s after it goes idle.
- Wait on event-log lines (`dialog:`, `finished:`, `summary:`, `reveal:`, `retry:`), not on sleeps.
- Use `QS job <ext> <files>` to choose a specific output format. The picker can only take its default under test mode.
- The Finder menu itself needs a person or computer use to open it. Everything after the click can be driven with `QS job`.

## Proof and skip reporting

- Capture the action (the `dialog:` line or a `QS capture` of the dialog), the result (the `summary:` line or the captured summary), and the files on disk, checked with `file`, `magick identify` or `ffprobe`.
- Record the feature file, the entry point used (`picker`, `job`, Finder right-click, Services) and the evidence directory with every claim.
- An entry point you couldn't drive is reported as not verified, with the reason. It is never reported as covered by a different entry point.

## Feature entry contract

Each feature file starts with an H1 and one paragraph describing the user-visible behavior, followed by four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with qc-session`, and `Gotchas`.

## Features

- [Finder Convert to menu](./finder-convert-menu.md): the extension's submenu, its format list per file type, and the handoff to the app.
- [Format picker](./format-picker.md): drop, Services, Choose Files, the labeled format control, the selection summary, and "Nothing to convert".
- [Batch results](./batch-results.md): the summary counts, full errors, Show Converted Files, Try Again, and cancellation.
- [Password-protected documents](./password-documents.md): the prompt, wrong password, skip, and successful conversion.
- [Install and command line](./install-and-cli.md): `./build.sh`, `quickconvert setup`/`uninstall`, Homebrew, and extension registration.
