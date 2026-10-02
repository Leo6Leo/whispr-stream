import AppKit

/// Delivers text to whichever app has focus and/or the clipboard.
///
/// Pasteboard + Cmd-V rather than synthesised per-character key events: unicode
/// keystroke injection is unreliable for CJK, and this path handles mixed
/// scripts correctly. When clipboard retention is disabled, the previous
/// pasteboard contents are restored after the paste.
enum TextInserter {
    struct ReviewTarget {
        let application: NSRunningApplication
        let element: AXUIElement?
        let window: AXUIElement?
        let windowID: CGWindowID?
        let selectionAttribute: String?
        let selection: CFTypeRef?
        let originalValue: String?
    }

    /// Capture before the chooser takes focus. Custom editors (including WeChat)
    /// may not expose a caret through Accessibility; keep their application and
    /// window so returning from the chooser can still use ordinary paste.
    static func captureReviewTarget() -> ReviewTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = focusedTextElement().flatMap { focused -> AXUIElement? in
            var owner: pid_t = 0
            return AXUIElementGetPid(focused, &owner) == .success && owner == app.processIdentifier
                ? focused : nil
        }
        let window = element.flatMap { uiElementAttribute(of: $0, named: kAXWindowAttribute as String) }
            ?? uiElementAttribute(of: AXUIElementCreateApplication(app.processIdentifier),
                                  named: kAXFocusedWindowAttribute as String)
        let selectionAttribute = element.flatMap { focused in
            [kAXSelectedTextRangeAttribute as String, "AXSelectedTextMarkerRange"].first {
                attributeValue(of: focused, named: $0) != nil
            }
        }
        let selection = element.flatMap { focused in
            selectionAttribute.flatMap { attributeValue(of: focused, named: $0) }
        }
        Log.write("review: captured target=\(app.bundleIdentifier ?? "?") caret=\(selection != nil)")
        return ReviewTarget(application: app, element: element, window: window,
                            windowID: frontWindowID(for: app.processIdentifier),
                            selectionAttribute: selectionAttribute, selection: selection,
                            originalValue: element.flatMap {
                                attributeValue(of: $0, named: kAXValueAttribute as String) as? String
                            })
    }

    /// Window IDs remain available for custom editors without AX text support.
    /// Only metadata is read; no window contents or titles are needed.
    private static func frontWindowID(for processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                      kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }.flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    @MainActor
    static func restoreReviewTarget(
        _ target: ReviewTarget?,
        isCurrent: @escaping () -> Bool = { true },
        completion: @escaping (pid_t?) -> Void
    ) {
        guard isCurrent(), let target, !target.application.isTerminated else { completion(nil); return }
        NSApp.yieldActivation(to: target.application)
        target.application.activate(from: .current, options: [])
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        func restoreWhenActive() {
            guard isCurrent(), !target.application.isTerminated else { completion(nil); return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier else {
                guard ProcessInfo.processInfo.systemUptime < deadline else { completion(nil); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { restoreWhenActive() }
                return
            }
            // Do not restore an old range into a document edited while the
            // chooser was open. The caller keeps the chosen text on clipboard.
            if let element = target.element, let original = target.originalValue,
               attributeValue(of: element, named: kAXValueAttribute as String) as? String != original {
                completion(nil); return
            }
            if let window = target.window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
            if let element = target.element {
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if let name = target.selectionAttribute, let selection = target.selection {
                    AXUIElementSetAttributeValue(element, name as CFString, selection)
                }
            }
            func verifyRestoration() {
                guard isCurrent(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier,
                      !target.application.isTerminated else { completion(nil); return }
                if let element = target.element, let original = target.originalValue,
                   attributeValue(of: element, named: kAXValueAttribute as String) as? String != original {
                    completion(nil); return
                }
                let restored: Bool
                if let element = target.element, let name = target.selectionAttribute, let selection = target.selection {
                    // Editors with an exposed caret must still restore the
                    // exact field and selection, not merely the application.
                    restored = focusedTextElement().map { CFEqual($0, element) } == true
                        && attributeValue(of: element, named: name).map { CFEqual($0, selection) } == true
                } else {
                    let currentWindow = uiElementAttribute(
                        of: AXUIElementCreateApplication(target.application.processIdentifier),
                        named: kAXFocusedWindowAttribute as String)
                    let sameWindow = target.window.map { expected in
                        currentWindow.map { CFEqual($0, expected) } == true
                    } ?? target.windowID.map { frontWindowID(for: target.application.processIdentifier) == $0 } ?? false
                    let sameField = target.element.map { expected in
                        focusedTextElement().map { CFEqual($0, expected) } == true
                    } ?? true
                    restored = sameWindow && sameField
                }
                if restored {
                    Log.write("review: restored target caret=\(target.selection != nil)")
                    completion(target.application.processIdentifier)
                } else if ProcessInfo.processInfo.systemUptime < deadline {
                    // Some editors apply Accessibility focus/range changes on
                    // their next event-loop turn. Verify without moving again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { verifyRestoration() }
                } else {
                    Log.write("review: target restoration timed out; keeping transcript on clipboard")
                    completion(nil)
                }
            }
            verifyRestoration()
        }
        restoreWhenActive()
    }

    private struct PasteboardSnapshot {
        let items: [[(NSPasteboard.PasteboardType, Data)]]

        init(_ pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type, data)
                }
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations {
                    item.setData(data, forType: type)
                }
                return item
            }
            guard !restored.isEmpty else { return }
            pasteboard.writeObjects(restored)
        }
    }

    /// Performs the requested output actions. `text` is the clean transcript
    /// retained on the clipboard; `insertionText` may include cursor-separating
    /// whitespace used only for the synthetic paste.
    static func deliver(
        _ text: String,
        insertionText: String? = nil,
        insertAtCursor: Bool,
        copyToClipboard: Bool,
        targetProcessID: pid_t? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !text.isEmpty else { completion?(); return }

        if insertAtCursor {
            insert(
                insertionText ?? text,
                clipboardAfterPaste: copyToClipboard ? text : nil,
                targetProcessID: targetProcessID,
                completion: completion
            )
        } else if copyToClipboard {
            copyOnly(text)
            completion?()
        } else {
            Log.write("transcript delivered nowhere (both output options off)")
            completion?()
        }
    }

    private static func insert(
        _ text: String,
        clipboardAfterPaste: String?,
        targetProcessID: pid_t?,
        completion: (() -> Void)?
    ) {
        guard !text.isEmpty else { completion?(); return }

        let front = NSWorkspace.shared.frontmostApplication
        Log.write("insert: \(text.count) chars -> front=\(front?.bundleIdentifier ?? "nil") "
                  + "(\(front?.localizedName ?? "?")) trusted=\(AXIsProcessTrusted())")

        let pb = NSPasteboard.general
        let saved = clipboardAfterPaste == nil ? PasteboardSnapshot(pb) : nil

        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        Log.write("  pasteboard write=\(ok) chars=\(text.count)")
        let insertedChangeCount = pb.changeCount

        // The pasteboard write is asynchronous from the front app's point of
        // view; posting Cmd-V in the same runloop tick often pastes stale
        // contents or nothing at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pressCommandV(targetProcessID: targetProcessID)

            if saved != nil || clipboardAfterPaste != text {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    defer { completion?() }
                    // Do not overwrite a clipboard update made by the user or
                    // the destination app while the paste was in flight.
                    guard pb.changeCount == insertedChangeCount else {
                        Log.write("  skipped clipboard restore: clipboard changed")
                        return
                    }
                    if let saved {
                        saved.restore(to: pb)
                        Log.write("  restored previous clipboard contents")
                    } else if let clipboardAfterPaste {
                        pb.clearContents()
                        pb.setString(clipboardAfterPaste, forType: .string)
                        Log.write("  retained clean transcript on clipboard")
                    }
                }
            } else {
                completion?()
            }
        }
    }

    /// Put the transcript on the clipboard without pasting it.
    static func copyOnly(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("copied \(text.count) chars (insert at cursor off)")
    }

    /// Resolves continuation context while keeping the probe isolated from the
    /// final paste. Accessibility is the fast, read-only path. Apps that do not
    /// expose cursor text use a keyboard-copy fallback. Callers can start that
    /// fallback while dictation is in progress because its private event source
    /// carries only the explicit shortcut flags, not a held trigger modifier.
    /// They must still wait for completion before inserting so a delayed copy
    /// can never overwrite the transcript.
    static func resolveTextBeforeCursor(
        fallback: String?,
        forceKeyboardFallback: Bool = false,
        allowWhilePhysicalModifiersPressed: Bool = false,
        targetProcessID: pid_t? = nil,
        completion: @escaping (String?) -> Void
    ) {
        if !forceKeyboardFallback, let text = textBeforeCursor() {
            completion(text)
            return
        }

        guard frontmostBundleID != Bundle.main.bundleIdentifier else {
            completion(fallback)
            return
        }

        if allowWhilePhysicalModifiersPressed {
            copyLinePrefixBeforeCursor(targetProcessID: targetProcessID) { copiedText in
                completion(preferredTextBeforeCursor(
                    readableText: copiedText,
                    fallback: fallback
                ))
            }
            return
        }

        waitForPhysicalModifiersToClear { modifiersCleared in
            guard modifiersCleared else {
                Log.write("cursor context keyboard probe skipped: modifier still pressed")
                completion(fallback)
                return
            }
            copyLinePrefixBeforeCursor(targetProcessID: targetProcessID) { copiedText in
                completion(preferredTextBeforeCursor(
                    readableText: copiedText,
                    fallback: fallback
                ))
            }
        }
    }

    /// Kept separate from the Accessibility lookup so fallback precedence is
    /// deterministic and covered without synthesizing cross-app input events.
    static func preferredTextBeforeCursor(
        readableText: String?,
        fallback: String?
    ) -> String? {
        readableText ?? fallback
    }

    private static func waitForPhysicalModifiersToClear(
        deadline: DispatchTime = .now() + 0.8,
        completion: @escaping (Bool) -> Void
    ) {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let blockingFlags: CGEventFlags = [
            .maskCommand,
            .maskAlternate,
            .maskControl,
            .maskShift,
            .maskSecondaryFn,
        ]
        if flags.intersection(blockingFlags).isEmpty {
            completion(true)
            return
        }
        guard DispatchTime.now() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitForPhysicalModifiersToClear(deadline: deadline, completion: completion)
        }
    }

    private static func copyLinePrefixBeforeCursor(
        targetProcessID: pid_t?,
        completion: @escaping (String?) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)

        // Detect and preserve an existing selection before changing the caret.
        // Polling avoids treating a slow destination app as if no copy occurred.
        pasteboard.clearContents()
        let selectionProbeCount = pasteboard.changeCount
        pressCommandKey(8, targetProcessID: targetProcessID) // C
        waitForPasteboardChange(
            pasteboard,
            after: selectionProbeCount,
            timeout: 0.3
        ) { selectionChanged, _ in
            guard !selectionChanged else {
                saved.restore(to: pasteboard)
                Log.write("cursor context keyboard probe skipped: existing selection")
                completion(nil)
                return
            }

            // Select from the caret to the beginning of the current line, then
            // copy it. Every event carries explicit modifier flags and uses a
            // private source, so a held push-to-talk modifier cannot transform
            // the shortcut into another command.
            pressCommandShiftLeft(targetProcessID: targetProcessID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pasteboard.clearContents()
                let prefixProbeCount = pasteboard.changeCount
                pressCommandKey(8, targetProcessID: targetProcessID) // C
                waitForPasteboardChange(
                    pasteboard,
                    after: prefixProbeCount,
                    timeout: 0.5
                ) { changed, copiedText in
                    // A pasteboard change proves the selection-and-copy
                    // shortcut succeeded, so Right Arrow safely collapses the
                    // selection back to the original caret. With no change,
                    // there may be no selection at all (notably on an empty
                    // Google Docs bullet); a naked Right Arrow would advance
                    // the caret into the next list paragraph.
                    if shouldCollapseKeyboardSelection(
                        pasteboardChanged: changed
                    ) {
                        pressKey(124, targetProcessID: targetProcessID) // Right Arrow
                    }

                    // Leave time for the caret event and any timed-out copy to
                    // settle before restoring the clipboard and permitting the
                    // final transcript paste.
                    let settleDelay = changed ? 0.1 : 0.25
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                        saved.restore(to: pasteboard)
                        if let copiedText {
                            Log.write("cursor context source=keyboard-copy chars=\(copiedText.count)")
                        } else {
                            Log.write("cursor context keyboard probe unavailable")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            completion(copiedText)
                        }
                    }
                }
            }
        }
    }

    /// Kept as a pure decision so the empty-line caret regression remains
    /// covered without synthesizing global keyboard events in a unit test.
    static func shouldCollapseKeyboardSelection(
        pasteboardChanged: Bool
    ) -> Bool {
        pasteboardChanged
    }

    private static func waitForPasteboardChange(
        _ pasteboard: NSPasteboard,
        after changeCount: Int,
        timeout: TimeInterval,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        func poll() {
            if pasteboard.changeCount != changeCount {
                completion(true, pasteboard.string(forType: .string))
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                completion(false, nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    /// Returns only the short text slice immediately before the active cursor.
    /// Some apps do not expose editable text through Accessibility; callers
    /// treat nil as unknown and preserve the model's capitalization.
    static func textBeforeCursor(maxCharacters: Int = 256) -> String? {
        guard AXIsProcessTrusted(), maxCharacters > 0 else { return nil }

        guard let focusedElement = focusedTextElement() else {
            Log.write(
                "cursor context unavailable reason=no-focused-element front="
                    + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")
            )
            return nil
        }
        var element: AXUIElement? = focusedElement

        // Native text controls generally expose an integer selected range.
        // WebKit and Electron editors often expose only opaque text markers,
        // sometimes on an ancestor of the focused element. Try both forms.
        for _ in 0..<4 {
            guard let current = element else { break }
            if let text = textBeforeCursorUsingSelectedRange(
                in: current,
                maxCharacters: maxCharacters
            ) {
                logCursorContext(source: "selected-range", text: text, element: current)
                return text
            }
            if let text = textBeforeCursorUsingTextMarkers(
                in: current,
                maxCharacters: maxCharacters
            ) {
                logCursorContext(source: "text-marker", text: text, element: current)
                return text
            }
            element = parent(of: current)
        }

        // Some Chromium/Electron editors expose the focused text area's value
        // but no caret range at all. When nothing is selected, pasted text in
        // these controls normally lands at the end, so the value suffix is the
        // best available continuation context. Restrict this fallback to a
        // focused editable text role; never use a web area's or window's value.
        if let text = textBeforeCursorUsingFocusedValue(
            in: focusedElement,
            maxCharacters: maxCharacters
        ) {
            logCursorContext(source: "focused-value-end", text: text, element: focusedElement)
            return text
        }

        Log.write("cursor context unavailable role=\(role(of: focusedElement) ?? "unknown")")
        return nil
    }

    /// The system-wide focused-element query is not reliable for every app.
    /// Chromium/Electron and some sandboxed apps can reject it while still
    /// exposing the same element from their application Accessibility root.
    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = focusedElement(from: systemWide) {
            return focused
        }

        // The Accessibility-focused application may be an Electron/WebKit UI
        // helper rather than the bundle's main process. Querying it avoids the
        // PID mismatch that makes Codex and Chrome report no focused element.
        if let focusedApplication = uiElementAttribute(
            of: systemWide,
            named: kAXFocusedApplicationAttribute
        ),
        let focused = focusedElementWithinApplication(focusedApplication) {
            return focused
        }

        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return focusedElementWithinApplication(applicationElement)
    }

    private static func focusedElementWithinApplication(
        _ application: AXUIElement
    ) -> AXUIElement? {
        if let focused = focusedElementInExposedTree(application) {
            return focused
        }
        guard enableManualAccessibilityIfSupported(application) else { return nil }
        return focusedElementInExposedTree(application)
    }

    private static func focusedElementInExposedTree(
        _ application: AXUIElement
    ) -> AXUIElement? {
        if let focused = focusedElement(from: application) {
            return focused
        }
        guard let window = uiElementAttribute(
            of: application,
            named: kAXFocusedWindowAttribute
        ) else { return nil }
        if let focused = focusedElement(from: window) {
            return focused
        }
        return focusedEditableDescendant(of: window)
    }

    private static func enableManualAccessibilityIfSupported(
        _ application: AXUIElement
    ) -> Bool {
        let attribute = "AXManualAccessibility" as CFString
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            application,
            attribute,
            &settable
        ) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(
            application,
            attribute,
            kCFBooleanTrue
        ) == .success else { return false }

        Log.write("cursor context enabled manual accessibility for front app")
        return true
    }

    /// Last-resort lookup for apps that omit `AXFocusedUIElement` but expose a
    /// normal focused window tree. The bounds prevent a complex browser page
    /// from turning a trigger press into an unbounded accessibility traversal.
    private static func focusedEditableDescendant(of root: AXUIElement) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        let maximumDepth = 8
        let maximumElements = 512

        while index < queue.count, index < maximumElements {
            let candidate = queue[index]
            index += 1

            let isFocused = (attributeValue(
                of: candidate.element,
                named: kAXFocusedAttribute
            ) as? NSNumber)?.boolValue == true
            if isFocused, isEditableTextElement(candidate.element) {
                return candidate.element
            }

            guard candidate.depth < maximumDepth else { continue }
            for child in childElements(of: candidate.element) {
                queue.append((child, candidate.depth + 1))
                if queue.count >= maximumElements { break }
            }
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXChildrenAttribute, "AXChildrenInNavigationOrder"] {
            if let children = attributeValue(
                of: element,
                named: attribute
            ) as? [AXUIElement],
            !children.isEmpty {
                return children
            }
        }
        return []
    }

    private static func uiElementAttribute(
        of element: AXUIElement,
        named attribute: String
    ) -> AXUIElement? {
        guard let value = attributeValue(of: element, named: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedElement(from root: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(of: root, named: kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func textBeforeCursorUsingSelectedRange(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
        let selectedRangeValue,
        CFGetTypeID(selectedRangeValue) == AXValueGetTypeID()
        else { return nil }

        let selectedAXValue = selectedRangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(selectedAXValue, .cfRange, &selectedRange),
              selectedRange.location >= 0 else { return nil }

        let length = min(maxCharacters, selectedRange.location)
        guard length > 0 else { return "" }
        var requestedRange = CFRange(
            location: selectedRange.location - length,
            length: length
        )

        if let rangeValue = AXValueCreate(.cfRange, &requestedRange) {
            var substringValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &substringValue
            ) == .success,
            let substring = substringValue as? String {
                return substring
            }
        }

        // Native controls commonly expose a complete value but not the
        // parameterized range API. Read only the final slice from that value.
        var completeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &completeValue
        ) == .success,
        let completeText = completeValue as? String else { return nil }

        let utf16Text = completeText as NSString
        let cursor = min(selectedRange.location, utf16Text.length)
        let start = max(0, cursor - maxCharacters)
        return utf16Text.substring(with: NSRange(location: start, length: cursor - start))
    }

    /// WebKit-backed editors represent selections with opaque text markers
    /// instead of `AXSelectedTextRange`. Resolve the insertion marker to an
    /// index, build a short marker range before it, and request that string.
    private static func textBeforeCursorUsingTextMarkers(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {
        guard let selectedRange = attributeValue(
            of: element,
            named: "AXSelectedTextMarkerRange"
        ),
        let cursorMarker = parameterizedValue(
            of: element,
            named: "AXStartTextMarkerForTextMarkerRange",
            parameter: selectedRange
        ),
        let cursorIndexValue = parameterizedValue(
            of: element,
            named: "AXIndexForTextMarker",
            parameter: cursorMarker
        ) as? NSNumber
        else { return nil }

        let cursorIndex = cursorIndexValue.intValue
        guard cursorIndex >= 0 else { return nil }
        let startIndex = max(0, cursorIndex - maxCharacters)

        var cfStartIndex = startIndex
        guard let startIndexValue = CFNumberCreate(nil, .cfIndexType, &cfStartIndex),
              let startMarker = parameterizedValue(
                of: element,
                named: "AXTextMarkerForIndex",
                parameter: startIndexValue
              )
        else { return nil }

        let markers = [startMarker, cursorMarker] as CFArray
        guard let markerRange = parameterizedValue(
            of: element,
            named: "AXTextMarkerRangeForUnorderedTextMarkers",
            parameter: markers
        ),
        let text = parameterizedValue(
            of: element,
            named: "AXStringForTextMarkerRange",
            parameter: markerRange
        ) as? String
        else { return nil }

        return text
    }

    private static func textBeforeCursorUsingFocusedValue(
        in element: AXUIElement,
        maxCharacters: Int
    ) -> String? {
        guard isEditableTextElement(element) else { return nil }

        // If text is selected, paste will replace it rather than append at the
        // end. Without a range we cannot safely infer the preceding character.
        if let selectedText = attributeValue(
            of: element,
            named: kAXSelectedTextAttribute
        ) as? String,
        !selectedText.isEmpty {
            return nil
        }

        guard let completeText = attributeValue(
            of: element,
            named: kAXValueAttribute
        ) as? String else { return nil }

        let utf16Text = completeText as NSString
        let start = max(0, utf16Text.length - maxCharacters)
        return utf16Text.substring(
            with: NSRange(location: start, length: utf16Text.length - start)
        )
    }

    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let elementRole = role(of: element)
        let knownTextRole = elementRole == kAXTextFieldRole
            || elementRole == kAXTextAreaRole
            || elementRole == "AXComboBox"
        let explicitlyEditable = (attributeValue(
            of: element,
            named: "AXEditable"
        ) as? NSNumber)?.boolValue == true
        return knownTextRole || explicitlyEditable
    }

    private static func role(of element: AXUIElement) -> String? {
        attributeValue(of: element, named: kAXRoleAttribute) as? String
    }

    private static func logCursorContext(
        source: String,
        text: String,
        element: AXUIElement
    ) {
        Log.write(
            "cursor context source=\(source) chars=\(text.count) "
                + "role=\(role(of: element) ?? "unknown")"
        )
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(of: element, named: kAXParentAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attributeValue(
        of element: AXUIElement,
        named attribute: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func parameterizedValue(
        of element: AXUIElement,
        named attribute: String,
        parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value
    }

    private static func pressCommandV(targetProcessID: pid_t?) {
        // .hidSystemState + .cghidEventTap is the combination that actually
        // reaches other applications; session taps get dropped for synthetic
        // modifier-key combinations.
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9        // kVK_ANSI_V
        let cmdKey: CGKeyCode = 55     // kVK_Command

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        else {
            Log.write("  CGEvent creation FAILED (no event source)")
            return
        }

        // Stray modifiers still latched from the push-to-talk key would turn
        // Cmd-V into Cmd-Opt-V, which is not paste.
        let live = CGEventSource.flagsState(.combinedSessionState)
        if live.contains(.maskAlternate) || live.contains(.maskControl) || live.contains(.maskShift) {
            Log.write("  WARNING stray modifiers latched: \(live.rawValue)")
        }

        // Send a real modifier press/release around the V rather than only
        // stamping .maskCommand, so apps that track modifier state agree.
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        for event in [cmdDown, vDown, vUp, cmdUp] {
            post(event, targetProcessID: targetProcessID)
        }
        Log.write(
            targetProcessID.map { "  posted Cmd-V to pid=\($0)" }
                ?? "  posted Cmd-V to cghidEventTap"
        )
    }

    private static func pressCommandKey(
        _ keyCode: CGKeyCode,
        targetProcessID: pid_t?
    ) {
        let source = CGEventSource(stateID: .privateState)
        let commandKey: CGKeyCode = 55
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: true
        ),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: false
        ) else { return }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, keyDown, keyUp, commandUp] {
            post(event, targetProcessID: targetProcessID)
        }
    }

    private static func pressCommandShiftLeft(targetProcessID: pid_t?) {
        let source = CGEventSource(stateID: .privateState)
        let commandKey: CGKeyCode = 55
        let shiftKey: CGKeyCode = 56
        let leftArrow: CGKeyCode = 123
        guard let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: true
        ),
        let shiftDown = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: true),
        let leftDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: true),
        let leftUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrow, keyDown: false),
        let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: shiftKey, keyDown: false),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: commandKey,
            keyDown: false
        ) else { return }

        commandDown.flags = .maskCommand
        shiftDown.flags = [.maskCommand, .maskShift]
        leftDown.flags = [.maskCommand, .maskShift]
        leftUp.flags = [.maskCommand, .maskShift]
        shiftUp.flags = .maskCommand
        commandUp.flags = []
        for event in [commandDown, shiftDown, leftDown, leftUp, shiftUp, commandUp] {
            post(event, targetProcessID: targetProcessID)
        }
    }

    private static func pressKey(
        _ keyCode: CGKeyCode,
        targetProcessID: pid_t?
    ) {
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else { return }
        keyDown.flags = []
        keyUp.flags = []
        post(keyDown, targetProcessID: targetProcessID)
        post(keyUp, targetProcessID: targetProcessID)
    }

    private static func post(_ event: CGEvent, targetProcessID: pid_t?) {
        SyntheticInputEvent.mark(event)
        if let targetProcessID {
            event.postToPid(targetProcessID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// The app running the HUD, so we can avoid probing or pasting into ourselves.
    static var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
