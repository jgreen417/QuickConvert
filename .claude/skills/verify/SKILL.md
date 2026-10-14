---
name: verify
description: Drive the real QuickConvert macOS app (Finder "Convert to" menu, format picker, password prompts, batch results summary, quickconvert setup/uninstall) the way a user does and capture proof. Use after changing App/, Extension/, Shared/, bin/quickconvert or build.sh, or whenever you need to prove a QuickConvert behavior on the installed app rather than in unit-level tests.
---

# Verify QuickConvert

QuickConvert is a menu-bar-less macOS agent app plus a sandboxed Finder Sync extension. Users touch it through Finder's right-click **Convert to ›** menu, **Services › Convert with QuickConvert…**, dropping files on the app, and the `quickconvert` command. The host app has a **test mode** that logs every dialog to a file and answers it after a dwell time while it is still a real modal dialog; this skill drives the app through that mode with helpers that own the process they start.

Read [features/README.md](features/README.md) next, then the feature file for what you are proving.

## Launch

1. Build and install this checkout (replaces `~/Applications/QuickConvert.app`, registers the extension, relaunches Finder):

   ```bash
   ./build.sh
   ```

   Ready when it prints `QuickConvert is installed in ~/Applications.` and `qc-doctor` passes. From a Homebrew install instead: `quickconvert setup`.

2. Start one instance per scenario. The app quits ~5 s after its last job or dialog, so start it with the files the scenario needs:

   ```bash
   .claude/skills/verify/scripts/qc-session start <dwell-seconds> [KEY=VALUE ...] [-- <file>...]
   ```

   It prints `started pid <pid>` and the evidence directory once the app logs `launch <arch>`. Files given after `--` arrive as one open event, exactly like dropping a multi-selection on the app, and open the format picker.

Teardown: `qc-session stop` (see Cleanup).

## Doctor

Run first, and again whenever anything looks off. Read-only; exit 1 means don't drive.

```bash
.claude/skills/verify/scripts/qc-doctor
```

It checks: app installed and validly signed (ad-hoc or Apple Development), whether the installed binary is this checkout's `build/` (a `!` here means you are driving a Homebrew or stale build; run `./build.sh`), extension registered with `+` and loaded by Finder, every engine on disk (`magick ffmpeg ffprobe pdftoppm pdfinfo rsvg-convert textutil`, LibreOffice optional), the jobs folder `~/Library/Application Support/QuickConvert/Jobs` is `0700` and yours, no QuickConvert instance running that this session didn't start, and leftover work folders.

## Drive

All commands are `.claude/skills/verify/scripts/qc-session <command>`:

| Command | What it does |
|---|---|
| `start <dwell> [K=V ...] [-- file...]` | Launch the app binary in test mode (session holds the PID); refuses if any other QuickConvert is running |
| `send <file>...` | Open files in the running instance → format picker |
| `job <ext> <file>...` | Do exactly what the Finder extension does after a menu click: write a job file to the jobs folder and open `quickconvert://job/<uuid>`. Use this to pick a specific format; the picker can only take its default |
| `url <url>` | Open a raw `quickconvert://` URL (forged-link checks) |
| `wait <regex> [secs=30]` | Block until `events.log` has a matching line (ERE); prints it, or the whole log on timeout |
| `capture <name>` | Screenshot QuickConvert's front window **only** (`screencapture -l`) into the evidence dir |
| `log` / `status` / `stop` | Print the event log / show pid and evidence dir / stop our instance |

**Event log lines** (the stable handles to wait on):

```
launch arm64|x86_64
dialog: <title>            closed: <title>
finished: <file> ok|failed|cancelled|skipped|needs password|wrong password
summary: converted=N failed=N cancelled=N skipped=N
reveal: <output names>     retry: <file names>
cancel all                 quit
```

**How test mode answers dialogs** (after `<dwell>` seconds, only once the dialog is frontmost):

- Format picker `Convert <file>` / `Convert N files` → **Convert** with the first (default) format: JPEG for images, MP4 for video, MP3 for audio, PDF for documents when LibreOffice is installed.
- Welcome `QuickConvert` (plain launch, no files) → **Done**.
- Password `“<file>” is password-protected` / `Incorrect password for “<file>”` → types the next value of `QC_TEST_PASSWORDS=a,b,...` then **Convert**. An empty value counts as Skip.
- Results summary (`Conversion failed`, `N of M conversions failed`, `Conversion cancelled`, …) → **OK**, or `QC_TEST_SUMMARY_ANSWER=show|retry` picks **Show Converted Files** / **Try Again**. Under test mode, Show only logs `reveal:` and does not open Finder.
- `Nothing to convert`, `Too many files` → **OK**.
- `QC_TEST_CANCEL_AFTER=<s>` presses Cancel All after that many seconds, the same action as the menu-bar item.

**Finder's own menu** (the extension's `Convert to ›` submenu) can't be opened from a shell: posting clicks needs Accessibility permission this environment doesn't have. Either ask the user to right-click and hover **Convert to**, or use computer use. Run `scripts/qc-finder-watch <evidence-dir>/finder` first; it captures the Finder window and its menus the moment the submenu opens. See [features/finder-convert-menu.md](features/finder-convert-menu.md).

## Evidence

- Everything goes to `~/Library/Caches/QuickConvert-verify/evidence/<YYYYmmdd-HHMMSS>/` (override with `QC_VERIFY_EVIDENCE`). `stop` copies `events.log` and `app.out` there; `capture` and `qc-finder-watch` write PNGs there.
- A proof has three parts: the user action (the `dialog:`/`finished:` lines or the screenshot of the dialog), the resulting state (the summary line or captured dialog), and the side effect on disk. List the output files next to the input and check them with `file`, `ffprobe` or `magick identify`, not just their names.
- Drive the user path. Use `start -- files`/`send` (drop, Services, Choose Files), `job` (Finder handoff) or a real right-click. Never call Converter functions, edit the jobs folder by hand, or use `Tests/main.swift` as proof of an app behavior. That harness is for converter internals (`Tests/run.sh`).
- Screenshots come from `capture`/`qc-finder-watch` only. They grab one app's windows by ID and never the desktop or other apps. Don't use full-screen `screencapture`; it leaks whatever the user has open.
- Test mode's Show skips opening Finder. Prove **Show Converted Files** by the `reveal:` line, and say that's what you checked.

## Cleanup

```bash
.claude/skills/verify/scripts/qc-session stop
```

It stops only the PID this session started (TERM, then KILL after 5 s), copies the logs into the evidence dir, deletes the session scratch (`$TMPDIR/quickconvert-verify-session`), and removes `$TMPDIR/QuickConvert-*` work folders when no QuickConvert is running. Delete input files you created yourself. Evidence is never removed.

Never `pkill QuickConvert` or `killall QuickConvert` to clean up. The user may be converting files with it. (`Tests/lifecycle.sh` does kill by name; it's a full-suite runner, not a driver for ad-hoc proofs.)

## Isolation and gotchas

- One instance at a time. macOS routes `open -a` and `quickconvert://` URLs to whichever QuickConvert is running, so a second driver or a real user conversion would mix into your session. `start` refuses when any other instance is running; wait for it to quit rather than killing it.
- The jobs folder is shared with real Finder use. `job` writes one file there, and the app deletes it on read.
- After `./build.sh` or `quickconvert setup`, Finder may need a moment (or `killall Finder`) before it shows the new extension. `qc-doctor` tells you when it's loaded.
- `build.sh` signs with your Apple Development certificate if one exists, otherwise ad-hoc. Homebrew builds are always ad-hoc. Handoff, sandboxing and the menu behave the same either way, but check `qc-doctor`'s signature line when a bug might be signing-related.

## Helpers

- `scripts/qc-session` drives one instance (usage above; run it with no arguments for help).
- `scripts/qc-doctor` is the read-only health check.
- `scripts/qc-finder-watch <out-dir> [timeout=600]` captures Finder's context menu when someone opens it.
- `scripts/wins.swift` lists windows by owner. The helpers compile it into `~/Library/Caches/QuickConvert-verify/bin/` on first use.
- Suites: `Tests/run.sh` (79 converter checks, real engines), `Tests/lifecycle.sh` (30 app checks). Run both before claiming a change is safe. This skill proves specific behaviors on the real app.
