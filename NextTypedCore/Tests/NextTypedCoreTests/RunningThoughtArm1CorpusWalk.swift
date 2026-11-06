import Testing
import Foundation
@testable import NextTypedCore

/// **Refusal-rate walk** — how often arm 1 of `RunningThoughtGate` refuses, across many
/// independent carets, split by the two dials that were chosen by argument
/// (the dials had never been measured).
///
/// **Why this is a Core walk and not a harness scenario.** `hasRunningThought(textBeforeCaret:)` is a
/// pure function of a `String` — no model, no `TypingContext`, no host — so the rate is arithmetic
/// over a corpus. The harness exists for behaviour that appears only in a real host,
/// and gate arithmetic is not that. Driving TextEdit to compute it would be slower, more fragile and
/// no more truthful.
///
/// **What it does not do.** It emits no verdict and moves no threshold. It produces the denominator
/// (the earlier analysis had none) and, on request, the sample that
/// the offline probe runs the real model at. Whether a given refusal cost the user
/// anything stays a human judgement.
///
/// **The trap this file exists because of.** The 2026-08-30 `quality-baseline` run recorded *zero*
/// arm-1 firings: after the narrowing the arm engages only at a **structural**
/// sentence start, and those chains all began mid-paragraph. An instrument that reports a rate while
/// never reaching the condition it measures is this project's recurring bug, so the walk reports its
/// carets **by origin branch** and asserts that both structural branches are non-empty. A run that
/// only visited mid-paragraph carets fails here rather than printing a reassuring zero.
///
/// **Opt-in**, on the `PredictPathScanCostBenchmark` precedent: a corpus measurement is not a
/// behaviour assertion, so it runs only under its own environment variable and is compiled with the
/// suite regardless, so it cannot rot.
///
/// ```
/// NEXTTYPED_ARM1_WALK=1 swift test --filter RunningThoughtArm1CorpusWalk
/// NEXTTYPED_ARM1_WALK=1 NEXTTYPED_ARM1_WALK_SAMPLE=/tmp/arm1-refusals.tsv \
///     swift test --filter RunningThoughtArm1CorpusWalk
/// ```
@Suite struct RunningThoughtArm1CorpusWalk {

    /// Written for this repository, licence-clean, and deliberately weaker than a split-author asset:
    /// no author identity, no ground-truth middles.
    static var corpusRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NextTypedCoreTests
            .deletingLastPathComponent()    // Tests
            .appendingPathComponent("Corpora/running-thought")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXTTYPED_ARM1_WALK"] != nil))
    func arm1RefusalRateAcrossManyCarets() throws {
        var sampleRows: [String] = []
        var languagesWalked = 0

        for language in ["en", "de"] {
            let directory = Self.corpusRoot.appendingPathComponent(language)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "txt" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

            // Reporting a missing input beats measuring nothing and passing (the walk's own version
            // of `probe_fim.py`'s corpus help).
            guard !files.isEmpty else {
                Issue.record("""
                    No corpus found under \(directory.path).
                    Expected plain UTF-8 prose with real paragraph structure, one or more `*.txt`
                    files per language. See Corpora/running-thought/README.md.
                    """)
                continue
            }
            languagesWalked += 1

            var report = Report(language: language.uppercased())
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                report.files += 1
                report.characters += text.count
                for caret in Self.caretPositions(in: text) {
                    if caret == 0 { report.caretsAtOffsetZero += 1 }
                    let prefix = String(text.prefix(caret))
                    // The SHIPPING decision. The scan below is only the breakdown key; the pinned
                    // invariant that the two agree lives in `RunningThoughtGateTests`.
                    let refused = !RunningThoughtGate.hasRunningThought(textBeforeCaret: prefix)
                    let scan = RunningThoughtGate.currentSentence(in: prefix)
                    report.record(origin: scan.origin, words: scan.wordCount, refused: refused)
                    if refused {
                        sampleRows.append(Self.row(caseID: "\(language.uppercased())/\(file.deletingPathExtension().lastPathComponent)/\(caret)",
                                                   language: language.uppercased(),
                                                   origin: scan.origin,
                                                   words: scan.wordCount,
                                                   prefix: prefix))
                    }
                }
            }
            report.print()

            // The walk reached its own subject — the assertion the 2026-08-30 zero would have failed.
            #expect(report.caretsByOrigin[.structuralBreak, default: 0] > 0,
                    "\(report.language): no structural-break caret visited — arm 1's only engagement site")
            // NOT `caretsByOrigin[.documentStart] > 0`: that branch is returned for every caret in a
            // file's opening sentence, so it is true of 27 carets and could not detect "offset 0 was
            // never visited" — the thing this control is supposed to prove. Count offset 0 itself.
            #expect(report.caretsAtOffsetZero == report.files,
                    "\(report.language): the caret at offset 0 was not visited in every file (\(report.caretsAtOffsetZero) of \(report.files))")
            #expect(report.carets > 200, "\(report.language): too few carets for a rate to mean anything")
            // A corpus that provokes no refusal at all is a corpus, not a finding — say so here
            // rather than letting the probe discover it with a model loaded.
            #expect(report.refusals > 0, "\(report.language): arm 1 never fired; the corpus cannot reach it")
        }

        #expect(languagesWalked == 2, "both languages must be walked for the per-language split to exist")

        if let path = ProcessInfo.processInfo.environment["NEXTTYPED_ARM1_WALK_SAMPLE"] {
            let header = "# case_id\tlang\torigin\twords\tprefix (\\n \\t \\\\ escaped)\n"
            try (header + sampleRows.joined(separator: "\n") + "\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            print("[running-thought-corpus] wrote \(sampleRows.count) refused carets to \(path)")
        }
    }

    // MARK: The caret set

    /// Every position a next-word ghost could be asked for: the document start, and the start of each
    /// whitespace-delimited **token** — an index whose preceding grapheme is whitespace and whose own
    /// grapheme is not.
    ///
    /// The second half of that condition is load-bearing and was missing in the first version: without
    /// it, every index *inside* a whitespace run is visited too, so a `"\n\n"` paragraph break
    /// contributes two carets whose flush prefixes are byte-identical after the spacing strip. That
    /// inflated the first run by 44 carets per language, **all of them arm-1 refusals**, which is a
    /// quarter of the reported refusal count — the same observation counted twice, in the cell (`0w`)
    /// where it did the most damage. A rate over non-independent positions is not a rate.
    ///
    /// Walking positions that **already exist** in the corpus is the point: nothing is typed, so
    /// nothing is manufactured, which is how the `sweep` attempt recorded in
    /// `de-chain-heterogeneous.scenario` invalidated itself by building the very copy attractor it was
    /// probing. Newlines are whitespace, so the structural starts arm 1 engages at are in the set by
    /// construction rather than by a special case.
    static func caretPositions(in text: String) -> [Int] {
        var positions = [0]                 // the document start, whatever stands there
        var index = 0
        var previousWasWhitespace = false
        for character in text {
            if previousWasWhitespace, !character.isWhitespace, index > 0 { positions.append(index) }
            previousWasWhitespace = character.isWhitespace
            index += 1
        }
        return positions
    }

    private static func row(caseID: String,
                            language: String,
                            origin: RunningThoughtGate.SentenceStartOrigin,
                            words: Int,
                            prefix: String) -> String {
        // Every `Character.isNewline` grapheme has to survive the round trip, not just LF and CR:
        // VT, FF, NEL, LS and PS are newlines to `RunningThoughtGate` and to `ClauseStop`, and an
        // unescaped one would split a TSV row in half — which `load_carets` then drops in silence.
        var escaped = ""
        for character in prefix {
            switch character {
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                // CRLF is ONE `Character` of two scalars, so escape scalar by scalar rather than
                // assuming a newline grapheme is a single code point.
                if character.isNewline {
                    for scalar in character.unicodeScalars {
                        escaped += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    escaped.append(character)
                }
            }
        }
        return "\(caseID)\t\(language)\t\(Report.name(origin))\t\(words)\t\(escaped)"
    }

    // MARK: The report

    /// Counts only. Every line is prefixed with the ticket so a run can be pasted into it verbatim.
    struct Report {
        let language: String
        var files = 0
        var characters = 0
        var carets = 0
        /// The real document-start control: how many files had their offset-0 caret visited.
        var caretsAtOffsetZero = 0
        var refusals = 0
        var caretsByOrigin: [RunningThoughtGate.SentenceStartOrigin: Int] = [:]
        var refusalsByOrigin: [RunningThoughtGate.SentenceStartOrigin: Int] = [:]
        var refusalsByWordCount: [Int: Int] = [:]
        /// The **threshold dial**: how many words the sentence holds at a structural-origin caret.
        /// Reading off `2w`, `3w`, … is what a proposal to move `minimumSentenceWords` costs.
        var structuralOriginWordCounts: [Int: Int] = [:]
        /// The **origin dial**: sentence-boundary carets holding fewer than the threshold. These are
        /// exactly the carets the narrowing handed back to the user, so this is
        /// what un-narrowing arm 1 would cost.
        var boundaryOriginBelowThreshold = 0

        mutating func record(origin: RunningThoughtGate.SentenceStartOrigin, words: Int, refused: Bool) {
            carets += 1
            caretsByOrigin[origin, default: 0] += 1
            if origin == .sentenceBoundary {
                if words < RunningThoughtGate.minimumSentenceWords { boundaryOriginBelowThreshold += 1 }
            } else {
                structuralOriginWordCounts[min(words, 5), default: 0] += 1
            }
            guard refused else { return }
            refusals += 1
            refusalsByOrigin[origin, default: 0] += 1
            refusalsByWordCount[words, default: 0] += 1
        }

        static func name(_ origin: RunningThoughtGate.SentenceStartOrigin) -> String {
            switch origin {
            case .documentStart: return "documentStart"
            case .structuralBreak: return "structuralBreak"
            case .sentenceBoundary: return "sentenceBoundary"
            }
        }

        func print() {
            let tag = "[running-thought-corpus]"
            let all: [RunningThoughtGate.SentenceStartOrigin] = [.documentStart, .structuralBreak, .sentenceBoundary]
            Swift.print("\(tag) \(language) files=\(files) chars=\(characters) carets=\(carets) "
                + "atOffset0=\(caretsAtOffsetZero)")
            Swift.print("\(tag)   carets by origin: "
                + all.map { "\(Self.name($0))=\(caretsByOrigin[$0, default: 0])" }.joined(separator: " "))
            Swift.print(String(format: "%@   arm-1 refusals: %d of %d (%.1f%% of all carets)",
                               tag, refusals, carets, carets == 0 ? 0 : Double(refusals) / Double(carets) * 100))
            Swift.print("\(tag)     by origin: "
                + all.map { "\(Self.name($0))=\(refusalsByOrigin[$0, default: 0])" }.joined(separator: " "))
            Swift.print("\(tag)     by sentence word count: "
                + refusalsByWordCount.keys.sorted().map { "\($0)w=\(refusalsByWordCount[$0]!)" }.joined(separator: " "))
            let structural = caretsByOrigin[.documentStart, default: 0] + caretsByOrigin[.structuralBreak, default: 0]
            Swift.print(String(format: "%@   refusal rate WITHIN structural-origin carets: %d of %d (%.1f%%)",
                               tag, refusals, structural, structural == 0 ? 0 : Double(refusals) / Double(structural) * 100))
            Swift.print("\(tag)   dial 1 (threshold=\(RunningThoughtGate.minimumSentenceWords)) — structural-origin carets by word count: "
                + structuralOriginWordCounts.keys.sorted()
                    .map { "\($0 == 5 ? "5+w" : "\($0)w")=\(structuralOriginWordCounts[$0]!)" }
                    .joined(separator: " "))
            Swift.print(String(format: "%@   dial 2 (structural-origin rule) — sentenceBoundary carets below the threshold, ALLOWED today by the narrowing: %d (%.1f%% of all carets)",
                               tag, boundaryOriginBelowThreshold,
                               carets == 0 ? 0 : Double(boundaryOriginBelowThreshold) / Double(carets) * 100))
        }
    }
}
