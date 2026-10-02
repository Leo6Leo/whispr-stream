import AppKit

@MainActor
final class DictationReviewPanel: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let review: DictationReview
    private let editor = NSTextView()
    private let editScroll = NSScrollView()
    private let submitButton = NSButton(title: "Insert edited text", target: nil, action: nil)
    private let preferredButton: NSButton
    private let alternativeButton: NSButton
    private var completion: ((String?, Bool) -> Void)?

    init(review: DictationReview, savesChoices: Bool, completion: @escaping (String?, Bool) -> Void) {
        self.review = review
        self.completion = completion
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preferredButton = NSButton(title: "1 · " + review.preferred.trimmingCharacters(in: .whitespaces), target: nil, action: nil)
        alternativeButton = NSButton(title: "2 · " + review.alternative.trimmingCharacters(in: .whitespaces), target: nil, action: nil)
        super.init()
        window.title = "Check a word"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: "Which word did you say?")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let context = NSTextField(wrappingLabelWithString: review.excerpt)
        context.font = .systemFont(ofSize: 14)
        context.preferredMaxLayoutWidth = 472
        let detail = NSTextField(wrappingLabelWithString: "The last recognition passes disagreed on this word.")
        detail.textColor = .secondaryLabelColor
        let footer = NSTextField(wrappingLabelWithString: savesChoices
            ? "Your choice stays on this Mac and helps suggest familiar words. No audio is saved."
            : "Choices are not saved. You can enable learning in Settings.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.preferredMaxLayoutWidth = 472
        preferredButton.target = self
        preferredButton.action = #selector(choosePreferred)
        preferredButton.keyEquivalent = "1"
        preferredButton.keyEquivalentModifierMask = []
        alternativeButton.target = self
        alternativeButton.action = #selector(chooseAlternative)
        alternativeButton.keyEquivalent = "2"
        alternativeButton.keyEquivalentModifierMask = []
        for button in [preferredButton, alternativeButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.toolTip = button.title
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 472).isActive = true
        }
        window.defaultButtonCell = preferredButton.cell as? NSButtonCell
        let edit = NSButton(title: "Neither — edit text…", target: self, action: #selector(beginEditing))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelReview))
        cancel.keyEquivalent = "\u{1b}"
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.string = review.recommendedText
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editScroll.documentView = editor
        editScroll.hasVerticalScroller = true
        editScroll.borderType = .bezelBorder
        editScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        editScroll.isHidden = true
        submitButton.target = self
        submitButton.action = #selector(submitEdit)
        submitButton.isHidden = true

        let options = NSStackView(views: [preferredButton, alternativeButton])
        options.spacing = 12
        if preferredButton.intrinsicContentSize.width + alternativeButton.intrinsicContentSize.width > 440 {
            options.orientation = .vertical
            options.alignment = .leading
        }
        let actions = NSStackView(views: [edit, cancel, submitButton])
        actions.spacing = 12
        let stack = NSStackView(views: [title, detail, context, options, editScroll, actions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            context.widthAnchor.constraint(equalToConstant: 472),
            footer.widthAnchor.constraint(equalToConstant: 472),
            editScroll.widthAnchor.constraint(equalToConstant: 472),
        ])
        resizeToFit(minimumHeight: 300)
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func choosePreferred() { finish(review.recommendedText, manual: false) }
    @objc private func chooseAlternative() { finish(review.alternativeText, manual: false) }
    @objc private func cancelReview() { finish(nil, manual: false) }
    @objc private func submitEdit() {
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12_000 else { NSSound.beep(); return }
        finish(text, manual: true)
    }
    @objc private func beginEditing() {
        editScroll.isHidden = false
        submitButton.isHidden = false
        preferredButton.keyEquivalent = ""
        alternativeButton.keyEquivalent = ""
        window.defaultButtonCell = submitButton.cell as? NSButtonCell
        resizeToFit(minimumHeight: 420)
        window.makeFirstResponder(editor)
    }
    private func resizeToFit(minimumHeight: CGFloat) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: max(minimumHeight, window.contentView?.fittingSize.height ?? 0)))
    }
    func cancel() { finish(nil, manual: false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    private func finish(_ text: String?, manual: Bool) {
        guard let callback = completion else { return }
        completion = nil
        window.orderOut(nil)
        callback(text, manual)
    }
}
