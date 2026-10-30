import SwiftUI

/// Keep dictation and meeting text growth on the same spring.
enum LiveTranscriptMotion {
    static let spring = Spring(response: 0.30, dampingRatio: 0.85)
    static let animation = Animation.spring(spring)
    static let duration = 0.30
}
