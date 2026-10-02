import Foundation
import Combine

/// A bounded disagreement, not a probability or a new model-generated guess.
struct DictationReview: Codable, Equatable {
    let prefix: String
    let preferred: String
    let alternative: String
    let suffix: String

    var recommendedText: String { prefix + preferred + suffix }
    var alternativeText: String { prefix + alternative + suffix }
    var excerpt: String { String(prefix.suffix(65)) + "[" + preferred + "]" + String(suffix.prefix(65)) }

    static func parse(_ value: Any?, transcript: String) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let review = try? JSONDecoder().decode(Self.self, from: data),
              review.recommendedText == transcript,
              transcript.count <= 12_000,
              isTerm(review.preferred), isTerm(review.alternative),
              review.preferred.lowercased() != review.alternative.lowercased()
        else { return nil }
        return review
    }

    static func isTerm(_ text: String) -> Bool {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && term.count <= 48
            && !text.contains(where: { $0.isNewline })
            && term.split(whereSeparator: \.isWhitespace).count <= 3
            && term.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    func term(in text: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count >= prefix.count + suffix.count else { return nil }
        let middle = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        return Self.isTerm(middle) ? middle.trimmingCharacters(in: .whitespaces) : nil
    }
}

struct CorrectionRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let review: DictationReview
    let chosenText: String
    let model: String
    let manual: Bool
}

/// Text-only feedback stays on this Mac. Suggestions never rewrite output.
@MainActor
final class CorrectionStore: ObservableObject {
    static let shared = CorrectionStore()
    static let maximumRecords = 200
    @Published private(set) var records: [CorrectionRecord] = []
    @Published private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    let url: URL
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisprStream/Corrections.json")
        guard FileManager.default.fileExists(atPath: self.url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8_000_000 else {
                throw CocoaError(.fileReadTooLarge)
            }
            records = Array(try JSONDecoder().decode([CorrectionRecord].self, from: Data(contentsOf: self.url))
                .suffix(Self.maximumRecords))
        } catch {
            loadFailed = true
            errorMessage = "Saved corrections could not be read. Clear them to start again."
        }
    }

    var preferredTerms: [String] {
        // Learn only explicitly chosen candidates. A manually rewritten sentence
        // is useful feedback, but is not evidence for a particular word mapping.
        var votes: [String: [String: Int]] = [:]
        for record in records where !record.manual {
            guard record.chosenText == record.review.recommendedText
                    || record.chosenText == record.review.alternativeText else { continue }
            let choices = [record.review.preferred, record.review.alternative]
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.sorted()
            guard let term = record.review.term(in: record.chosenText), term.count >= 2 else { continue }
            votes[choices.joined(separator: "\u{0}"), default: [:]][term, default: 0] += 1
        }
        let winners = votes.values.compactMap { counts -> String? in
            let ranked = counts.sorted { $0.value > $1.value }
            guard let winner = ranked.first, winner.value >= 2,
                  winner.value - (ranked.dropFirst().first?.value ?? 0) >= 2 else { return nil }
            return winner.key
        }
        return Array(Set(winners).sorted().prefix(32))
    }

    @discardableResult
    func record(_ review: DictationReview, chosenText: String, model: String, manual: Bool) -> Bool {
        guard !loadFailed, !chosenText.isEmpty, chosenText.count <= 12_000 else { return false }
        guard manual || chosenText == review.recommendedText || chosenText == review.alternativeText else { return false }
        var next = records
        next.append(CorrectionRecord(id: UUID(), date: Date(), review: review,
                                     chosenText: chosenText, model: model, manual: manual))
        next = Array(next.suffix(Self.maximumRecords))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            records = next
            errorMessage = nil
            onChange?()
            return true
        } catch {
            errorMessage = "The choice was used, but could not be saved on this Mac."
            return false
        }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records = []
            loadFailed = false
            errorMessage = nil
            onChange?()
        } catch { errorMessage = "Saved corrections could not be cleared." }
    }
}
