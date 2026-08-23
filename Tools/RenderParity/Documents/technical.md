---
title: Notes on layout
tags: [layout, textkit]
---

# Notes on layout

<!-- No `$…$` or `$$…$$` here on purpose. LaTeX is not GFM: it is in no version
     of the spec, cmark-gfm does not know it, and the corpus has no example of
     it. Edit renders it with SwiftMath and Preview shows the literal `$$`, which
     is a real divergence and a real bug — recorded in docs/unimplemented.md —
     but it is an app-feature gap rather than a conformance failure, and this
     gate cannot even measure it: the harness's editor side has no math renderer
     either, so both of its sides are fallbacks. Putting it here would make the
     document gate permanently red for something it is not testing. -->

The box model is shared, so both engines measure from one table[^1].

[^1]: `GFMBoxMetrics.swift`.

An image by reference: ![diagram][fig1]

[fig1]: train.jpg "A train"

<div align="center">
  <b>Centred</b>
</div>

Ordinary text after the block.
