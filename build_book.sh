#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
FMT="${1:-html}"; mkdir -p build
mapfile -t FILES < <( { [ -f README.md ] && echo README.md; \
  find . -mindepth 2 -maxdepth 2 -name '*.md' -not -path './build/*' | sed 's|^\./||' | sort -V; } )
printf '%s\n' "${FILES[@]}"
COMMON=(--from=gfm --toc --toc-depth=2 --highlight-style=tango --standalone --metadata "title=Embedded Systems Notes")
case "$FMT" in
  html) pandoc "${COMMON[@]}" "${FILES[@]}" -o build/book.html ;;
  odt)  pandoc "${COMMON[@]}" "${FILES[@]}" -o build/book.odt ;;
  pdf)  pandoc "${COMMON[@]}" --pdf-engine=xelatex -V mainfont="DejaVu Sans" -V monofont="DejaVu Sans Mono" "${FILES[@]}" -o build/book.pdf ;;
  *) echo "usage: $0 html|odt|pdf"; exit 1 ;;
esac
