import AppKit
import SwiftUI

/// Floating panel that asks which of two recognised words the user said.
///
/// One uncertain word is a single question. Several become steps over the
/// same sentence: each step is the same 1 / 2 / 3 choice, and the result is
/// inserted after the last one.
///
/// AppKit owns only the window. The content is SwiftUI so it shares the
/// onboarding/update-prompt vocabulary: rounded titles, soft cards with an
/// accent border for the active choice, and a `.bar` action strip.
@MainActor
final class DictationReviewPanel: NSObject, NSWindowDelegate {
    private let window: NSPanel
    /// Text to insert (nil when cancelled), whether it was typed by hand, and
    /// for each word in reading order whether its alternative was picked.
    private var completion: ((String?, Bool, [Bool]) -> Void)?

    static let confirmSound = "review-confirm"

    /// `playsSound` follows the app's sound setting. The confirm sound plays
    /// on the keypress itself, so the caller skips its own finish sound.
    init(reviews: [DictationReview], savesChoices: Bool, playsSound: Bool = false,
         completion: @escaping (String?, Bool, [Bool]) -> Void) {
        precondition(!reviews.isEmpty, "a review needs at least one word")
        self.completion = completion
        if playsSound { SoundPlayer.shared.prepareBundled(Self.confirmSound) }
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: DictationReviewView.width, height: 320),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        super.init()
        window.title = reviews.count == 1 ? "Check a word" : "Check \(reviews.count) words"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(rootView: DictationReviewView(
            reviews: reviews,
            savesChoices: savesChoices,
            playsSound: playsSound,
            finish: { [weak self] text, manual, picks in self?.finish(text, manual: manual, picks: picks) }
        ))
        // The window follows the view, so switching to the editor grows it
        // instead of clipping the text box.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func cancel() { finish(nil, manual: false, picks: []) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    private func finish(_ text: String?, manual: Bool, picks: [Bool]) {
        guard let callback = completion else { return }
        completion = nil
        // Fade rather than vanish; the result is delivered at once so
        // insertion never waits on the animation.
        let window = self.window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            window.alphaValue = 1
        }
        callback(text, manual, picks)
    }
}

struct DictationReviewView: View {
    static let width: CGFloat = 520
    /// Characters of context kept on each side of the word.
    private static let contextLength = 65

    let reviews: [DictationReview]
    let savesChoices: Bool
    let playsSound: Bool
    let finish: (String?, Bool, [Bool]) -> Void

    private enum Choice { case preferred, alternative }

    /// Which word is being asked about, in reading order.
    @State private var step = 0
    /// +1 slides the next word in from the right, -1 from the left.
    @State private var direction: CGFloat = 1
    /// The answer for each word so far; nil until that step is answered.
    @State private var picks: [Choice?] = []
    /// What the editor opened with, for Undo Changes.
    @State private var editBase = ""

    private var isStepped: Bool { reviews.count > 1 }
    private var review: DictationReview { reviews[min(step, reviews.count - 1)] }

    @State private var hovered: Choice?
    /// Set the moment a word is picked, by click or key. The card confirms
    /// with a checkmark before the panel closes, so a keypress never feels
    /// like it went nowhere.
    @State private var chosen: Choice?
    @State private var isEditing = false
    @State private var draft = ""
    /// Height of the choice layout. The editor takes exactly this height so
    /// switching modes never resizes the window, which is what made the
    /// transition stutter.
    @State private var bodyHeight: CGFloat = 0
    /// Bumped by Undo Changes so the editor reloads and reselects the word.
    @State private var resetToken = 0

    /// The sentence previews whichever word the pointer is on. With nothing
    /// hovered it shows the best guess, which is also what Return inserts.
    private var shown: Choice { chosen ?? hovered ?? pick(at: step) ?? .preferred }

    private func pick(at index: Int) -> Choice? {
        picks.indices.contains(index) ? picks[index] : nil
    }

    private static let modeSpring = Animation.spring(response: 0.34, dampingFraction: 0.88)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                // Both layouts stay in the tree and crossfade in place.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 18) {
                        sentenceCard
                        // Each word's choices are their own view, so moving
                        // to the next word slides one set out and the next in.
                        choices
                            .id(step)
                            .transition(.asymmetric(
                                insertion: .offset(x: 36 * direction).combined(with: .opacity),
                                removal: .offset(x: -36 * direction).combined(with: .opacity)
                            ))
                        privacyNote
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                    .opacity(isEditing ? 0 : 1)
                    .offset(x: isEditing ? -24 : 0)
                    .disabled(isEditing)
                    .accessibilityHidden(isEditing)

                    // Inserted only while editing: a hidden-but-present text
                    // view keeps a caret, and macOS then floats its Writing
                    // Tools pill over the choices.
                    if isEditing {
                        editor
                            .transition(.opacity.combined(with: .offset(x: 24)))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
        .frame(width: Self.width)
        .background(.regularMaterial)
        .onAppear { if picks.count != reviews.count { picks = Array(repeating: nil, count: reviews.count) } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if isEditing || (isStepped && step > 0) {
                    Button(action: isEditing ? endEditing : previousStep) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.accentColor.opacity(0.14)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(ChoicePressStyle())
                    .keyboardShortcut(isEditing ? KeyEquivalent("[") : .leftArrow,
                                      modifiers: isEditing ? .command : [])
                    .help(isEditing ? "Back to the choices (⌘[)" : "Previous word (←)")
                    .accessibilityLabel(isEditing ? "Back to choices" : "Previous word")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                Text(isEditing ? "Edit the text" : "Which word did you say?")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .contentTransition(.opacity)
                if isStepped && !isEditing {
                    Spacer(minLength: 8)
                    StepDots(count: reviews.count, current: step)
                        .transition(.opacity)
                }
            }
            .frame(height: 28)
            .animation(Self.modeSpring, value: step)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        let term = review.preferred.trimmingCharacters(in: .whitespaces)
        if isEditing { return "Type to replace “\(term)”, or fix anything else." }
        guard isStepped else { return "WhisprStream wasn’t sure about the highlighted word." }
        let ordinals = ["first", "second", "third", "fourth"]
        let which = ordinals.indices.contains(step) ? ordinals[step] : "next"
        return "WhisprStream wasn’t sure about \(reviews.count) words. Here’s the \(which)."
    }

    // MARK: - Sentence

    private var sentenceCard: some View {
        sentence
            .font(.system(size: 15))
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackground(active: false))
            .animation(.easeInOut(duration: 0.15), value: hovered)
            .animation(.easeInOut(duration: 0.18), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(currentText)
    }

    /// Surrounding words recede to `.secondary` and the uncertain word is set
    /// in the accent colour on a tinted highlight, so it reads at a glance in
    /// both appearances without relying on brackets. With several words, the
    /// ones already answered show the pick in accent and the ones still to
    /// come are underlined, so the whole question is visible at once.
    private var sentence: Text {
        var text = AttributedString(Self.leadingContext(reviews[0].prefix))
        text.swiftUI.foregroundColor = .secondary
        for (index, item) in reviews.enumerated() {
            let choice: Choice? = index == step ? shown : pick(at: index)
            let word = choice == .alternative ? item.alternative : item.preferred
            let leadingSpace = String(word.prefix(while: \.isWhitespace))
            let trailingSpace = String(word.reversed().prefix(while: \.isWhitespace).reversed())
            let core = word.trimmingCharacters(in: .whitespaces)

            var space = AttributedString(leadingSpace)
            space.swiftUI.foregroundColor = .secondary
            text += space
            var mark: AttributedString
            if index == step {
                // Thin spaces pad the highlight so it isn't flush against the glyphs.
                mark = AttributedString("\u{2009}" + core + "\u{2009}")
                mark.swiftUI.foregroundColor = chosen == nil ? .accentColor : .white
                mark.swiftUI.backgroundColor = chosen == nil ? Color.accentColor.opacity(0.24) : .accentColor
                mark.swiftUI.font = .system(size: 15, weight: .semibold)
            } else if pick(at: index) != nil {
                mark = AttributedString(core)
                mark.swiftUI.foregroundColor = .accentColor
                mark.swiftUI.font = .system(size: 15, weight: .medium)
            } else {
                mark = AttributedString(core)
                mark.swiftUI.foregroundColor = .primary
                mark.swiftUI.underlineStyle = Text.LineStyle(pattern: .dot, color: .secondary)
            }
            text += mark

            let gap: String
            if index + 1 < reviews.count {
                let next = reviews[index + 1]
                gap = String(item.suffix.dropLast(next.preferred.count + next.suffix.count))
            } else {
                gap = Self.trailingContext(item.suffix)
            }
            var after = AttributedString(trailingSpace + gap)
            after.swiftUI.foregroundColor = .secondary
            text += after
        }
        return Text(text)
    }

    /// The sentence with every answered word applied and the rest at their
    /// best guess.
    private var currentText: String {
        DictationReview.compose(reviews, alternatives: reviews.indices.map { pick(at: $0) == .alternative })
    }

    private static func leadingContext(_ prefix: String) -> String {
        guard prefix.count > contextLength else { return prefix }
        let tail = String(prefix.suffix(contextLength))
        return "…" + tail.drop(while: \.isWhitespace)
    }

    private static func trailingContext(_ suffix: String) -> String {
        guard suffix.count > contextLength else { return suffix }
        let head = String(suffix.prefix(contextLength))
        return String(head.reversed().drop(while: \.isWhitespace).reversed()) + "…"
    }

    // MARK: - Choices

    private var choices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { choiceButtons }
            VStack(spacing: 8) { choiceButtons }
        }
        .background {
            // Return keeps what is shown, like a default button: the best
            // guess, or this word's earlier answer when the user stepped back.
            Button("") { choose(pick(at: step) ?? .preferred) }
                .keyboardShortcut(.defaultAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var choiceButtons: some View {
        choiceButton(.preferred, number: 1, word: review.preferred, note: "Best guess")
        choiceButton(.alternative, number: 2, word: review.alternative, note: "Also possible")
    }

    private func choiceButton(_ choice: Choice, number: Int, word: String, note: String) -> some View {
        let active = shown == choice
        let confirmed = chosen == choice
        let term = word.trimmingCharacters(in: .whitespaces)
        return Button {
            choose(choice)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(active ? Color.white : Color.secondary)
                        .opacity(confirmed ? 0 : 1)
                        .scaleEffect(confirmed ? 0.4 : 1)
                    // Draws itself, the same stroke-on motion the brand uses.
                    CheckmarkShape()
                        .trim(from: 0, to: confirmed ? 1 : 0)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 11)
                        .animation(.easeOut(duration: 0.16).delay(0.03), value: confirmed)
                }
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(confirmed ? Color.white : (active ? Color.accentColor : Color.primary.opacity(0.08)))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(term)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(confirmed ? Color.white : (active ? Color.accentColor : Color.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(confirmed ? "Inserted" : note)
                        .font(.system(size: 11, weight: confirmed ? .medium : .regular))
                        .foregroundStyle(confirmed ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    cardBackground(active: active)
                    // The confirmed card floods with solid accent.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                        .opacity(confirmed ? 1 : 0)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ChoicePressStyle())
        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        .onHover { inside in
            guard chosen == nil else { return }
            if inside { hovered = choice } else if hovered == choice { hovered = nil }
        }
        // Press-in, overshoot, settle — plus one ring that expands and fades.
        // A key press gets the same physical response as a click.
        .keyframeAnimator(initialValue: Pop(), trigger: confirmed) { content, pop in
            content
                .scaleEffect(pop.scale)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .scaleEffect(1 + 0.14 * pop.ripple)
                        .opacity(pop.ripple > 0 && pop.ripple < 1 ? Double(1 - pop.ripple) * 0.8 : 0)
                        .allowsHitTesting(false)
                }
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                CubicKeyframe(0.95, duration: 0.05)
                SpringKeyframe(1.035, duration: 0.12, spring: .init(response: 0.18, dampingRatio: 0.55))
                SpringKeyframe(1.0, duration: 0.14, spring: .init(response: 0.22, dampingRatio: 0.8))
            }
            KeyframeTrack(\.ripple) {
                LinearKeyframe(0.001, duration: 0.04)
                CubicKeyframe(1, duration: 0.3)
            }
        }
        // The other card steps back.
        .scaleEffect(chosen != nil && !confirmed ? 0.97 : 1)
        .opacity(chosen != nil && !confirmed ? 0.35 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: active)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: chosen)
        .help("Insert “\(term)” (\(number))")
        .accessibilityLabel("Insert \(term)")
        .accessibilityHint(note)
    }

    private var privacyNote: some View {
        Label {
            Text(savesChoices
                 ? "Your choice stays on this Mac and helps suggest familiar words. No audio is saved."
                 : "Choices aren’t saved. You can turn on learning in Settings.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ReviewTextEditor(
                text: $draft,
                highlight: wordRange(in: draft),
                resetToken: resetToken,
                onSubmit: submitEdit,
                onCancel: { finish(nil, false, []) }
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            // A text field reads best on a neutral surface; the accent
            // border alone says it has focus.
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
            }

            HStack(spacing: 14) {
                keyHint("Return", "insert")
                keyHint("⇧ Return", "new line")
                keyHint("esc", "cancel")
                Spacer(minLength: 0)
            }
        }
        .frame(height: max(bodyHeight, 150))
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                }
            Text(action)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(.secondary)
    }

    /// The current word's range, while the sentence around it is untouched.
    /// Once the user has rewritten more than the word, nothing is preselected.
    private func wordRange(in text: String) -> NSRange? {
        guard text == editBase else { return nil }
        let alternatives = reviews.indices.map { pick(at: $0) == .alternative }
        let word = alternatives[step] ? review.alternative : review.preferred
        let leading = word.prefix(while: \.isWhitespace).count
        let core = word.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return nil }
        // Composing up to this word yields: earlier text, the word, then this
        // word's own suffix. Strip the last two to find where the word starts.
        let through = DictationReview.compose(Array(reviews[...step]), alternatives: alternatives)
        let start = through.utf16.count - review.suffix.utf16.count - word.utf16.count
            + String(word.prefix(leading)).utf16.count
        guard start >= 0, start + core.utf16.count <= text.utf16.count else { return nil }
        return NSRange(location: start, length: core.utf16.count)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if isEditing {
                if draft != editBase {
                    Button {
                        draft = editBase
                        resetToken += 1
                    } label: {
                        Label("Undo Changes", systemImage: "arrow.uturn.backward")
                    }
                    .transition(.opacity)
                }
                Spacer()
                Button("Cancel") { finish(nil, false, []) }
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: submitEdit)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button(action: beginEditing) {
                    HStack(spacing: 8) {
                        Text("Neither — Edit Text…")
                        KeyCap("3")
                    }
                }
                .keyboardShortcut("3", modifiers: [])
                .help("Edit the text yourself (3)")
                Spacer()
                Button("Cancel") { finish(nil, false, []) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.large)
        .animation(.easeInOut(duration: 0.15), value: draft == editBase)
    }

    /// A short beat of confirmation, then the panel closes. Long enough to
    /// see the checkmark land, short enough not to feel like a wait.
    ///
    /// With several words, the same beat confirms this word and then slides
    /// in the next; only the last one closes the panel.
    private func choose(_ choice: Choice) {
        guard chosen == nil, !isEditing, picks.indices.contains(step) else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { chosen = choice }
        confirmFeedback()
        picks[step] = choice
        let answered = step
        if answered + 1 < reviews.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                guard step == answered, !isEditing else { return }
                direction = 1
                hovered = nil
                withAnimation(Self.stepSpring) {
                    chosen = nil
                    step = answered + 1
                }
            }
            return
        }
        let alternatives = picks.map { $0 == .alternative }
        let text = DictationReview.compose(reviews, alternatives: alternatives)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Editing during the beat takes over; the editor submits instead.
            guard !isEditing else { return }
            finish(text, false, alternatives)
        }
    }

    private static let stepSpring = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// Revisits the previous word; its answer stays selected until changed.
    private func previousStep() {
        guard step > 0, chosen == nil else { return }
        direction = -1
        hovered = nil
        withAnimation(Self.stepSpring) { step -= 1 }
    }

    /// Sound and haptic fire together, on the same frame the card starts
    /// its press-in.
    private func confirmFeedback() {
        if playsSound { SoundPlayer.shared.playBundled(DictationReviewPanel.confirmSound) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func beginEditing() {
        let base = currentText
        if draft.isEmpty || draft == editBase { draft = base }
        editBase = base
        hovered = nil
        // Opening the editor during a pick's confirmation beat cancels the
        // step change or close that beat was waiting for. The pick itself is
        // kept, but `chosen` must clear or every choice stays locked once the
        // editor is left again.
        withAnimation(Self.modeSpring) {
            chosen = nil
            isEditing = true
        }
    }

    private func endEditing() {
        withAnimation(Self.modeSpring) { isEditing = false }
    }

    private func submitEdit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12_000 else { NSSound.beep(); return }
        confirmFeedback()
        finish(text, true, [])
    }

    // MARK: - Surfaces

    /// The onboarding card: faint fill and hairline at rest, accent tint and
    /// a firmer accent border when active.
    private func cardBackground(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: active ? 1.5 : 1)
            }
    }
}

/// Press feedback matching `PrimaryButtonStyle`: a small spring squeeze.
private struct ChoicePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A plain-text editor tuned for fixing one dictated sentence.
///
/// SwiftUI's `TextEditor` can't set a selection or customise Return, so this
/// wraps `NSTextView` directly: it opens with the uncertain word selected and
/// pointed out by the system find indicator, so typing replaces it at once.
/// Return inserts; Shift- or Option-Return adds a line.
private struct ReviewTextEditor: NSViewRepresentable {
    @Binding var text: String
    let highlight: NSRange?
    let resetToken: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        // Dictated text is literal: no smart quotes, dashes or replacements.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.insertionPointColor = .controlAccentColor
        view.selectedTextAttributes = [
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.3),
            .foregroundColor: NSColor.labelColor,
        ]
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        view.typingAttributes = attributes
        context.coordinator.attributes = attributes
        context.coordinator.load(text, into: view, selecting: highlight)
        context.coordinator.lastReset = resetToken
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if context.coordinator.lastReset != resetToken || view.string != text {
            context.coordinator.lastReset = resetToken
            context.coordinator.load(text, into: view, selecting: highlight)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewTextEditor
        var attributes: [NSAttributedString.Key: Any] = [:]
        var lastReset = 0

        init(_ parent: ReviewTextEditor) { self.parent = parent }

        func load(_ text: String, into view: NSTextView, selecting range: NSRange?) {
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            // Wait for the panel to be on screen and key before focusing,
            // or the find indicator has no window to draw in.
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                let target = range ?? NSRange(location: (view.string as NSString).length, length: 0)
                view.setSelectedRange(target)
                view.scrollRangeToVisible(target)
                if range != nil { view.showFindIndicator(for: target) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // NSTextView turns Esc into word completion; here it means Cancel.
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}

private struct Pop {
    var scale: CGFloat = 1
    var ripple: CGFloat = 0
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.85))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// A small outlined key, used to show a button's bare-key shortcut.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
            }
    }
}

/// Onboarding's progress dots: the current step stretches into a capsule,
/// answered steps stay accent, the rest are faint.
private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
            Text("\(current + 1) of \(count)")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .padding(.leading, 4)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Word \(current + 1) of \(count)")
    }
}
