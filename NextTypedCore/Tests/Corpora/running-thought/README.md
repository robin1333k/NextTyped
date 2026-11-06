# running-thought corpus

Plain EN + DE prose, written for this repository and therefore licence-clean. It exists for exactly
one measurement: the rate at which **arm 1** of `RunningThoughtGate` refuses a continuation, across
many independent carets.

**What it deliberately is not.** It carries **no author identity** and **no ground-truth middles**, so
it cannot stand in for a corpus of real authors with known middles. Do not extend it into one; the two
have different requirements.

**Stated plainly, because the numbers look odd otherwise.** `prose.txt`, `correspondence.txt` and
`notes.txt`/`notizen.txt` are the **same documents rewritten** in the other language — a deliberate
controlled pair, so a difference between the EN and DE rates is a difference in the *language*, not in
the material. The consequence is that those three files contribute the *same* line and paragraph
structure to both sides, and arm 1 keys on structure: a first run therefore produced byte-identical
`0w`/`1w` refusal counts for EN and DE, which reads as a bug and is not one. `structured.txt` is the
one **unpaired** pair — an EN meeting minute against a DE fault report, different shapes and different
line counts — and it is what makes the two totals diverge at all. Do not "fix" the symmetry of the
other three by translating loosely; either keep the pairing exact or add another unpaired file.

**What it must keep.** Arm 1 engages only at a **structural** sentence start — after a newline, or at
the document start — so the corpus has to contain real structure and not only flowing paragraphs:
headings, short colon-terminated lines, list items, a dateline. `*-structured.txt` in each language is
there for that reason, and removing it would leave the walk unable to reach its own subject. The walk
asserts a non-zero structural-origin count precisely so that removal shows up as a failure rather than
as a smaller number.

Layout, read by `RunningThoughtArm1CorpusWalk` through `#filePath` (no SPM resource declaration, the
`PredictPathScanCostBenchmark` precedent). The walk can write a TSV of refused carets, which carries
each prefix verbatim, so an offline probe never needs to open these files:

    NextTypedCore/Tests/Corpora/running-thought/en/*.txt
    NextTypedCore/Tests/Corpora/running-thought/de/*.txt

The files live under `Tests/` but **outside** `Tests/NextTypedCoreTests/` on purpose: a non-Swift
file inside the test target's source directory is an unhandled-resource warning in SwiftPM.
