//
//  SelfTest.swift
//  EmbedBench
//
//  Does each backend actually encode meaning?
//
//  This exists because of a lesson this repo already paid for: an entire
//  session was lost chasing a "white capsule" that only existed in the
//  *instrument* used to look at it. A benchmark is an instrument. If
//  `NLEmbedding.sentenceEmbedding` degrades on 900-character chunks — it is
//  documented as a *sentence* model — it would still return vectors, the
//  benchmark would still produce a table, and the table would confidently
//  recommend the wrong backend.
//
//  So before trusting any number: paraphrases must score higher than unrelated
//  text. If a backend fails that on six hand-written pairs, nothing it says
//  about the vault is worth reading.
//

import Foundation
import Accelerate

enum SelfTest {
    /// (anchor, paraphrase, unrelated-but-same-register)
    static let triples: [(String, String, String)] = [
        ("A second brain is an external system for capturing and organising what you know, so you do not have to hold it all in memory.",
         "Personal knowledge management means keeping your ideas in a system outside your head, so recall is a matter of looking things up rather than remembering.",
         "The quarterly revenue figures exceeded forecast, driven mainly by stronger performance in the enterprise segment and favourable exchange rates."),

        ("Zettelkasten is a note-taking method built on many small, atomic notes that link to one another, so structure emerges from the connections.",
         "The slip-box approach keeps each idea on its own short note and connects them with references, letting an order appear from the links rather than a filing plan.",
         "Preheat the oven to 200°C, rub the joint with salt and rosemary, and roast for twenty minutes per kilogram before resting it under foil."),

        ("Spaced repetition schedules reviews at increasing intervals, timing each one just before the material would otherwise be forgotten.",
         "Flashcard systems that expand the gap between repetitions work because you revisit a fact right at the point it is about to slip away.",
         "The ferry departs from the eastern terminal every forty minutes and takes roughly an hour to reach the island in calm weather."),

        ("Markdown is a plain-text formatting syntax that stays readable as source, which is why notes written in it survive the tools that made them.",
         "Because a Markdown file is just text with light markup, you can still read it in any editor years later, long after the original app is gone.",
         "Cold-water immersion after training may reduce perceived soreness, though evidence for its effect on strength adaptation is mixed."),

        ("Deep work is a sustained period of undistracted concentration on a cognitively demanding task, and it is what produces genuinely difficult output.",
         "Long uninterrupted stretches of focus, with notifications off and nothing else competing, are how hard intellectual work actually gets done.",
         "Beetroot grows best in loose, stone-free soil; thin the seedlings early or the roots will crowd each other and stay small."),

        ("Version control records the history of a project so any earlier state can be recovered and the reason for each change stays attached to it.",
         "With a repository you can go back to how the files looked last Tuesday, and each commit carries a note explaining why the change was made.",
         "Sourdough needs a starter that doubles reliably; feed it twice a day at room temperature until it does before attempting a loaf."),
    ]

    /// Returns true if the backend is fit to benchmark with.
    @discardableResult
    static func run(_ embedder: Embedder) -> Bool {
        func cos(_ a: [Float], _ b: [Float]) -> Float {
            var d: Float = 0
            vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
            return d
        }

        var passes = 0
        var margins: [Float] = []
        for (anchor, paraphrase, unrelated) in triples {
            guard let a = embedder.vector(for: anchor),
                  let p = embedder.vector(for: paraphrase),
                  let u = embedder.vector(for: unrelated) else { continue }
            let near = cos(a, p), far = cos(a, u)
            margins.append(near - far)
            if near > far { passes += 1 }
        }
        let mean = margins.isEmpty ? 0 : margins.reduce(0, +) / Float(margins.count)
        let verdict = passes == triples.count ? "ok" : (passes >= triples.count - 1 ? "marginal" : "FAILS")
        print("- `\(embedder.name)` — \(passes)/\(triples.count) paraphrase pairs ranked above unrelated, "
              + "mean margin \(String(format: "%.3f", mean)) — **\(verdict)**")
        return passes >= triples.count - 1
    }
}
