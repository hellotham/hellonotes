#!/bin/bash
#
#  render-parity.sh — does Edit still render what Preview renders?
#
#  Lays the same note out in TextKit and in WebKit, offscreen, and compares
#  where every block landed. Sweeps the text-size range the app offers (0.8×…
#  1.5× of the 16pt base) and a pane narrow enough that nearly every paragraph
#  wraps, because both axes have caught real drift.
#
#  Not a unit test, because it cannot be one: a WKWebView will not start its
#  content process under XCTest or `swift test`, so every load hangs there. An
#  ordinary executable renders fine. See docs/implemented.md §23.
#
set -u
cd "$(dirname "$0")/.." || exit 1

BASES=(12.8 14.4 16 20 24)
WIDTHS=(420 800 1200)
status=0

for base in "${BASES[@]}"; do
  for width in "${WIDTHS[@]}"; do
    out=$(swift run --package-path Tools/RenderParity RenderParity \
            --base "$base" --width "$width" 2>&1)
    code=$?
    worst=$(printf '%s\n' "$out" | grep -E "^worst" | tr '\n' ' ')
    if [ $code -ne 0 ]; then
      status=1
      printf 'FAIL  base %-6s width %-5s %s\n' "$base" "$width" "$worst"
      printf '%s\n' "$out" | sed -n '/^block/,/^worst per-block/p'
    else
      printf 'ok    base %-6s width %-5s %s\n' "$base" "$width" "$worst"
    fi
  done
done

if [ $status -ne 0 ]; then
  echo
  echo "Edit and Preview have drifted apart. Both are laid out from"
  echo "MarkdownCore/GFMBoxMetrics.swift — a change to one side of it needs the other."
fi
exit $status
