#!/usr/bin/env python3
"""Render a TDCommons defensive-publication source .md into the article-body PDF.

Pipeline: pandoc (gfm -> html5) -> headless Chrome (html -> pdf). Mirrors the
patents/ builder house style (12pt Times, 1.5 line spacing, Letter portrait).

Before rendering it strips the leading **submission-note blockquote** (the
`> Prepared for submission ... / DRAFT / Posted ...` block right after the
`**Author:**` line) so the uploaded PDF carries no internal note — exactly what
`docs/tdcommons/SUBMISSION_GUIDE.md` says to do before upload.

Usage:
    python3 scripts/render_tdcommons_pdf.py docs/PRIOR_ART_FOO_TDCOMMONS.md foo_tdcommons.pdf

The PDF is written into docs/tdcommons/<output-name>. macOS-only (hardcoded
Chrome path, same as the patents builder).
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "docs" / "tdcommons"
TMP = Path("/tmp/tdcommons_pdf_temp")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
<style>
@page { size: letter portrait; margin: 2.0cm 2.0cm 2.0cm 2.5cm; }
html, body { margin: 0; padding: 0; font-family: "Times New Roman", Times, serif;
  font-size: 12pt; line-height: 1.5; color: #000; }
h1, h2, h3, h4 { font-family: "Times New Roman", Times, serif; font-weight: bold;
  page-break-after: avoid; }
h1 { font-size: 16pt; text-align: center; margin: 0 0 16pt 0; }
h2 { font-size: 14pt; margin: 18pt 0 6pt 0; }
h3 { font-size: 13pt; margin: 14pt 0 5pt 0; }
p { margin: 0 0 8pt 0; text-align: justify; }
ul, ol { margin: 4pt 0 8pt 0; padding-left: 24pt; }
li { margin-bottom: 4pt; }
blockquote { margin: 8pt 0; padding-left: 12pt; border-left: 2px solid #888; color: #333; }
table { border-collapse: collapse; margin: 8pt 0; font-size: 11pt; }
th, td { border: 1px solid #000; padding: 3pt 6pt; text-align: left; }
code { font-family: "Courier New", monospace; font-size: 11pt; }
hr { border: none; border-top: 1px solid #000; margin: 12pt 0; }
</style>
"""

SUBMISSION_NOTE = re.compile(
    r"(\*\*Author:\*\*[^\n]*\n)\n(?:>[^\n]*\n)+", re.MULTILINE
)


def strip_note(md: str) -> str:
    """Remove the submission-note blockquote that follows the Author line."""
    return SUBMISSION_NOTE.sub(r"\1", md, count=1)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src = (REPO / sys.argv[1]).resolve()
    out_pdf = OUT_DIR / sys.argv[2]
    if not src.exists():
        sys.exit(f"source not found: {src}")

    TMP.mkdir(exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    cleaned = strip_note(src.read_text())
    md_tmp = TMP / src.name
    md_tmp.write_text(cleaned)

    fragment = subprocess.run(
        ["pandoc", "-f", "gfm", "-t", "html5", str(md_tmp)],
        capture_output=True, text=True, check=True,
    ).stdout

    html_tmp = TMP / (src.stem + ".html")
    html_tmp.write_text(
        f'<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n'
        f"<title>{src.stem}</title>\n{CSS}\n</head>\n<body>\n{fragment}\n</body>\n</html>\n"
    )

    subprocess.run([
        CHROME, "--headless", "--disable-gpu", "--no-pdf-header-footer",
        f"--print-to-pdf={out_pdf}", f"file://{html_tmp}",
    ], capture_output=True, check=True)

    if not out_pdf.exists():
        sys.exit(f"FAILED to render {out_pdf}")

    info = subprocess.run(["pdfinfo", str(out_pdf)], capture_output=True, text=True)
    pages = next((l.split(":", 1)[1].strip()
                  for l in info.stdout.splitlines() if l.startswith("Pages")), "?")
    print(f"-> {out_pdf.relative_to(REPO)} | {out_pdf.stat().st_size:,} bytes | {pages} pages")


if __name__ == "__main__":
    main()
