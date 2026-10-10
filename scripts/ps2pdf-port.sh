#!/bin/bash
# Port for the "Revit PDF" printer in the bottle: Wine pipes the PostScript job to stdin
# (HKCU\Software\Wine\Printing\Spooler "REVITPDF:" = "|<this script>"), we turn it into a PDF with Ghostscript.
# Output: $REVIT_PDF_DIR or ~/Documents/Revit-PDF. Without Ghostscript the .ps is saved there instead.
OUT="${REVIT_PDF_DIR:-$HOME/Documents/Revit-PDF}"; mkdir -p "$OUT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
TS="$(date +%Y%m%d-%H%M%S)-$$"
TMP="$OUT/.job-$TS.ps"
cat > "$TMP"
# Document name from the %%Title DSC comment, if Wine wrote one.
TITLE="$(LC_ALL=C grep -a -m1 '^%%Title:' "$TMP" | sed -E 's/^%%Title:[[:space:]]*\(?//; s/\)?[[:space:]]*$//; s/[^A-Za-z0-9._ -]+/_/g' | cut -c1-80)"
NAME="${TITLE:+$TITLE-}$TS"
if command -v gs >/dev/null 2>&1; then
  gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=pdfwrite -dAutoRotatePages=/None -dCompatibilityLevel=1.6 \
     -sOutputFile="$OUT/$NAME.pdf" "$TMP" 2>>"$OUT/.ps2pdf.log" && rm -f "$TMP" || mv "$TMP" "$OUT/$NAME.ps"
else
  echo "$(date) ghostscript not found, saved $NAME.ps" >>"$OUT/.ps2pdf.log"; mv "$TMP" "$OUT/$NAME.ps"
fi
