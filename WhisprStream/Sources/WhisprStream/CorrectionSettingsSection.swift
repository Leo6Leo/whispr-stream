import SwiftUI

struct CorrectionSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var corrections = CorrectionStore.shared
    @ObservedObject private var training = TrainingDataStore.shared

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
            Toggle("Learn from edits I make after inserting", isOn: $settings.captureCorrections)
            HStack {
                Text("\(training.samples.count) captured corrections")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show local folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([training.storageRootURL])
                }
                .disabled(training.samples.isEmpty)
                Button("Delete captured corrections", role: .destructive) { try? training.deleteAll() }
                    .disabled(training.samples.isEmpty)
            }
            if let error = training.loadError { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Uncertain words")
        } footer: {
            Text("Only unresolved word disagreements ask for a choice. Learning saves up to 200 text choices locally and uses repeated selections as vocabulary hints; it keeps no audio. Turning learning off stops saving and using these hints; Clear removes them. Learning from edits watches the field you dictated into, through Accessibility only, until you send or move on. If you fix a word inside the inserted text, that sentence and its recording are kept on this Mac as a training sample. Nothing is ever uploaded.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
