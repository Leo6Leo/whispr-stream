import AppKit
import SwiftUI

extension AppUpdateManager.Status {
    var availableRelease: AppUpdateManager.Release? {
        guard case let .available(release) = self else { return nil }
        return release
    }

    var showsUpdateAttention: Bool {
        switch self {
        case .available, .downloading, .installing:
            return true
        case .idle, .checking, .upToDate, .failed:
            return false
        }
    }
}

/// The checked-in WhisprStream wordmark, adapted only for legibility when the
/// user chooses Dark appearance. No alternate or generated logo is substituted.
struct WhisprStreamBrandLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    private var image: NSImage? {
        guard let url = Bundle.main.url(
            forResource: "whisprstream-logo",
            withExtension: "png"
        ), let source = NSImage(contentsOf: url) else { return nil }

        // The original file intentionally has export whitespace around the
        // artwork. Crop only those transparent pixels for native UI layout;
        // the bundled brand asset itself remains byte-for-byte unchanged.
        let visibleArtwork = NSRect(x: 33, y: 44, width: 862, height: 116)
        guard source.size.width >= visibleArtwork.maxX,
              source.size.height >= visibleArtwork.maxY else { return source }
        let cropped = NSImage(size: visibleArtwork.size)
        cropped.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: visibleArtwork.size),
            from: visibleArtwork,
            operation: .copy,
            fraction: 1
        )
        cropped.unlockFocus()
        return cropped
    }

    var body: some View {
        Group {
            if let image {
                if colorScheme == .dark {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .colorInvert()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                // Development binaries launched outside the assembled app do
                // not have bundle resources. Keep that workflow usable without
                // inventing a replacement mark.
                Text("WhisprStream")
                    .font(.system(size: 25, weight: .semibold, design: .serif))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("WhisprStream")
    }
}

struct AppUpdatePromptView: View {
    @ObservedObject var updates: AppUpdateManager
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            actions
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.bar)
        }
        .frame(width: 470)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            WhisprStreamBrandLogo()
                .frame(width: 235, height: 34, alignment: .leading)
                .padding(.bottom, 20)

            switch updates.status {
            case let .available(release):
                availableContent(release)
            case let .downloading(release):
                progressContent(
                    title: "Downloading version \(release.version)…",
                    detail: "WhisprStream will verify the update before anything is installed."
                )
            case let .installing(release):
                progressContent(
                    title: "Installing version \(release.version)…",
                    detail: "WhisprStream will relaunch as soon as the update is ready."
                )
            case .checking:
                progressContent(
                    title: "Checking for updates…",
                    detail: "Looking for the latest stable WhisprStream release."
                )
            case .upToDate:
                statusContent(
                    title: "WhisprStream is up to date.",
                    detail: "You already have the latest stable version.",
                    symbol: "checkmark.circle.fill",
                    color: .green
                )
            case let .failed(message):
                statusContent(
                    title: "The update couldn’t be completed.",
                    detail: message,
                    symbol: "exclamationmark.triangle.fill",
                    color: .orange
                )
            case .idle:
                statusContent(
                    title: "Check for a new version.",
                    detail: "WhisprStream can securely install stable updates in place.",
                    symbol: "arrow.down.circle",
                    color: .accentColor
                )
            }
        }
    }

    private func availableContent(_ release: AppUpdateManager.Release) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keep WhisprStream at its best.")
                .font(.system(size: 25, weight: .semibold))

            Text("Version \(release.version) is ready with the latest reliability and performance improvements.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Label {
                Text("Your speech engine, models, vocabulary, and shortcuts stay exactly where they are.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(12)
            .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 20)

            Button("View release notes…", action: updates.openAvailableRelease)
                .buttonStyle(.link)
                .font(.system(size: 13))
                .padding(.top, 16)
        }
    }

    private func progressContent(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    private func statusContent(
        title: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(color)
            }
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch updates.status {
            case .available:
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Update & Relaunch", action: updates.installAvailableUpdate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .downloading:
                Button("Cancel") {
                    updates.cancelUpdate()
                    onDismiss()
                }
            case .installing:
                EmptyView()
            case .failed:
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again", action: updates.checkForUpdates)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Button("Not Now", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Check for Updates", action: updates.checkForUpdates)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .checking:
                Button("Cancel") {
                    updates.cancelUpdate()
                    onDismiss()
                }
            case .upToDate:
                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
