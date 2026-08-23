//
//  PaintedContent.swift
//  GFMRender
//
//  Where a rendered page's ink stops — one description of it, for everything
//  that has to agree about the bottom of a document.
//
//  Two callers, and they used to answer it differently. `RenderParity` asks it
//  of the whole note, to score Edit against Preview. `HTMLBlockImageRenderer`
//  asks it of one raw HTML block, to decide how tall the editor's collapsed
//  embed of that block should be — and it used to ask a *different* question,
//  `.markdown-body`'s border box, which is the same number only while nothing
//  empty is parked at the end. A `<tr>` whose cells became an indented code
//  block leaves an empty `<table>` behind exactly there: the page's ink stops
//  at the listing, the border box runs 16pt further, and the editor reserved
//  the difference under a note that ends in blank space (spec #160).
//
//  It lives here, beside `GFMRenderer.page`, because it is a property of the
//  page that function emits: change the stylesheet and this is what has to
//  change with it.
//

import Foundation

/// The rule for "how far down this page does anything actually get drawn".
public enum PaintedContent {

    /// A JavaScript function `paintedContentBottom(b)`, to be pasted into a
    /// script evaluated in a page `GFMRenderer.page` produced. It returns the
    /// distance from the top of `b`'s content box to the bottom of the lowest
    /// thing the page paints, in CSS pixels.
    ///
    /// **Not** `scrollHeight - paddingTop - paddingBottom`, and not the
    /// element's border box either. On a well-formed page all three agree to
    /// within WebKit's integer rounding, because github-markdown-css zeroes
    /// `.markdown-body > *:last-child`'s `margin-bottom` and nothing sits
    /// below the last box — which is exactly why the wrong one looked right
    /// for so long. The moment an example leaves a tag open, the `<p>` that
    /// gets re-parented into it is no longer that last child: its 16pt bottom
    /// margin survives, collapses out through the unclosed element and is
    /// stopped only by the article's own padding — 16pt of page that nothing
    /// draws in. The editor's own answer is the bottom of its lowest layout
    /// fragment, a *content* bottom: TextKit drops the last paragraph's
    /// `paragraphSpacing` for the same reason CSS zeroes that margin, because
    /// nothing paints there.
    ///
    /// Three details the walk cannot skip:
    /// - A box of zero height paints nothing. An empty `<p>` — or an empty
    ///   `<table>` — parked after the last visible box must not push the answer
    ///   down by the margin above it.
    /// - An **inline** box is not a line box and must not be measured as one. A
    ///   `<code>` span carries `.2em` of vertical padding and a background, so
    ///   its border box hangs 2.72pt below the glyphs — but *inside* the 24pt
    ///   line box its block already accounts for. Counting it charged the
    ///   editor a point on three examples where both engines drew the same
    ///   single line.
    /// - A text run whose nearest block ancestor is the article itself — the
    ///   tagfilter escapes an unclosed `<style>` into one, and an example that
    ///   leaves a raw tag open leaves others — is laid out in an **anonymous**
    ///   block box that no element walk can reach. Its `Range` rect is the
    ///   glyph box, so the bottom half-leading CSS centres it with has to be
    ///   added back; the tempting alternative, appending a zero-height block
    ///   and reading where it lands, silently moves the answer 16pt down,
    ///   because the probe takes over `.markdown-body > *:last-child` and hands
    ///   the paragraph above it back the margin that rule was zeroing.
    public static let bottomJS = """
    function paintedContentBottom(b) {
      var cs = getComputedStyle(b);
      var origin = b.getBoundingClientRect().top + parseFloat(cs.paddingTop);
      var bottom = origin, strut = parseFloat(cs.lineHeight);
      function note(v) { if (v > bottom) bottom = v; }
      function inlineLevel(el) {
        var d = getComputedStyle(el).display;
        return d.lastIndexOf('inline', 0) === 0 || d === 'contents';
      }
      var all = b.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        if (inlineLevel(all[i])) continue;
        var r = all[i].getBoundingClientRect();
        if (r.height > 0) note(r.bottom);
      }
      var walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT, null), t;
      while ((t = walker.nextNode())) {
        if (!t.nodeValue.trim()) continue;
        var anonymous = true;
        for (var p = t.parentNode; p && p !== b; p = p.parentNode) {
          if (p.nodeType !== 1 || !inlineLevel(p)) { anonymous = false; break; }
        }
        if (!anonymous) continue;
        var lh = parseFloat(getComputedStyle(t.parentElement).lineHeight);
        if (!isFinite(lh) || lh < strut) lh = strut;
        var rg = document.createRange();
        rg.selectNodeContents(t);
        var rects = rg.getClientRects();
        for (var j = 0; j < rects.length; j++) {
          if (rects[j].height <= 0) continue;
          note(rects[j].bottom + Math.max(0, (lh - rects[j].height) / 2));
        }
      }
      return Math.max(0, bottom - origin);
    }
    """
}
