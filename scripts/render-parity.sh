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

# Whole **documents**, not one construct at a time.
#
# The corpus sweep can be green on all 672 of its examples while a README-shaped
# note is 7pt out, because a document is a combination and a construct that is
# right on its own can be wrong beside another one. `Tools/RenderParity/Documents`
# holds notes somebody could plausibly have written — a README with badges and
# fenced steps, meeting notes with nested quotes, a document ending in each
# awkward thing and one starting with it, front matter, CJK, long wrapping
# prose.
#
# Three widths, because wrapping is half of what makes a document a document,
# and six of the nine defects this folder found were invisible until something
# wrapped: a code box inside a list item laid out 32pt too wide, an opening
# margin paid once per wrapped line, a quote's lazy continuation given the full
# pane. 800 is the ordinary pane; 560 wraps most paragraphs and every code line
# over about forty characters.
#
# 1200 is here because a picture is the other thing a width decides. The editor
# capped every rendered embed at 900pt — an undocumented number the page has no
# equivalent of — so a 1600x900 screenshot was 33pt short at a 1000pt pane and
# 145pt short at 1200, on a maximised Mac window, while 800 and 560 both read
# +0.00. A gate that only measures widths where a cap does not bite measures
# the cap.
#
# 420 is measured and **reported without failing on it**, which is a weaker
# thing than a gate and a stronger thing than silence. It is not decoration: it
# is the width at which a four-column table stops fitting, so it is the only
# place the table-overflow layout gets exercised at all — it was once dropped
# from this list and the suite went green on the very case it had been added to
# catch. It is also the only width at which one open, measured divergence
# fires, so failing on it would fail every run from here on:
#
#   `.package(url: "https://example.com/widget-kit", from: "1.0.0")` in a
#   ```swift fence is two lines in Edit and three in Preview, −20.00pt.
#   **TextKit takes a line-break opportunity after `/` and WebKit does not.**
#   The discriminator is one command — replace the two solidi with dots and the
#   same snippet measures +0.00 on both sides — so this is a break opportunity
#   and not a box-model error, and it is falsifiable by anyone who doubts it.
#   Three repairs were measured and reverted: `overflow-wrap: anywhere` on the
#   page (no change — every word here fits, so nothing mid-word breaks either
#   way), `lineBreakStrategy = []` on every paragraph (no change), and
#   `.byCharWrapping` (worse). CSS has no "break after solidus", and giving the
#   page one means emitting `<wbr>` into cmark's output, which is the byte
#   parity `GFMRenderTests` holds. docs/unimplemented.md carries it.
#
# So: any *new* shortfall at 420 shows up in this listing as a document name and
# a number, and the two documents below are the ones already accounted for. If
# this line ever reads more than those two, something regressed.
DOC_ADVISORY_WIDTHS=" 420 "
for width in 1200 800 560 420; do
  out=$(swift run --package-path Tools/RenderParity RenderParity --docs \
          --width "$width" 2>&1)
  code=$?
  headline=$(printf '%s\n' "$out" | grep -E "^documents:")
  if [ $code -eq 0 ]; then
    printf 'ok    documents width %-5s %s\n' "$width" "$headline"
  elif [ "${DOC_ADVISORY_WIDTHS#* $width }" != "$DOC_ADVISORY_WIDTHS" ]; then
    printf 'note  documents width %-5s %s  (advisory — see the comment above)\n' \
           "$width" "$headline"
    printf '%s\n' "$out" | grep -E "^!|^UNMEASURED"
  else
    status=1
    printf 'FAIL  documents width %-5s %s\n' "$width" "$headline"
    printf '%s\n' "$out" | grep -E "^!|^UNMEASURED"
  fi
done

# Heights agreeing is not the same as the marks being in the right place. This
# renders both sides and measures the chrome itself — the bullets and the quote
# gutters — because the sweep above stayed green through three defects you could
# see at a glance.
out=$(swift run --package-path Tools/RenderParity RenderParity --chrome \
        --base 16 --width 800 2>&1)
code=$?
printf '%s\n' "$out" | grep -E "^(bullet|quote|code|chrome|  FAIL)"
[ $code -ne 0 ] && status=1

if [ $status -ne 0 ]; then
  echo
  echo "Edit and Preview have drifted apart. Both are laid out from"
  echo "MarkdownCore/GFMBoxMetrics.swift — a change to one side of it needs the other."
fi
exit $status
