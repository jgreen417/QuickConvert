# Password-protected documents

Converting a password-protected Word, Excel or OpenDocument file asks for its password. A wrong password asks again, up to three tries. Skip leaves it unconverted without an error, and the right password converts the real content. The password is never saved.

## Sub-features

- `pw-prompt` shows `“<file>” is password-protected` with a secure field, **Convert** and **Skip**.
- `pw-wrong` shows `Incorrect password for “<file>”` and asks again.
- `pw-limit` ends with a `Conversion failed` summary saying "Incorrect password" after three wrong tries.
- `pw-skip` records the file as skipped, with no error dialog.
- `pw-success` converts a correct password to the real content.

## How to get to it (user POV)

- Convert a protected `.docx`, `.doc`, `.xlsx`, `.xls` or `.odt` from any entry point.

## Driving it with qc-session

Preconditions:

- LibreOffice is installed (`qc-doctor` says "LibreOffice present").
- `Tests/make-protected.sh <dir>` has created `locked.docx`, `locked.doc`, `locked.xlsx`, `locked.xls` and `locked.odt`, all with the password `pw` and the text `Top secret memo` (spreadsheets hold `a,b / 1,2`).

- **Prompt, wrong, then right.** Run `QS start 2 QC_TEST_PASSWORDS=nope,pw -- <dir>/locked.docx`. Then `QS wait '^dialog: “locked.docx” is password-protected$'` (run `QS capture password` right after), and `QS wait '^dialog: Incorrect password for “locked.docx”$'`, then `QS wait '^finished: locked.docx ok$' 60`. `pdftotext <dir>/locked.pdf -` prints `Top secret memo`.
- **Skip.** Run `QS start 1 -- <dir>/locked.odt` with no passwords, then `QS wait '^summary: converted=0 failed=0 cancelled=0 skipped=1$' 60`. The log has no `dialog: Conversion failed`.
- **Three wrong tries.** Run `QS start 1 QC_TEST_PASSWORDS=a,b,c -- <dir>/locked.xlsx`, then `QS wait '^dialog: Conversion failed$' 90`. `grep -c '^dialog: Incorrect password' events.log` is `2`, and no new PDF exists.
- **Other targets.** Use `QS job txt <dir>/locked.doc` with `QC_TEST_PASSWORDS=pw`. `locked.txt` contains `Top secret memo`, not binary noise.

## Gotchas

- Each attempt starts a private LibreOffice instance, so allow 60–90 s per scenario.
- Without LibreOffice, protected files fail with "Install LibreOffice to convert protected documents" and no prompt. That path is covered in `Tests/run.sh` (`QC_NO_OFFICE=1`).
- Passwords must never appear in `events.log`, `app.out` or error text. Grep the evidence for the password you used.
