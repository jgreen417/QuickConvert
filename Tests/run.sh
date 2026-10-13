#!/bin/zsh
# End-to-end tests for the converter: real engines, generated fixtures, in a throwaway folder.
# Usage: Tests/run.sh   (needs the same Homebrew tools as the app; Office tests skip without LibreOffice)
set -uo pipefail
ROOT="${0:A:h:h}"
W=$(mktemp -d -t qc-tests)
trap 'rm -rf "$W"' EXIT
swiftc -O -swift-version 5 "$ROOT/App/Converter.swift" "$ROOT/Shared/Formats.swift" "$ROOT/Tests/main.swift" -o "$W/qct" || exit 1
mkdir "$W/f" && cd "$W/f"
pass=0; fail=0
ok()  { print -r -- $'\e[32mPASS\e[0m' "$1"; ((pass++)); }
bad() { print -r -- $'\e[31mFAIL\e[0m' "$1${2:+ — $2}"; ((fail++)); }
check() { local name=$1; shift; if eval "$*"; then ok "$name"; else bad "$name" "$*"; fi; }
conv() { "$W/qct" "$@" 2>&1; }
codecs() { ffprobe -v error -show_entries stream=codec_type,codec_name -of csv=p=0 "$1" | tr '\n' ' '; }
ftype() { file -b "$1"; }

# Fixtures
magick -size 64x48 plasma:fractal -depth 8 photo.png
magick photo.png shot.jpg; magick photo.png shot.heic
magick -delay 20 -size 32x32 xc:red xc:lime xc:blue anim.gif; magick anim.gif anim.webp
magick -size 4x4 xc:red dot.png
printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="40"><image xlink:href="dot.png" width="40" height="40"/></svg>' > ref.svg
printf '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><circle cx="20" cy="20" r="18" fill="orange"/></svg>' > icon.svg
magick -size 100x100 xc:red xc:lime xc:blue doc.pdf
ffmpeg -loglevel error -f lavfi -i testsrc=d=2:s=320x240:r=24 -f lavfi -i sine=d=2 -shortest -c:v libx264 -pix_fmt yuv420p -c:a aac clip.mov
ffmpeg -loglevel error -f lavfi -i testsrc=d=1:s=321x241:r=24 -c:v png odd.mov
ffmpeg -loglevel error -f lavfi -i testsrc=d=1:s=160x120 -f lavfi -i sine=d=1:f=440 -f lavfi -i sine=d=1:f=880 \
  -f srt -i <(printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n') -map 0 -map 1 -map 2 -map 3 -c:v libx264 -c:a aac -c:s srt multi.mkv
ffmpeg -loglevel error -f lavfi -i sine=d=1 -i dot.png -map 0 -map 1 -c:a libmp3lame -c:v png -disposition:v attached_pic art.mp3
ffmpeg -loglevel error -f lavfi -i sine=d=1 -c:a pcm_s24le hires.wav
printf 'Hello from QuickConvert\n' > memo.txt
printf '<p>Hi <b>there</b></p>' > page.html
printf 'a,b\n1,2\n' > sheet.csv

print "— Images"
for t in jpg webp heic avif gif tiff bmp ico pdf; do
  out=$(conv $t "$PWD/photo.png"); check "png → $t" '[[ $out == *"-> OK photo.$t"* && -s photo.$t ]]'
done
check "png → webp is lossless" '[[ $(magick compare -metric AE photo.png photo.webp null: 2>&1) == 0* ]]'
check "jpeg quality 95"        '[[ $(magick identify -format %Q photo.jpg) == 95 ]]'
conv jpg "$PWD/shot.heic" >/dev/null; check "heic → jpg" '[[ $(ftype "shot 2.jpg") == JPEG* ]]'
mkdir a && cp anim.webp a/
conv png "$PWD/a/anim.webp" >/dev/null
check "animated webp → png writes one file" '[[ $(ls a | wc -l | tr -d " ") == 2 && -s a/anim.png ]]'
mkdir g && cp anim.gif g/; conv webp "$PWD/g/anim.gif" >/dev/null
check "gif → webp keeps animation"  '[[ $(magick identify g/anim.webp | wc -l | tr -d " ") == 3 ]]'

print "— SVG"
conv png "$PWD/icon.svg" >/dev/null; check "svg → png (2x)" '[[ $(magick identify -format %wx%h icon.png) == 80x80 ]]'
conv pdf "$PWD/icon.svg" >/dev/null; check "svg → pdf"       '[[ $(ftype icon.pdf) == PDF* ]]'
conv png "$PWD/ref.svg"  >/dev/null; center=$(magick ref.png -format '%[fx:int(255*p[40,40].r)],%[fx:int(255*p[40,40].g)]' info:)
check "svg relative image resolves" '[[ $center == 255,0 ]]'

print "— PDF"
out=$(conv png "$PWD/doc.pdf" "$PWD/doc.pdf" "$PWD/doc.pdf")
check "3 concurrent pdf jobs → 9 distinct pages" '[[ $(ls doc*-*.png | wc -l | tr -d " ") == 9 ]]'
conv jpg "$PWD/doc.pdf" >/dev/null; check "pdf → jpg pages" '[[ -s doc-1.jpg && -s doc-3.jpg ]]'

print "— Video"
out=$(conv mp4 "$PWD/clip.mov")
check "mov → mp4 copies streams bit-exact" '[[ "$(ffmpeg -loglevel error -i clip.mov -map 0:v -c copy -f md5 -)" == "$(ffmpeg -loglevel error -i clip.mp4 -map 0:v -c copy -f md5 -)" ]]'
check "video progress reported" '[[ $out == *"[progress 100%]"* ]]'
conv mp4 "$PWD/odd.mov" >/dev/null; check "odd-size video re-encodes" '[[ $(codecs odd.mp4) == *h264,video* ]]'
conv webm "$PWD/clip.mov" >/dev/null; check "mov → webm" '[[ $(codecs clip.webm) == *vp9* && $(codecs clip.webm) == *opus* ]]'
conv mkv  "$PWD/clip.mov" >/dev/null; check "mov → mkv" '[[ -s clip.mkv ]]'
conv gif  "$PWD/clip.mov" >/dev/null; check "mov → gif" '[[ $(ftype clip.gif) == GIF* ]]'
conv mp3  "$PWD/clip.mov" >/dev/null; check "mov → mp3 (audio only)" '[[ $(codecs clip.mp3) == "mp3,audio " ]]'
conv mp4 "$PWD/multi.mkv" >/dev/null; conv webm "$PWD/multi.mkv" >/dev/null
check "mkv → mp4 keeps 2 audio + subtitle"  '[[ $(codecs multi.mp4 | grep -o audio | wc -l | tr -d " ") == 2 && $(codecs multi.mp4) == *subtitle* ]]'
check "mkv → webm keeps 2 audio + subtitle" '[[ $(codecs multi.webm | grep -o audio | wc -l | tr -d " ") == 2 && $(codecs multi.webm) == *subtitle* ]]'

print "— Audio"
conv m4a "$PWD/art.mp3" >/dev/null; check "mp3+art → m4a keeps art" '[[ $(codecs art.m4a) == *aac,audio* && $(codecs art.m4a) == *video* ]]'
conv ogg "$PWD/art.mp3" >/dev/null; check "mp3+art → ogg"           '[[ $(codecs art.ogg) == "opus,audio " ]]'
for t in wav flac aac opus aiff; do conv $t "$PWD/art.mp3" >/dev/null; check "mp3 → $t" '[[ -s art.$t ]]'; done
conv flac "$PWD/hires.wav" >/dev/null; conv aiff "$PWD/hires.wav" >/dev/null
check "24-bit wav → flac stays 24-bit" '[[ $(ffprobe -v error -show_entries stream=bits_per_raw_sample -of csv=p=0 hires.flac) == 24 ]]'

print "— Documents"
for t in docx doc odt rtf html; do conv $t "$PWD/memo.txt" >/dev/null; check "txt → $t" '[[ -s memo.$t ]]'; done
conv txt "$PWD/page.html" >/dev/null; check "html → txt" '[[ $(cat page.txt) == *"Hi there"* ]]'
if [[ -x /Applications/LibreOffice.app/Contents/MacOS/soffice ]]; then
  out=$(conv pdf "$PWD/memo.txt" "$PWD/memo.txt")
  check "txt → pdf ×2 concurrent (LibreOffice)" '[[ $(ftype memo.pdf) == PDF* && $(ftype "memo 2.pdf") == PDF* ]]'
  conv xlsx "$PWD/sheet.csv" >/dev/null; check "csv → xlsx" '[[ $(ftype sheet.xlsx) == *Excel* ]]'
  conv pdf "$PWD/memo.docx" >/dev/null; check "docx → pdf" '[[ $(ftype memo.pdf) == PDF* ]]'
  conv ods "$PWD/sheet.xlsx" >/dev/null; check "xlsx → ods" '[[ -s sheet.ods ]]'
  /Applications/LibreOffice.app/Contents/MacOS/soffice -env:UserInstallation=file://$W/lo --headless \
    --convert-to 'pdf:writer_pdf_Export:{"EncryptFile":{"type":"boolean","value":"true"},"DocumentOpenPassword":{"type":"string","value":"pw"}}' --outdir "$PWD/enc" memo.txt >/dev/null 2>&1
  out=$(conv png "$PWD/enc/memo.pdf"); check "password-protected pdf fails clearly" '[[ $out == *"password-protected"* && -z $(ls enc | grep png) ]]'
else
  print "skip LibreOffice tests (not installed)"
fi

print "— Safety"
cp photo.png 'pct%03d.png'; magick -size 8x8 xc:blue pct000.png; echo SENTINEL > pct000.jpg
out=$(conv jpg "$PWD/pct%03d.png")
check "%-pattern name converts literally"  '[[ -s "pct%03d.jpg" ]]'
check "…and never touches pct000.jpg"      '[[ $(cat pct000.jpg) == SENTINEL ]]'
cp photo.png private.png; chmod 600 private.png; conv jpg "$PWD/private.png" >/dev/null
check "0600 source → 0600 output" '[[ $(stat -f %Lp private.jpg) == 600 ]]'
out=$(conv docx "$PWD/missing.txt");  check "missing input fails, writes nothing" '[[ $out == *ERR* && ! -e missing.docx ]]'
mkfifo pipe.png; out=$(conv jpg "$PWD/pipe.png"); check "named pipe rejected" '[[ $out == *"Not a regular file"* && ! -e pipe.jpg ]]'
out=$(conv docx "$PWD/doc.pdf");      check "invalid pair rejected" '[[ $out == *"Can'"'"'t convert"* ]]'
printf 'not really a png' > broken.png; out=$(conv jpg "$PWD/broken.png")
check "corrupt input fails, writes nothing" '[[ $out == *ERR* && ! -e broken.jpg ]]'
echo "x" > same.png; magick -size 8x8 xc:red same.png; magick -size 8x8 xc:red same.jpg
conv jpg "$PWD/same.png" >/dev/null; check "existing output is never replaced" '[[ -s "same 2.jpg" ]]'
check "no staging dirs left behind" '[[ -z "$(find ${TMPDIR:-/tmp} -maxdepth 1 -name "QuickConvert-*" 2>/dev/null)" ]]'

print "\n$pass passed, $fail failed"
exit $(( fail > 0 ))
