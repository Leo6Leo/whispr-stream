import SwiftUI

/// Word-by-word springs for the live transcript, matching the Meeting Notes
/// motion: every new word lifts 4 pt, grows from 94% and fades in on its own
/// light spring, 25 ms after the word before it. Earlier words keep their
/// arrival time, so a new preview never replays them.
enum HUDWordMotion {
    static let spring = Spring(response: 0.24, dampingRatio: 0.68)
    static let lift: CGFloat = 4
    static let initialScale: CGFloat = 0.94
    /// Long enough for the last staggered word's spring to come to rest.
    static let retireAfter = LiveTextAnimation.maximumStagger + 0.55
}

/// The whole line is one `Text` drawn by a renderer, not a view per word.
/// The HUD line slides while it grows, and SwiftUI animates each view's frame
/// separately: a newly inserted word view would land at its final position
/// while its neighbours were still sliding, so the two would overlap. Inside
/// one `Text`, every word moves with the line.
struct HUDLiveText: View {
    let committed: String
    let tail: String
    let committedColor: Color
    let tailColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation = LiveTextAnimation(retireAfter: HUDWordMotion.retireAfter)

    private var text: String { committed + tail }

    private var presentation: LiveTextAnimation {
        if reduceMotion {
            return LiveTextAnimation(stableText: text, retireAfter: HUDWordMotion.retireAfter)
        }
        var next = animation
        next.update(to: text, at: .now)
        return next
    }

    var body: some View {
        let current = presentation
        let words = current.words(committedCount: committed.count)
        Group {
            if #available(macOS 15.0, *) {
                TimelineView(.animation(paused: current.animationEnd == nil)) { timeline in
                    marked(words)
                        .textRenderer(HUDWordRenderer(now: timeline.date))
                }
            } else {
                plain(words)
            }
        }
        .contentTransition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { animation = current }
        .onChange(of: text) { _, _ in animation = current }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                animation = LiveTextAnimation(stableText: text, retireAfter: HUDWordMotion.retireAfter)
            }
        }
        .task(id: animation.animationEnd) {
            guard let end = animation.animationEnd else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            animation.settle(at: .now)
        }
    }

    @available(macOS 15.0, *)
    private func marked(_ words: [LiveTextAnimation.Word]) -> Text {
        words.reduce(Text("")) { text, word in
            var part = Text(word.text).foregroundColor(color(of: word))
            if let startsAt = word.startsAt {
                part = part.customAttribute(HUDWordArrival(startsAt: startsAt))
            }
            return text + part
        }
    }

    private func plain(_ words: [LiveTextAnimation.Word]) -> Text {
        words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(color(of: word))
        }
    }

    private func color(of word: LiveTextAnimation.Word) -> Color {
        word.isCommitted ? committedColor : tailColor
    }
}

@available(macOS 15.0, *)
private struct HUDWordArrival: TextAttribute {
    let startsAt: Date
}

@available(macOS 15.0, *)
private struct HUDWordRenderer: TextRenderer {
    let now: Date

    /// Room for the lift and the spring's overshoot.
    var displayPadding: EdgeInsets {
        EdgeInsets(top: 2, leading: 2, bottom: HUDWordMotion.lift + 2, trailing: 2)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let arrival = run[HUDWordArrival.self] else {
                    context.draw(run)
                    continue
                }
                let elapsed = now.timeIntervalSince(arrival.startsAt)
                // Staggered words hold their place, invisible, until their turn.
                guard elapsed > 0 else { continue }
                // The underdamped spring overshoots slightly past 1, which
                // gives scale and lift their bounce; opacity is clamped.
                let progress = HUDWordMotion.spring.value(target: 1.0, time: elapsed)
                let bounds = run.typographicBounds.rect
                let scale = HUDWordMotion.initialScale + (1 - HUDWordMotion.initialScale) * progress
                var copy = context
                copy.opacity *= min(1, max(0, progress))
                copy.translateBy(x: bounds.midX, y: bounds.midY + HUDWordMotion.lift * (1 - progress))
                copy.scaleBy(x: scale, y: scale)
                copy.translateBy(x: -bounds.midX, y: -bounds.midY)
                copy.draw(run)
            }
        }
    }
}
