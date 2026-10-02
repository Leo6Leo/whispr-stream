import SwiftUI

struct CorrectionSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var corrections = CorrectionStore.shared

    var body: some View {
        Section {
            Toggle("Check uncertain words before inserting", isOn: $settings.reviewUncertainWords)
            Toggle("Learn from my choices on this Mac", isOn: $settings.learnFromCorrections)
            if !corrections.preferredTerms.isEmpty {
                LabeledContent("Suggested vocabulary", value: corrections.preferredTerms.joined(separator: ", "))
            }
            HStack {
                Text("\(corrections.records.count) saved choices")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show local file") { NSWorkspace.shared.activateFileViewerSelecting([corrections.url]) }
                    .disabled(corrections.records.isEmpty)
                Button("Clear saved choices", role: .destructive) { corrections.clear() }
                    .disabled(corrections.records.isEmpty && corrections.errorMessage == nil)
            }
            if let error = corrections.errorMessage { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Uncertain words")
        } footer: {
            Text("Only unresolved word disagreements ask for a choice. Learning saves up to 200 text choices locally and uses repeated selections as vocabulary hints. No audio is saved or uploaded. Turning learning off stops saving and using these hints; Clear removes them.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
