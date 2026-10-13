#!/bin/zsh
# make-protected.sh <dir>: writes password-protected fixtures (password "pw") into <dir>:
# locked.docx, locked.doc, locked.xlsx, locked.xls, locked.odt. Needs LibreOffice. The encryption runs as a
# LibreOffice macro because its bundled Python can't be launched on its own.
set -eu
D=${1:A}; SO=/Applications/LibreOffice.app/Contents/MacOS/soffice; P=$D/.lo-fixtures
printf 'Top secret memo\n' > $D/secret.txt; printf 'a,b\n1,2\n' > $D/secret.csv
$SO -env:UserInstallation=file://$P --headless --terminate_after_init >/dev/null 2>&1
mkdir -p $P/user/Scripts/python && cat > $P/user/Scripts/python/enc.py <<'PY'
import os, uno
from com.sun.star.beans import PropertyValue
def P(n, v):
    p = PropertyValue(); p.Name = n; p.Value = v; return p
def main(*args):
    desk = XSCRIPTCONTEXT.getDesktop(); b = os.environ["QC_DIR"]
    for src, dst, flt in [("secret.txt", "locked.docx", "MS Word 2007 XML"), ("secret.txt", "locked.doc", "MS Word 97"),
                          ("secret.csv", "locked.xlsx", "Calc MS Excel 2007 XML"), ("secret.csv", "locked.xls", "MS Excel 97"),
                          ("secret.txt", "locked.odt", "writer8")]:
        d = desk.loadComponentFromURL(uno.systemPathToFileUrl(b + "/" + src), "_blank", 0, (P("Hidden", True),))
        d.storeToURL(uno.systemPathToFileUrl(b + "/" + dst), (P("FilterName", flt), P("Password", "pw")))
        d.close(True)
    desk.terminate()
PY
QC_DIR=$D $SO -env:UserInstallation=file://$P --headless 'vnd.sun.star.script:enc.py$main?language=Python&location=user' >/dev/null 2>&1
rm -rf $P $D/secret.txt $D/secret.csv
