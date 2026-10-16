# "Revit PDF": a printer in the bottle that saves PDFs to ~/Documents/Revit-PDF through Ghostscript on the Mac.
ADDIN_NAME="PDF printer"
ADDIN_ABOUT="Print to PDF into Documents/Revit-PDF (needs Ghostscript)"
ADDIN_TESTED=(2020 2023 2024 2025)   # offered for 2026 too, not tested there yet
ADDIN_EULA=""
ADDIN_AFTER=()
ADDIN_TOOL=gs
ADDIN_STEP=pdfprinter
addin_files() { case "$1" in 2020|2023|2024|2025|2026) printf 'tool\tgs\t-\t-\n' ;; esac; }
addin_is_installed() { grep -q 'REVITPDF:' "$B/user.reg" 2>/dev/null; }
