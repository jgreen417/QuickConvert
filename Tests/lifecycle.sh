#!/bin/zsh
# Lifecycle tests for the installed app: dialogs, jobs arriving mid-dialog, idle quit, rejected requests.
# Launches QuickConvert in test mode (open --env), where every dialog is logged and auto-answered after
# a dwell time while still running as a real modal session. Usage: Tests/lifecycle.sh (after ./build.sh)
set -uo pipefail
HERE=${0:A:h}
APP=~/Applications/QuickConvert.app
W=$(mktemp -d -t qc-life)
trap 'pkill -x QuickConvert; rm -rf "$W"' EXIT
LOG=$W/events.log
pass=0; fail=0
ok()  { print -r -- $'\e[32mPASS\e[0m' "$1"; ((pass++)); }
bad() { print -r -- $'\e[31mFAIL\e[0m' "$1"; print -r -- "      log: $(tr '\n' '|' < $LOG 2>/dev/null)"; ((fail++)); }
check() { local name=$1; shift; if eval "$*"; then ok "$name"; else bad "$name"; fi; }

start() { # start <dwell> [open args...]: fresh instance in test mode
  pkill -x QuickConvert; while pgrep -x QuickConvert >/dev/null; do sleep 0.2; done
  : > $LOG
  open -n -a $APP ${=QC_ARCH:+--arch $QC_ARCH} --env QC_TEST_DWELL=$1 --env QC_TEST_LOG=$LOG ${=EXTRA_ENV:-} "${@:2}"
}
send() { open -a $APP "$@"; }                               # deliver to the running instance
wait_for() { for _ in {1..300}; do grep -q -- "$1" $LOG 2>/dev/null && return 0; sleep 0.1; done; return 1; }
wait_quit() { wait_for '^quit$' && { for _ in {1..30}; do pgrep -x QuickConvert >/dev/null || return 0; sleep 0.1; done; return 1; }; }
before() { local a b; a=$(grep -n -m1 -- "$1" $LOG | cut -d: -f1); b=$(grep -n -m1 -- "$2" $LOG | cut -d: -f1); [[ -n $a && -n $b && $a -lt $b ]]; }

cd $W
magick -size 64x48 plasma:fractal -depth 8 photo.png; cp photo.png second.png; cp photo.png third.png
printf 'not an image' > broken.png
ffmpeg -loglevel error -f lavfi -i testsrc2=d=30:s=1920x1080:r=30 -c:v prores big.mov
ffmpeg -loglevel error -f lavfi -i sine=d=1 song.mp3
mkdir many && for i in {1..501}; do cp photo.png many/p$i.png; done
mkdir prot && "$HERE/make-protected.sh" prot

print "— Plain launch shows the welcome dialog, then quits"
start 1
check "running as ${QC_ARCH:-$(uname -m)}"   'wait_for "^launch ${QC_ARCH:-$(uname -m)}$"'
check "welcome shown and closed" 'wait_for "^closed: QuickConvert$"'
check "quits after welcome"      'wait_quit'

print "— A job arriving while the welcome dialog is open"
start 6
wait_for "^dialog: QuickConvert$"; sleep 1; send photo.png
check "picker opens on top of welcome"       'wait_for "^dialog: Convert photo.png$"'
check "job runs while welcome still open"    'wait_for "^finished: photo.png ok$" && [[ -s photo.jpg ]]'
check "app waits for both, then quits"       'wait_quit && before "^finished: photo.png" "^quit$" && before "^closed: QuickConvert$" "^quit$"'

print "— A job arriving while a failure alert is open"
start 4 broken.png
check "failure alert shown"                  'wait_for "^dialog: Conversion failed$"'
sleep 1; send second.png
check "new job runs during the alert"        'wait_for "^finished: second.png ok$" && [[ -s second.jpg ]]'
check "quits only after alert and job"       'wait_quit && before "^finished: second.png" "^quit$" && before "^closed: Conversion failed$" "^quit$"'
check "broken input left nothing behind"     '[[ ! -e broken.jpg ]]'

print "— A long job keeps the app alive (and videos default to MP4)"
start 0.5 big.mov
wait_for "^closed: Convert big.mov$"; sleep 3
check "still running mid-conversion"         'pgrep -x QuickConvert >/dev/null && ! grep -q "^finished: big.mov" $LOG'
check "finishes, then quits"                 'wait_for "^finished: big.mov ok$" && wait_quit && [[ -s big.mp4 ]]'

print "— Cancel All mid-conversion"
rm -f big.mp4
EXTRA_ENV="--env QC_TEST_CANCEL_AFTER=3" start 0.5 big.mov
check "job reports cancelled, no error dialog" 'wait_for "^finished: big.mov cancelled$" && ! grep -q "^dialog: Conversion failed" $LOG'
check "ffmpeg stopped, nothing written"        'wait_quit && ! pgrep -f "QuickConvert-.*/src/in.mov" >/dev/null && [[ ! -e big.mp4 ]]'
check "staging cleaned up"                     '[[ -z "$(find ${TMPDIR:-/tmp} -maxdepth 1 -name "QuickConvert-*" 2>/dev/null)" ]]'

print "— Password-protected documents"
EXTRA_ENV="--env QC_TEST_PASSWORDS=nope,pw" start 1 prot/locked.docx
check "asks for the password"                 'wait_for "^dialog: “locked.docx” is password-protected$"'
check "wrong password → asks again"           'wait_for "^dialog: Incorrect password for “locked.docx”$"'
check "right password → converted"            'wait_for "^finished: locked.docx ok$" && wait_quit && [[ "$(pdftotext prot/locked.pdf - 2>/dev/null)" == *"Top secret memo"* ]]'
check "no error dialog along the way"         '! grep -q "^dialog: Conversion failed" $LOG'
EXTRA_ENV="--env QC_TEST_PASSWORDS=a,b,c" start 1 prot/locked.xlsx
check "3 wrong passwords → stops with error"  'wait_for "^dialog: Conversion failed$" && wait_quit && [[ $(grep -c "^dialog: Incorrect password" $LOG) == 2 && ! -e "prot/locked 2.pdf" ]]'

print "— Requests that must do nothing"
start 1 "quickconvert://job/$(uuidgen)"
check "forged job id: no dialog, quits"      'wait_quit && ! grep -q "^dialog" $LOG'
start 1 "quickconvert://convert?to=jpg&f=$W/third.png"
check "old-style path URL: nothing written"  'wait_quit && [[ ! -e third.jpg ]] && ! grep -q "^dialog" $LOG'

print "— Rejections with a clear dialog"
start 1 photo.png song.mp3
check "image + audio: 'Nothing to convert'"    'wait_for "^dialog: Nothing to convert$" && wait_quit'
start 1 many/*.png
check "over 500 files: 'Too many files'"     'wait_for "^dialog: Too many files$" && wait_quit && [[ -z "$(ls many | grep jpg)" ]]'

print "\n$pass passed, $fail failed"
exit $(( fail > 0 ))
