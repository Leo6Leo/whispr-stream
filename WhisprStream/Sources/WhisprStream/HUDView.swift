import SwiftUI

/// The floating dictation HUD.
///
/// Active dictation uses a horizontal capsule: animated waveform on the left,
/// live transcript on the right. Model startup stays in the background.
struct HUDView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var settings = Settings.shared
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var transcriptOverflows = false

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

    /// Rainbow is the system-audio indicator, not decoration: it tells the
    /// user the Mac's output, not their voice, is being transcribed.
    private var isRainbow: Bool { settings.audioSource == .systemAudio }

    /// Drives the hue drift. Paused outside active phases so an idle HUD
    /// costs nothing.
    private var isAnimatingRainbow: Bool {
        isRainbow && (state.phase == .listening || state.phase == .thinking)
    }

    var body: some View {
        hudContent
        .background {
            RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
                        .fill(Color.orange.opacity(state.isApproachingDictationLimit ? 0.18 : 0))
                }
                .overlay { border }
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
        .animation(.easeInOut(duration: 0.2), value: state.notice)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: settings.audioSource)
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

    /// All three rings stay in the tree and only their opacity changes. An
    /// if/else here swapped view identity on every source switch, so SwiftUI
    /// tore one ring down while fading a new gradient ring in from nothing.
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: surfaceCornerRadius, style: .continuous)
        let atLimit = state.isApproachingDictationLimit
        return ZStack {
            shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                .opacity(atLimit || isRainbow ? 0 : 1)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimatingRainbow)) { context in
                let phase = RainbowPalette.phase(at: context.date)
                shape.strokeBorder(
                    AngularGradient(
                        colors: RainbowPalette.stops(phase: phase, span: 1, count: 7) {
                            RainbowPalette.accent(hue: $0, scheme: colorScheme)
                        },
                        center: .center,
                        angle: .degrees(phase * 360)
                    ),
                    lineWidth: 1
                )
            }
            .opacity(isRainbow && !atLimit ? (colorScheme == .dark ? 0.55 : 0.45) : 0)
            shape.strokeBorder(Color.orange.opacity(0.72), lineWidth: 1.2)
                .opacity(atLimit ? 1 : 0)
        }
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
        if let notice = state.notice {
            // A passing message while still listening, for example when ⌥S
            // cannot switch sources. Orange like the limit warning: something
            // needs the user, but nothing was lost.
            Text(notice)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.orange)
                .transition(.opacity)
                .id(notice)
        } else if !state.displayText.isEmpty && !isShowingFailure {
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
        default:
            return settings.audioSource == .systemAudio ? "Listening to system audio…" : "Listening…"
        }
    }

    private var transcript: some View {
        HUDLiveText(
            committed: state.committed,
            tail: state.tail,
            committedColor: isRainbow ? .clear : .primary,
            tailColor: .secondary
        )
        .overlay {
            if isRainbow { rainbowCommittedText }
        }
        .font(.system(size: 15.5, weight: .medium, design: .rounded))
        .lineLimit(1)
        // Lay the line out at full width and slide it inside a clipped
        // window. Head truncation re-laid the whole line on every preview,
        // jumping every glyph left; a pinned trailing edge lets the capsule
        // spring glide the sentence instead.
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            transcriptOverflows = width > Self.transcriptMaxWidth
        }
        .frame(maxWidth: Self.transcriptMaxWidth, alignment: .trailing)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: transcriptOverflows ? .clear : .black, location: 0),
                    .init(color: .black, location: 0.06),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // The line crosses the window's edge once per utterance; fade the
            // edge in rather than snapping the leftmost glyphs away.
            .animation(.easeInOut(duration: 0.2), value: transcriptOverflows)
        }
    }

    private static let transcriptMaxWidth: CGFloat = 540

    /// The settled words carry the color; the changing tail stays
    /// `.secondary` so the sentence still visibly settles. Only the gradient
    /// redraws with the hue drift: the text is a mask with the same glyph
    /// motion, so the drift never rebuilds the transcript.
    private var rainbowCommittedText: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimatingRainbow)) { context in
            let phase = RainbowPalette.phase(at: context.date)
            LinearGradient(
                colors: RainbowPalette.stops(phase: phase, span: 0.55) {
                    RainbowPalette.text(hue: $0, scheme: colorScheme)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .mask {
            HUDLiveText(
                committed: state.committed,
                tail: state.tail,
                committedColor: .white,
                tailColor: .clear
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            ThinkingDots(colors: isRainbow
                ? [0.0, 0.33, 0.62].map { RainbowPalette.accent(hue: $0, scheme: colorScheme) }
                : Array(repeating: Color.accentColor, count: 3))
                .transition(.opacity)
        default:
            waveform
                .transition(.opacity)
        }
    }

    /// Microphone mode keeps the plain 1.0.3 bars: one height spring per bar
    /// and nothing else in the chain. The rainbow bars, with their hue drift,
    /// exist only while system audio is the source; the two sets swap with a
    /// fade driven by the root `audioSource` animation.
    @ViewBuilder
    private var waveform: some View {
        if isRainbow {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimatingRainbow)) { context in
                let phase = RainbowPalette.phase(at: context.date)
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        rainbowBar(at: index, phase: phase)
                    }
                }
            }
            .frame(width: waveformWidth, height: barMaxHeight)
            .transition(.opacity)
        } else {
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
            .transition(.opacity)
        }
    }

    /// Colour lives outside the height spring. Inside it, every level update
    /// would carry the fill along on an underdamped spring, so the drifting
    /// hue overshot its target and the bars shimmered.
    private func rainbowBar(at index: Int, phase: Double) -> some View {
        Capsule(style: .continuous)
            .frame(width: barWidth, height: height(at: index))
            .animation(
                .spring(response: 0.28, dampingFraction: 0.62),
                value: height(at: index)
            )
            .foregroundStyle(rainbowBarColor(at: index, phase: phase))
    }

    /// The bars span ~60% of the wheel so neighbours blend instead of
    /// striping red-next-to-violet.
    private func rainbowBarColor(at index: Int, phase: Double) -> Color {
        let hue = phase + 0.6 * Double(index) / Double(barCount - 1)
        return RainbowPalette.accent(hue: hue, scheme: colorScheme).opacity(0.95)
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
    let colors: [Color]
    @State private var animating = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(colors[i])
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
