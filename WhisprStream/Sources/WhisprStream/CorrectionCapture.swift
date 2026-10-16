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
/// value. It attributes a change to the inserted transcript only when the edit
/// stays inside that span and looks like a correction rather than a rewrite.
enum CorrectionDiff {
    /// Edits larger than this fraction of the inserted text are rewrites, not
    /// recognition corrections, and must not become training samples.
    static let maximumEditRatio = 0.4
    /// Small spans tolerate a couple of characters regardless of the ratio so a
    /// two-character Chinese word can still be corrected.
    static let minimumEditAllowance = 2

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

    /// Returns the correction when `current` differs from `baseline` only inside
    /// `insertedRange` and the difference is small enough to be a word fix.
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

        var prefix = 0
        while prefix < base.count, prefix < now.count, base[prefix] == now[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < now.count - prefix,
              base[base.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }

        // The changed region in the baseline is [prefix, base.count - suffix).
        // Reject edits that reach outside the inserted text.
        var changeStart = prefix
        var changeEnd = base.count - suffix
        guard changeStart >= spanStart, changeEnd <= spanEnd else { return nil }

        // Widen to whole Latin words so "Hevy" -> "Heavy" compares words, not
        // the single inserted letter. CJK text has no word spacing; leave it.
        while changeStart > spanStart, isLatinWordCharacter(base[changeStart - 1]) { changeStart -= 1 }
        while changeEnd < spanEnd, isLatinWordCharacter(base[changeEnd]) { changeEnd += 1 }
        let replaced = String(base[changeStart..<changeEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementEnd = now.count - (base.count - changeEnd)
        guard replacementEnd >= changeStart else { return nil }
        let replacement = String(now[changeStart..<replacementEnd]).trimmingCharacters(in: .whitespacesAndNewlines)

        // A recognition fix swaps one stretch of text for another. Typing new
        // words the speaker never said, or deleting ones they did, is editing.
        guard !replaced.isEmpty, !replacement.isEmpty, isSubstitution(replaced, replacement) else { return nil }

        let delta = now.count - base.count
        let inserted = String(base[spanStart..<spanEnd])
        let correctedEnd = spanEnd + delta
        guard correctedEnd >= spanStart, correctedEnd <= now.count else { return nil }
        let corrected = String(now[spanStart..<correctedEnd])
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, corrected != inserted else { return nil }

        // Punctuation and spacing are the app's own formatting choices (the
        // punctuation setting strips sentence enders), not recognition errors.
        // Casing changes are kept: "codex" -> "Codex" is real vocabulary signal.
        guard lexicalContent(inserted) != lexicalContent(corrected) else { return nil }

        let distance = editDistance(Array(inserted), Array(corrected))
        let allowance = max(minimumEditAllowance,
                            Int((Double(inserted.count) * maximumEditRatio).rounded(.down)))
        guard distance <= allowance else { return nil }
        return CapturedCorrection(inserted: inserted, corrected: corrected)
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
/// field was cleared (a message was sent), the element went away, another
/// dictation started, or the watch timed out. Only Accessibility reads are
/// used: no keystrokes, no clipboard, nothing visible to the user.
@MainActor
final class CorrectionCaptureSession {
    static let baselinePollInterval: TimeInterval = 0.15
    static let baselineTimeout: TimeInterval = 2.0
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
    private var latestNonEmpty: String?
    private var baselineDeadline: Date = .distantPast
    private var pollWork: DispatchWorkItem?
    private var clearWork: DispatchWorkItem?
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
        guard AXIsProcessTrusted(), let element = TextInserter.focusedTextElement() else {
            Log.write("correction capture: no focused accessibility element")
            return false
        }
        self.element = element
        baselineDeadline = Date().addingTimeInterval(Self.baselineTimeout)
        pollForBaseline()
        return true
    }

    /// Ends the watch using the latest value seen. Safe to call repeatedly.
    func finish() {
        guard !finished else { return }
        finished = true
        pollWork?.cancel()
        timeoutWork?.cancel()
        clearWork?.cancel()
        if let observer, let element {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
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
        if let value = readValue(),
           let range = CorrectionDiff.insertedRange(of: insertedText, in: value, caret: readCaret()) {
            baseline = value
            insertedRange = range
            latestNonEmpty = value
            Log.write("correction capture: baseline \(value.count) chars, span \(insertedText.count) chars")
            subscribe()
            return
        }
        guard Date() < baselineDeadline else {
            Log.write("correction capture: inserted text never appeared in the focused field")
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
