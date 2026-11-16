import AppKit
import SwiftUI

/// A first-responder AppKit surface is more reliable than SwiftUI keyboard
/// shortcuts for recording punctuation, function keys, and modifier-only keys.
private final class TriggerShortcutCaptureNSView: NSView {
    var onCandidate: ((Result<TriggerShortcut, TriggerShortcutValidationError>) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
            onCancel?()
            return
        }
        guard !event.isARepeat else { return }
        do {
            onCandidate?(.success(try TriggerShortcut.candidate(from: event)))
        } catch let error as TriggerShortcutValidationError {
            onCandidate?(.failure(error))
        } catch {
            onCandidate?(.failure(.unsupportedKey))
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard TriggerKey.allCases.contains(where: { $0.keyCode == event.keyCode }) else {
            return
        }
        guard let key = TriggerKey.allCases.first(where: { $0.keyCode == event.keyCode }),
              event.modifierFlags.contains(key.flag) else {
            return
        }
        do {
            onCandidate?(.success(try TriggerShortcut.candidate(from: event)))
        } catch let error as TriggerShortcutValidationError {
            onCandidate?(.failure(error))
        } catch {
            onCandidate?(.failure(.unsupportedKey))
        }
    }
}

private struct TriggerShortcutCaptureView: NSViewRepresentable {
    let onCandidate: (Result<TriggerShortcut, TriggerShortcutValidationError>) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> TriggerShortcutCaptureNSView {
        let view = TriggerShortcutCaptureNSView(frame: .zero)
        view.onCandidate = onCandidate
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: TriggerShortcutCaptureNSView, context: Context) {
        nsView.onCandidate = onCandidate
        nsView.onCancel = onCancel
    }
}

/// The modal editor shared by Settings and onboarding.
struct TriggerShortcutRecorderSheet: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: TriggerShortcut?
    @State private var validationError: TriggerShortcutValidationError?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Record a shortcut")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Press the key combination you want to use for dictation.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                shortcutCard(settings.triggerShortcut)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.26), lineWidth: 1)
                    }

                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(candidate.map(\.compactDisplay) ?? "Press your desired shortcut")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(candidate == nil ? .secondary : Color.primary)
                    Text(candidate?.spokenDisplay ?? "Use a modifier with a key, or F13–F24 by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 112)

            if let validationError {
                Label(validationError.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Escape cancels recording. The current shortcut stays active until you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TriggerShortcutCaptureView(
                onCandidate: { result in
                    switch result {
                    case let .success(shortcut):
                        candidate = shortcut
                        validationError = nil
                    case let .failure(error):
                        validationError = error
                    }
                },
                onCancel: { dismiss() }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(candidate == nil)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onAppear { settings.beginTriggerShortcutCapture() }
        .onDisappear { settings.endTriggerShortcutCapture() }
    }

    private func shortcutCard(_ shortcut: TriggerShortcut) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .foregroundStyle(Color.accentColor)
            Text(shortcut.compactDisplay)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Text(shortcut.spokenDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shortcut.accessibilityLabel)
    }

    private func save() {
        guard let candidate else { return }
        settings.triggerShortcut = candidate
        dismiss()
    }
}

/// Compact reusable control for a saved recording shortcut.
struct TriggerShortcutEditor: View {
    @ObservedObject var settings: Settings
    var compact: Bool = false
    @State private var isShowingRecorder = false

    var body: some View {
        HStack(spacing: 10) {
            if !compact {
                Text("Recording shortcut")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(settings.triggerShortcut.compactDisplay)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                // Only the compact layout needs a floor to keep its button
                // from shifting; the full one pins its buttons trailing with
                // a spacer, and in the Settings detail column 132 pt pushed
                // "Reset to Default" into truncation.
                .frame(minWidth: compact ? 110 : nil, alignment: .leading)
                .accessibilityLabel(settings.triggerShortcut.accessibilityLabel)

            if !compact {
                Spacer(minLength: 12)
            }

            Button("Change…") {
                isShowingRecorder = true
            }

            if !compact {
                Button("Reset to Default") {
                    settings.resetTriggerShortcut()
                }
                .disabled(settings.triggerShortcut == .defaultValue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingRecorder) {
            TriggerShortcutRecorderSheet(settings: settings)
        }
    }
}
