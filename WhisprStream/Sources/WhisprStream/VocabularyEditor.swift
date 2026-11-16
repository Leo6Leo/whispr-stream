import Foundation
import SwiftUI

/// The Vocabulary block in General settings.
///
/// Deliberately two separate things: a text field that only ever holds the term
/// being typed, and the saved terms as chips underneath it.
///
/// The previous single `NSTokenField` held both at once, and that is what made
/// the list so easy to lose — the saved vocabulary *was* the field's text, so
/// ⌘A followed by any key, a held backspace, or a drag-select plus Delete wiped
/// every term in one gesture. Each of those went straight to `UserDefaults` and
/// pushed an empty context to the running sidecar, with nothing to undo it.
///
/// Now nothing typed into the entry field can reach the saved list. Removal has
/// exactly one path — clicking a chip's own ✕ — and even that is reversible
/// while the Undo row is showing.
struct VocabularySection: View {
    @ObservedObject var settings: Settings

    /// The term being typed. Never holds saved terms, by construction.
    @State private var draft = ""

    /// Backspace into an empty field arms the last chip rather than deleting it;
    /// a second backspace removes it. Two keystrokes, and the first one is
    /// visible, so the destructive one is never a surprise.
    @State private var armedTerm: String?

    /// When the last backspace landed, to tell a deliberate second press from
    /// key repeat. Without this, *holding* backspace still walks the whole list
    /// — arm, remove, arm, remove — which is the exact gesture this rewrite
    /// exists to stop. Repeats arrive ~30 ms apart, deliberate presses far
    /// slower, so one term per hold is the worst case.
    @State private var lastDeleteAt: Date?

    /// Set when a term already in the list is re-added, to pulse the existing
    /// chip. Silently swallowing the word reads as the app dropping input.
    @State private var duplicateTerm: String?

    @State private var lastChange: VocabularyChange?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument = VocabularyDocument(entries: [])
    @State private var importPreview: ImportPreview?
    @State private var transferError: String?
    @FocusState private var entryFocused: Bool

    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// A reversible vocabulary mutation, with the whole list as it stood
    /// before the change.
    ///
    /// Snapshotting the list rather than just the term means Undo also restores
    /// the term's original position, so recovering doesn't quietly reorder the
    /// vocabulary.
    private struct VocabularyChange: Equatable, Identifiable {
        let id = UUID()
        let summary: String
        let previous: [String]
    }

    private struct ImportPreview: Identifiable {
        let id = UUID()
        let entries: [String]
        let fileDuplicates: Int
        let existingMatches: Int
    }

    private var terms: [String] { settings.vocabularyEntries }

    var body: some View {
        Section {
            entryRow

            if !terms.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        TermChip(
                            term: term,
                            isArmed: armedTerm == term,
                            isDuplicate: duplicateTerm == term,
                            remove: { remove(term) }
                        )
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.vertical, 2)
            }

            if let change = lastChange {
                undoRow(change)
            }
        } header: {
            HStack {
                Text("Vocabulary")
                Spacer()
                if !terms.isEmpty {
                    Text("\(terms.count)")
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                        .transition(.opacity)
                }

                Menu {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Vocabulary…", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        exportDocument = VocabularyDocument(entries: terms)
                        isExporting = true
                    } label: {
                        Label("Export Vocabulary…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(terms.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help("Import or export vocabulary")
            }
        } footer: {
            footer
        }
        .animation(spring, value: terms)
        .animation(spring, value: lastChange)
        .animation(spring, value: armedTerm)
        // Auto-hide the Undo row, but only after long enough to notice it. The
        // `id:` restarts the clock on each new change instead of letting an
        // earlier timer close the row on a fresh deletion or import.
        .task(id: lastChange?.id) {
            guard lastChange != nil else { return }
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            lastChange = nil
        }
        .task(id: duplicateTerm) {
            guard duplicateTerm != nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            duplicateTerm = nil
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [VocabularyTransfer.contentType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                prepareImport(from: url)
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    transferError = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: VocabularyTransfer.contentType,
            defaultFilename: "WhisprStream Vocabulary"
        ) { result in
            if case let .failure(error) = result,
               (error as NSError).code != NSUserCancelledError {
                transferError = error.localizedDescription
            }
        }
        .alert(item: $importPreview) { preview in
            let newCount = preview.entries.count - preview.existingMatches
            let message = "This file contains \(newCount) new entries. "
                + "They will be added to your current vocabulary; existing entries will stay unchanged. "
                + "\(preview.fileDuplicates + preview.existingMatches) duplicate entries will be ignored."
            if newCount == 0 {
                return Alert(
                    title: Text("No New Vocabulary"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
            return Alert(
                title: Text("Import Vocabulary"),
                message: Text(message),
                primaryButton: .default(Text("Import \(newCount) New")) {
                    applyImport(preview)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Vocabulary Transfer Failed",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )
        ) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "Unknown error")
        }
    }

    // MARK: - Entry

    private var entryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(draft.isEmpty ? .secondary : Color.accentColor)
                .font(.system(size: 13))

            TextField(
                "",
                text: $draft,
                prompt: Text("Add a word or phrase")
            )
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($entryFocused)
                .onSubmit { commitDraft() }
                .onChange(of: draft) { _, _ in armedTerm = nil }
                // Backspace on an empty field arms the last chip instead of
                // removing it outright. `.ignored` while there is text to
                // delete leaves normal editing completely untouched.
                .onKeyPress(.delete) {
                    guard draft.isEmpty, let last = terms.last else { return .ignored }
                    let now = Date()
                    defer { lastDeleteAt = now }
                    if let previous = lastDeleteAt, now.timeIntervalSince(previous) < 0.3 {
                        return .handled  // key repeat, not a second decision
                    }
                    if armedTerm == last {
                        remove(last)
                    } else {
                        armedTerm = last
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard armedTerm != nil else { return .ignored }
                    armedTerm = nil
                    return .handled
                }
                .onChange(of: entryFocused) { _, focused in
                    if !focused { armedTerm = nil }
                }

            if !draft.isEmpty {
                Button("Add") { commitDraft() }
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    entryFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: entryFocused ? 1.2 : 0.8
                )
        }
        .animation(spring, value: draft.isEmpty)
        .animation(.easeOut(duration: 0.15), value: entryFocused)
        // The whole rounded row is the target so the field remains easy to
        // focus even when the draft is empty.
        .contentShape(Rectangle())
        .onTapGesture { entryFocused = true }
    }

    private func undoRow(_ change: VocabularyChange) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11))
            Text(change.summary)
            Spacer()
            Button("Undo") {
                settings.setVocabulary(change.previous)
                lastChange = nil
            }
            .controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Names and jargon you say often. Type a word or phrase, then press Return.")

            // Measured, not guessed: lowercase `claude` was enough to beat
            // `Cloud`, but lowercase `codex` did not beat `CodeX`.
            Text("Write each term the way you want it spelled back — ")
                + Text("Codex").fontWeight(.semibold)
                + Text(" is recognised where ")
                + Text("codex").fontWeight(.semibold)
                + Text(" isn't.")

            Text("Applies immediately. Keep the list tight; every term is re-read on each pass.")
        }
        .foregroundStyle(.secondary)
        .font(.callout)
    }

    // MARK: - Mutation

    private func commitDraft() {
        add(draft)
        draft = ""
    }

    private func add(_ raw: String) {
        guard let term = VocabularyEntry.normalize(raw) else { return }
        // Case-sensitive on purpose: casing is the lever that makes biasing
        // work at all, so `Codex` and `codex` are genuinely different entries.
        guard !terms.contains(term) else {
            duplicateTerm = term
            return
        }
        // The pending snapshot predates this term, so undoing after an add would
        // silently swallow it. Retire the offer instead of restoring a stale list.
        lastChange = nil
        settings.setVocabulary(terms + [term])
    }

    private func remove(_ term: String) {
        let previous = terms
        guard previous.contains(term) else { return }
        armedTerm = nil
        settings.setVocabulary(previous.filter { $0 != term })
        lastChange = VocabularyChange(summary: "Removed \(term)", previous: previous)
    }

    private func prepareImport(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let parsed = try VocabularyTransfer.parse(Data(contentsOf: url))
            let existingMatches = parsed.entries.filter { terms.contains($0) }.count
            importPreview = ImportPreview(
                entries: parsed.entries,
                fileDuplicates: parsed.duplicatesSkipped,
                existingMatches: existingMatches
            )
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func applyImport(_ preview: ImportPreview) {
        let previous = terms
        let updated = VocabularyTransfer.appending(preview.entries, to: previous)
        guard updated != previous else { return }

        settings.setVocabulary(updated)
        lastChange = VocabularyChange(
            summary: "Imported \(updated.count - previous.count) entries",
            previous: previous
        )
    }
}

// MARK: - Chip

private struct TermChip: View {
    let term: String
    let isArmed: Bool
    let isDuplicate: Bool
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(isArmed ? Color.red : .primary)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isArmed ? Color.red : .secondary)
                    // Never hidden outright, only dimmed: a chip that is
                    // removable only once you are already on it can't be
                    // discovered, and a ✕ that appears on hover would have to
                    // resize the chip — moving the target out from under the
                    // cursor mid-approach.
                    .opacity(hovering || isArmed ? 1 : 0.3)
            }
            .buttonStyle(.plain)
            .help("Remove “\(term)”")
            .accessibilityLabel("Remove \(term)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(fill)
                .overlay {
                    Capsule().strokeBorder(
                        isArmed ? Color.red.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
                }
        }
        .scaleEffect(isDuplicate ? 1.08 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.26, dampingFraction: 0.62), value: isDuplicate)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isArmed)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if isArmed { return .red.opacity(0.13) }
        if isDuplicate { return .accentColor.opacity(0.22) }
        return .primary.opacity(hovering ? 0.10 : 0.06)
    }
}

// MARK: - Layout

/// Left-to-right flow that wraps onto new lines.
///
/// The chips have to wrap: at 20-odd terms a single scrolling row hides most of
/// what the user has configured, which is the same reason the old token field
/// set `wraps = true`.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // SwiftUI probes with 0 and nil widths while sizing. Treating a 0 as a
        // real bound would wrap after every chip and report a tall column.
        let proposed = proposal.width ?? .infinity
        let maxWidth = proposed > 0 ? proposed : .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        var widestChip: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            widestChip = max(widestChip, size.width)
            lineHeight = max(lineHeight, size.height)
        }
        // The 0 probe is how containers read a minimum width. Answering it
        // with the whole list on one line made that the minimum, and the
        // split view in Settings squeezed its sidebar trying to honour it.
        // The layout can wrap down to its widest chip, so that is the floor.
        if proposal.width == 0 {
            return CGSize(width: widestChip, height: y + lineHeight)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
