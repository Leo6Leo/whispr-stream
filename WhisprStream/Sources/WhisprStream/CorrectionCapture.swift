import AppKit
import ApplicationServices

/// A correction the user made by hand inside the destination field after a
/// transcript was inserted. Both strings are the inserted span only, never the
/// surrounding document.
struct CapturedCorrection: Equatable {
    let inserted: String
    let corrected: String
}

/// Pure comparison between the field value right after insertion and a later
/// value. The inserted span is located again in the later value, so edits
/// elsewhere in a document, a line that re-rendered, or a scrolled editor
/// viewport do not hide a correction. A change is attributed to the transcript
/// only when it stays inside that span and looks like a correction rather than
/// a rewrite.
enum CorrectionDiff {
    /// Edits larger than this fraction of the inserted text are rewrites, not
    /// recognition corrections, and must not become training samples.
    static let maximumEditRatio = 0.4
    /// Small spans tolerate a couple of characters regardless of the ratio so a
    /// two-character Chinese word can still be corrected.
    static let minimumEditAllowance = 2
    /// Character alignment is quadratic in the part of a line that changed.
    /// Past this many cells the span is not relocated and no sample is taken.
    static let maximumAlignmentCells = 4_000_000

    /// Locates the inserted transcript inside the field value as it was right
    /// after the paste landed. The caret sits at the end of the paste, so the
    /// last occurrence ending at or before the caret wins.
    static func insertedRange(
        of inserted: String,
        in baseline: String,
        caret: Int?
    ) -> Range<String.Index>? {
        let needle = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !baseline.isEmpty else { return nil }
        var candidates: [Range<String.Index>] = []
        var search = baseline.startIndex..<baseline.endIndex
        while let found = baseline.range(of: needle, range: search) {
            candidates.append(found)
            guard found.upperBound < baseline.endIndex else { break }
            search = baseline.index(after: found.lowerBound)..<baseline.endIndex
        }
        guard !candidates.isEmpty else { return nil }
        guard let caret, caret >= 0, caret <= baseline.count else { return candidates.last }
        let caretIndex = baseline.index(baseline.startIndex, offsetBy: caret)
        return candidates.last(where: { $0.upperBound <= caretIndex }) ?? candidates.last
    }

    /// Returns the correction when what now stands where the transcript was
    /// pasted differs from it by a word fix. Everything outside the span may
    /// have changed in the meantime.
    static func correction(
        baseline: String,
        insertedRange: Range<String.Index>,
        current: String
    ) -> CapturedCorrection? {
        guard baseline != current else { return nil }
        let base = Array(baseline)
        let now = Array(current)
        let spanStart = baseline.distance(from: baseline.startIndex, to: insertedRange.lowerBound)
        let spanEnd = baseline.distance(from: baseline.startIndex, to: insertedRange.upperBound)
        guard spanStart < spanEnd, spanEnd <= base.count else { return nil }
        guard let located = currentSpan(baseline: base, span: spanStart..<spanEnd, current: now) else { return nil }
        return correction(inserted: Array(base[spanStart..<spanEnd]), corrected: Array(now[located]))
    }

    /// Compares the inserted transcript with the text that replaced it.
    static func correction(inserted: [Character], corrected: [Character]) -> CapturedCorrection? {
        guard inserted != corrected else { return nil }
        var prefix = 0
        while prefix < inserted.count, prefix < corrected.count, inserted[prefix] == corrected[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < inserted.count - prefix, suffix < corrected.count - prefix,
              inserted[inserted.count - 1 - suffix] == corrected[corrected.count - 1 - suffix] { suffix += 1 }

        // Widen to whole Latin words so "Hevy" -> "Heavy" compares words, not
        // the single inserted letter. CJK text has no word spacing; leave it.
        var changeStart = prefix
        var changeEnd = inserted.count - suffix
        while changeStart > 0, isLatinWordCharacter(inserted[changeStart - 1]) { changeStart -= 1 }
        while changeEnd < inserted.count, isLatinWordCharacter(inserted[changeEnd]) { changeEnd += 1 }
        let replaced = String(inserted[changeStart..<changeEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementEnd = corrected.count - (inserted.count - changeEnd)
        guard replacementEnd >= changeStart else { return nil }
        let replacement = String(corrected[changeStart..<replacementEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        // A recognition fix swaps one stretch of text for another. Typing new
        // words the speaker never said, or deleting ones they did, is editing.
        guard !replaced.isEmpty, !replacement.isEmpty, isSubstitution(replaced, replacement) else { return nil }

        let insertedText = String(inserted)
        let correctedText = String(corrected)
        guard !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Punctuation and spacing are the app's own formatting choices (the
        // punctuation setting strips sentence enders), not recognition errors.
        // Casing changes are kept: "codex" -> "Codex" is real vocabulary signal.
        guard lexicalContent(insertedText) != lexicalContent(correctedText) else { return nil }

        let distance = editDistance(inserted, corrected)
        let allowance = max(minimumEditAllowance,
                            Int((Double(inserted.count) * maximumEditRatio).rounded(.down)))
        guard distance <= allowance else { return nil }
        return CapturedCorrection(inserted: insertedText, corrected: correctedText)
    }

    /// Where the inserted span stands in `current`. Only the span's own line
    /// is aligned character by character; the other lines may have been
    /// edited, re-rendered by a live-preview editor, or scrolled in and out of
    /// an editor that exposes just its viewport. Returns nil when no line in
    /// `current` resembles the span's line any more.
    static func currentSpan(
        baseline base: [Character],
        span: Range<Int>,
        current now: [Character]
    ) -> Range<Int>? {
        guard span.lowerBound < span.upperBound, span.upperBound <= base.count else { return nil }
        if base == now { return span }

        var lineStart = span.lowerBound
        while lineStart > 0, base[lineStart - 1] != "\n" { lineStart -= 1 }
        var lineEnd = span.upperBound
        while lineEnd < base.count, base[lineEnd] != "\n" { lineEnd += 1 }
        let line = Array(base[lineStart..<lineEnd])
        let local = (span.lowerBound - lineStart)..<(span.upperBound - lineStart)
        let lineIndex = base[..<lineStart].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }

        // Rank the current lines by what they share with the span's line at
        // either end, align the best few, and keep the closest in edit
        // distance. Ties go to the line nearest the original position.
        let candidates = lineRanges(of: now)
        let ranked = candidates.indices.sorted { lhs, rhs in
            let left = sharedEdges(line, Array(now[candidates[lhs]]))
            let right = sharedEdges(line, Array(now[candidates[rhs]]))
            if left != right { return left > right }
            return abs(lhs - lineIndex) < abs(rhs - lineIndex)
        }
        var best: (range: Range<Int>, alignment: Alignment)?
        for index in ranked.prefix(3) {
            let range = candidates[index]
            guard let alignment = align(line, Array(now[range])) else { continue }
            if best == nil || alignment.distance < best!.alignment.distance {
                best = (range, alignment)
            }
        }
        guard let best,
              best.alignment.distance * 2 <= max(line.count, best.range.count)
        else { return nil }
        let located = best.alignment.map(local, in: Array(now[best.range]))
        return (best.range.lowerBound + located.lowerBound)..<(best.range.lowerBound + located.upperBound)
    }

    /// The caret may rest right after the span, where the paste left it, or
    /// one position further when a separator followed the transcript.
    static func caretLeftSpan(caret: Int, span: Range<Int>) -> Bool {
        caret < span.lowerBound || caret > span.upperBound + 1
    }

    /// Character-level alignment of one line against its later version.
    struct Alignment {
        let distance: Int
        /// For each baseline index the current index where it begins; the
        /// final entry is the current length.
        let begin: [Int]
        /// For each baseline character the current index after its aligned
        /// character, equal to `begin` when the character was deleted.
        let end: [Int]

        /// Carries a baseline span across to the current line. Characters
        /// typed hard against the span's first or last character belong to
        /// that word ("run Py" -> "run Pi", "the NAS" -> "the NASA"); once
        /// whitespace separates them they are new text outside the transcript.
        func map(_ span: Range<Int>, in current: [Character]) -> Range<Int> {
            let aligned = span.filter { end[$0] > begin[$0] }
            guard let first = aligned.first, let last = aligned.last else {
                return begin[span.lowerBound]..<begin[span.lowerBound]
            }
            var start = begin[first]
            var stop = end[last]
            let previousEnd = (0..<first).last(where: { end[$0] > begin[$0] }).map { end[$0] } ?? 0
            if previousEnd < start {
                let run = current[previousEnd..<start]
                start = run.lastIndex(where: \.isWhitespace).map { $0 + 1 } ?? previousEnd
            }
            let nextBegin = (last + 1 ..< end.count).first(where: { end[$0] > begin[$0] })
                .map { begin[$0] } ?? current.count
            if stop < nextBegin {
                let run = current[stop..<nextBegin]
                stop = run.firstIndex(where: \.isWhitespace) ?? nextBegin
            }
            return start..<stop
        }
    }

    /// Levenshtein alignment with a backtrace, computed over the part of the
    /// two lines that differs. Nil when that part is too large to align.
    static func align(_ a: [Character], _ b: [Character]) -> Alignment? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        guard (n + 1) * (m + 1) <= maximumAlignmentCells else { return nil }

        let width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        for i in 0...n { cost[i * width] = Int32(i) }
        for j in 0...m { cost[j] = Int32(j) }
        if n > 0, m > 0 {
            for i in 1...n {
                let ai = a[prefix + i - 1]
                for j in 1...m {
                    let substitute = cost[(i - 1) * width + j - 1] + (ai == b[prefix + j - 1] ? 0 : 1)
                    let delete = cost[(i - 1) * width + j] + 1
                    let insert = cost[i * width + j - 1] + 1
                    cost[i * width + j] = min(substitute, min(delete, insert))
                }
            }
        }

        // Backtrace: 0 = aligned (match or substitution), 1 = deleted, 2 = inserted.
        var operations: [(index: Int, kind: UInt8)] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            let here = cost[i * width + j]
            if i > 0, j > 0,
               here == cost[(i - 1) * width + j - 1] + (a[prefix + i - 1] == b[prefix + j - 1] ? 0 : 1) {
                operations.append((i - 1, 0)); i -= 1; j -= 1
            } else if i > 0, here == cost[(i - 1) * width + j] + 1 {
                operations.append((i - 1, 1)); i -= 1
            } else {
                operations.append((j - 1, 2)); j -= 1
            }
        }

        var begin = [Int](repeating: 0, count: a.count + 1)
        var end = [Int](repeating: 0, count: a.count)
        for k in 0..<prefix {
            begin[k] = k
            end[k] = k + 1
        }
        var cursor = prefix
        for operation in operations.reversed() {
            switch operation.kind {
            case 0:
                begin[prefix + operation.index] = cursor
                end[prefix + operation.index] = cursor + 1
                cursor += 1
            case 1:
                begin[prefix + operation.index] = cursor
                end[prefix + operation.index] = cursor
            default:
                cursor += 1
            }
        }
        for k in 0..<suffix {
            let index = a.count - suffix + k
            begin[index] = b.count - suffix + k
            end[index] = b.count - suffix + k + 1
        }
        begin[a.count] = b.count
        return Alignment(distance: Int(cost[n * width + m]), begin: begin, end: end)
    }

    private static func lineRanges(of text: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, character) in text.enumerated() where character == "\n" {
            ranges.append(start..<index)
            start = index + 1
        }
        ranges.append(start..<text.count)
        return ranges
    }

    private static func sharedEdges(_ a: [Character], _ b: [Character]) -> Int {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return prefix + suffix
    }

    static func isLatinWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter || character.isNumber, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: return false
        default: return true
        }
    }

    /// False when one side is just the other side with words added or removed.
    static func isSubstitution(_ replaced: String, _ replacement: String) -> Bool {
        let exactA = lexicalContent(replaced)
        let exactB = lexicalContent(replacement)
        guard !exactA.isEmpty, !exactB.isEmpty, exactA != exactB else { return false }
        let a = exactA.lowercased()
        let b = exactB.lowercased()
        // Only the casing changed: "codex" -> "Codex" is a vocabulary fix.
        guard a != b else { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return !(long.hasPrefix(short) || long.hasSuffix(short))
    }

    static func lexicalContent(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            row[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &row)
        }
        return previous[b.count]
    }
}

/// Watches the destination text field after a transcript was inserted and
/// reports a correction once the user finishes with it. Finishing means the
/// caret left the inserted text and stayed away, the field was cleared (a
/// message was sent), the element went away, another dictation started, or
/// the watch timed out. Only Accessibility reads are
/// used: no keystrokes, no clipboard, nothing visible to the user.
@MainActor
final class CorrectionCaptureSession {
    static let baselinePollInterval: TimeInterval = 0.15
    /// A missing field is looked up less often: each lookup may walk the tree.
    static let elementRetryInterval: TimeInterval = 0.5
    /// Covers the paste landing and, in Chromium apps (Chrome, ChatGPT), the
    /// ~3 s the web tree takes to appear after dictation start switched it on.
    static let baselineTimeout: TimeInterval = 4.0
    static let watchTimeout: TimeInterval = 120
    /// Web editors (ProseMirror in Claude) report an empty value for a moment
    /// while re-rendering after a paste. A clear counts only once it persists.
    static let clearConfirmationDelay: TimeInterval = 1.0

    let insertedText: String
    private let onFinish: (CapturedCorrection?) -> Void
    private var element: AXUIElement?
    private var observer: AXObserver?
    private var baseline: String?
    private var insertedRange: Range<String.Index>?
    private var insertedOffsets: Range<Int>?
    private var latestNonEmpty: String?
    private var baselineDeadline: Date = .distantPast
    private var lastElementLookup: Date = .distantPast
    private var pollWork: DispatchWorkItem?
    private var clearWork: DispatchWorkItem?
    private var caretExitWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var finished = false
    private var finishReason = "explicit"
    private var eventCount = 0

    init(insertedText: String, onFinish: @escaping (CapturedCorrection?) -> Void) {
        self.insertedText = insertedText
        self.onFinish = onFinish
    }

    /// Finds the focused field and waits for the paste to land before
    /// recording the baseline. Returns false when nothing can be observed.
    @discardableResult
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        baselineDeadline = Date().addingTimeInterval(Self.baselineTimeout)
        pollForBaseline()
        return !finished
    }

    /// Ends the watch using the latest value seen. Safe to call repeatedly.
    func finish() {
        guard !finished else { return }
        finished = true
        pollWork?.cancel()
        timeoutWork?.cancel()
        clearWork?.cancel()
        caretExitWork?.cancel()
        if let observer, let element {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        var result: CapturedCorrection?
        var detail = "no baseline"
        if let baseline, let insertedRange, let latest = latestNonEmpty ?? readValue() {
            result = CorrectionDiff.correction(baseline: baseline, insertedRange: insertedRange, current: latest)
            detail = "baseline=\(baseline.count) latest=\(latest.count) changed=\(baseline != latest) events=\(eventCount)"
        }
        Log.write("correction capture finished reason=\(finishReason) captured=\(result != nil) \(detail)")
        onFinish(result)
    }

    private func pollForBaseline() {
        guard !finished else { return }
        // A Chromium app may still be building its tree; keep asking for the
        // field until the deadline instead of giving up on the first miss.
        if element == nil, Date().timeIntervalSince(lastElementLookup) >= Self.elementRetryInterval {
            lastElementLookup = Date()
            element = TextInserter.focusedTextElement()
        }
        if let value = readValue(),
           let range = CorrectionDiff.insertedRange(of: insertedText, in: value, caret: readCaret()) {
            baseline = value
            insertedRange = range
            insertedOffsets = value.distance(from: value.startIndex, to: range.lowerBound)
                ..< value.distance(from: value.startIndex, to: range.upperBound)
            latestNonEmpty = value
            Log.write("correction capture: baseline \(value.count) chars, span \(insertedText.count) chars")
            subscribe()
            return
        }
        guard Date() < baselineDeadline else {
            Log.write(element == nil
                ? "correction capture: no focused accessibility element"
                : "correction capture: inserted text never appeared in the focused field")
            finished = true
            onFinish(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.pollForBaseline() }
        pollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselinePollInterval, execute: work)
    }

    private func subscribe() {
        guard let element else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let session = Unmanaged<CorrectionCaptureSession>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            Task { @MainActor in session.handle(notification: name) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Log.write("correction capture: observer unavailable")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, refcon)
        AXObserverAddNotification(created, element, kAXSelectedTextChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created

        let work = DispatchWorkItem { [weak self] in
            self?.finishReason = "timeout"
            self?.finish()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchTimeout, execute: work)
    }

    private func handle(notification: String) {
        guard !finished else { return }
        if notification == kAXSelectedTextChangedNotification as String {
            noteCaretPosition()
            return
        }
        eventCount += 1
        if notification == kAXUIElementDestroyedNotification as String {
            finishReason = "element-destroyed"
            finish()
            return
        }
        guard let value = readValue() else {
            Log.write("correction capture: value unreadable after change")
            return
        }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The field was cleared: the message was sent. The last non-empty
            // value is the user's final version. Confirm after a short delay so
            // a transient empty read during a re-render does not end the watch.
            guard clearWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                self.clearWork = nil
                let stillEmpty = (self.readValue() ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard stillEmpty else {
                    Log.write("correction capture: ignored transient empty value")
                    return
                }
                self.finishReason = "field-cleared"
                self.finish()
            }
            clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearConfirmationDelay, execute: work)
            return
        }
        clearWork?.cancel()
        clearWork = nil
        latestNonEmpty = value
        Log.write("correction capture: value changed to \(value.count) chars")
    }

    /// A caret that left the inserted text and stayed away for a moment means
    /// the user moved on. Ending the watch here, rather than after two minutes
    /// or at the next dictation, lets a correction reach the training store
    /// while the user is still looking at it.
    private func noteCaretPosition() {
        guard let baseline, let insertedOffsets else { return }
        func caretIsOutside() -> Bool {
            guard let caret = readCaret(), let value = readValue(),
                  let span = CorrectionDiff.currentSpan(
                    baseline: Array(baseline), span: insertedOffsets, current: Array(value)
                  ) else { return false }
            return CorrectionDiff.caretLeftSpan(caret: caret, span: span)
        }
        guard caretIsOutside() else {
            caretExitWork?.cancel()
            caretExitWork = nil
            return
        }
        guard caretExitWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.caretExitWork = nil
            guard caretIsOutside() else { return }
            if let value = self.readValue(),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.latestNonEmpty = value
            }
            self.finishReason = "caret-left-span"
            self.finish()
        }
        caretExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearConfirmationDelay, execute: work)
    }

    private func readValue() -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func readCaret() -> Int? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }
}
