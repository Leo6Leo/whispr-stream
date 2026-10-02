import SwiftUI

/// The floating dictation HUD.
///
/// Active dictation uses a horizontal capsule: animated waveform on the left,
/// live transcript on the right. Model startup stays in the background.
struct HUDView: View {
    @ObservedObject var state: AppState
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void

    // Waveform geometry. The frame is derived from these so the bars can never
    // outgrow their slot and collide with the text.
    private let barCount = 14
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let barMaxHeight: CGFloat = 26

    private var waveformWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    /// Room for the drop shadow, which would otherwise be clipped to a hard
    /// rectangle by the panel bounds (sized to this view's fittingSize).
    static let shadowInset: CGFloat = 30

    @State private var history: [CGFloat] = []

    /// The leading slot is sized per phase. Giving the checkmark the waveform's
    /// full width would strand ~29pt of dead space on either side of it.
    private var leadingWidth: CGFloat {
        switch state.phase {
        case .inserted, .failed: return 24                              // glyph
        case .thinking: return 3 * 7 + 2 * 7                            // dots + gaps
        default: return waveformWidth
        }
    }

    private let surfaceCornerRadius: CGFloat = 24

    var body: some View {
        hudContent
        .background {
            RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .fill(Color.orange.opacity(state.isApproachingDictationLimit ? 0.18 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .strokeBorder(
                            state.isApproachingDictationLimit
                                ? Color.orange.opacity(0.72)
                                : Color.primary.opacity(0.07),
                            lineWidth: state.isApproachingDictationLimit ? 1.2 : 0.5
                        )
                }
        }
        // Flatten before shadowing: a shadow applied straight to a material
        // fill renders behind the blur and muddies the panel instead of
        // lifting it off the desktop.
        .compositingGroup()
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        .fixedSize()
        // Gesture belongs to the visible capsule, before the outer shadow
        // padding and fixed canvas are applied. This avoids turning the large
        // transparent animation canvas into a drag handle.
        .contentShape(RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in onDragChanged() }
                .onEnded { _ in onDragEnded() }
        )
        .padding(Self.shadowInset)
        // Centred in the fixed-size panel canvas, so growth animates from the
        // middle outward instead of snapping the window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One driver for text growth (both halves change together) and one for
        // phase. Separate modifiers per field fight each other mid-resize.
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: state.displayText)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: state.phase)
        .animation(.easeInOut(duration: 0.2), value: state.isApproachingDictationLimit)
        .onAppear { history = Array(repeating: 0, count: barCount) }
        .onChange(of: state.level) { _, new in
            var next = history
            next.removeFirst()
            next.append(new)
            history = next
        }
    }

    private var hudContent: some View {
        HStack(spacing: 14) {
            leading
                .frame(width: leadingWidth, height: barMaxHeight)

            label
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    // MARK: - Right hand side

    private var label: some View {
        HStack(spacing: 10) {
            labelText

            if state.isApproachingDictationLimit {
                Text(state.dictationCountdownLabel)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(minWidth: 26, alignment: .trailing)
                    .transition(.opacity)
                    .accessibilityLabel("\(state.dictationCountdownLabel) remaining")
            }
        }
    }

    @ViewBuilder
    private var labelText: some View {
        if !state.displayText.isEmpty && !isShowingFailure {
            transcript
                .transition(.opacity)
        } else {
            Text(placeholder)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .id(placeholder)
        }
    }

    private var isShowingFailure: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    private var placeholder: String {
        switch state.phase {
        case .thinking: return "Transcribing…"
        case .failed(let message): return message
        default: return "Listening…"
        }
    }

    private var transcript: some View {
        HStack(spacing: 0) {
            Text(state.committed)
                .foregroundStyle(.primary)
            Text(state.tail)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 15.5, weight: .medium, design: .rounded))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: 540, alignment: .leading)
    }

    // MARK: - Leading indicator

    @ViewBuilder
    private var leading: some View {
        switch state.phase {
        case .inserted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white, Color.accentColor)
                .symbolEffect(.bounce, options: .speed(1.8), value: state.phase)
                .transition(.scale(scale: 0.35).combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.orange)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        case .thinking:
            ThinkingDots()
                .transition(.opacity)
        default:
            waveform
                .transition(.opacity)
        }
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: barWidth, height: height(at: index))
                    .animation(
                        .spring(response: 0.28, dampingFraction: 0.62),
                        value: height(at: index)
                    )
            }
        }
        .frame(width: waveformWidth, height: barMaxHeight)
    }

    private func height(at index: Int) -> CGFloat {
        guard history.indices.contains(index) else { return barWidth }
        let value = history[index]
        // Taper the ends so it reads as a waveform rather than a bar chart.
        let position = Double(index + 1) / Double(barCount + 1)
        let taper = sin(position * .pi)
        let scaled = value * barMaxHeight * CGFloat(0.5 + 0.5 * taper)
        return max(barWidth, scaled)   // never thinner than a dot
    }
}

/// Three dots pulsing in sequence while the final pass decodes.
private struct ThinkingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.0 : 0.45)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.14),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
