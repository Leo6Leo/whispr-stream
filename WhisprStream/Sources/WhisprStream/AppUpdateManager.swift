import AppKit
import CryptoKit
import Darwin
import Foundation

/// Secure, in-place app updates backed by stable GitHub Release assets.
///
/// The GitHub API is only discovery metadata. The downloaded ZIP must carry a
/// detached Ed25519 signature made by the release key whose public half is
/// embedded in the currently running app. The archive is verified before it is
/// extracted, and the replacement bundle is validated again before a tiny
/// helper swaps it into place and relaunches it.
@MainActor
final class AppUpdateManager: ObservableObject {
    nonisolated static let archiveAssetName = "WhisprStream-macos-arm64.zip"
    nonisolated static let signatureAssetName = "WhisprStream-macos-arm64.zip.ed25519"
    nonisolated static let maximumArchiveBytes: Int64 = 250 * 1_024 * 1_024
    nonisolated static let maximumSignatureBytes = 1_024

    struct Release: Equatable, Sendable {
        let version: String
        let pageURL: URL
        let archiveURL: URL
        let signatureURL: URL
        let archiveBytes: Int64
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let repository: String?
    private let currentVersion: String
    private let bundleIdentifier: String
    private let publicKey: String?
    private let appBundleURL: URL
    private let session: URLSession
    private let developerFeedURL: URL?
    private var updateTask: Task<Void, Never>?
    private var updateOperationGeneration = 0
    private var lastRelease: Release?
    private var isSimulatingUpdate = false

    var canOpenReleasePage: Bool {
        lastRelease != nil || repository.flatMap(Self.repositoryReleasesURL) != nil
    }

    init(
        repository: String? = AppUpdateManager.configuredUpdateRepository(
            bundleValue: Bundle.main.object(
                forInfoDictionaryKey: "WhisprUpdateRepository"
            ) as? String
        ),
        currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0",
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        publicKey: String? = AppUpdateManager.configuredUpdatePublicKey(
            bundleValue: Bundle.main.object(
                forInfoDictionaryKey: "WhisprUpdatePublicKey"
            ) as? String
        ),
        appBundleURL: URL = Bundle.main.bundleURL,
        session: URLSession = .shared,
        developerFeedURL: URL? = AppUpdateManager.developerFeedURLFromEnvironment()
    ) {
        self.repository = repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentVersion = currentVersion
        self.bundleIdentifier = bundleIdentifier
        self.publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appBundleURL = appBundleURL.standardizedFileURL
        self.session = session
#if DEBUG
        self.developerFeedURL = developerFeedURL
#else
        // A release build always discovers updates from the configured GitHub
        // repository. Keep the local-feed seam compile-time disabled even if
        // a caller or inherited process environment supplies a value.
        self.developerFeedURL = nil
#endif
    }

    deinit { updateTask?.cancel() }

    func checkForUpdates() {
        guard updateTask == nil else { return }
        isSimulatingUpdate = false
        guard let repository, Self.isValidRepository(repository) else {
            status = .failed("This build does not have a valid GitHub update feed configured.")
            return
        }
        guard Self.isValidPublicKey(publicKey) else {
            status = .failed("This build does not contain a valid update-signing key.")
            return
        }

        status = .checking
        updateOperationGeneration &+= 1
        let generation = updateOperationGeneration
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.updateOperationGeneration == generation {
                    self.updateTask = nil
                }
            }

            do {
                let githubRelease = try await Self.fetchLatestRelease(
                    for: repository,
                    session: self.session,
                    developerFeedURL: self.developerFeedURL
                )
                if let release = try Self.release(
                    from: githubRelease,
                    currentVersion: self.currentVersion,
                    allowDeveloperAssetURLs: self.developerFeedURL != nil
                ) {
                    guard self.updateOperationGeneration == generation else { return }
                    self.lastRelease = release
                    self.status = .available(release)
                } else {
                    guard self.updateOperationGeneration == generation else { return }
                    self.status = .upToDate
                }
            } catch is CancellationError {
                guard self.updateOperationGeneration == generation else { return }
                self.status = .idle
            } catch {
                guard self.updateOperationGeneration == generation else { return }
                Log.write("update check failed: \(error.localizedDescription)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func installAvailableUpdate() {
        guard updateTask == nil, case let .available(release) = status else { return }
        if isSimulatingUpdate {
            installSimulatedUpdate(release)
            return
        }
        guard let publicKey else {
            status = .failed("This build does not contain an update-signing key.")
            return
        }

        status = .downloading(release)
        updateOperationGeneration &+= 1
        let generation = updateOperationGeneration
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.updateOperationGeneration == generation {
                    self.updateTask = nil
                }
            }

            do {
                let prepared = try await Self.downloadAndPrepare(
                    release: release,
                    publicKey: publicKey,
                    expectedBundleIdentifier: self.bundleIdentifier,
                    session: self.session
                )
                guard self.updateOperationGeneration == generation else { return }
                self.status = .installing(release)
                try await Self.stageAndLaunchInstaller(
                    prepared: prepared,
                    targetApp: self.appBundleURL,
                    helperSource: self.appBundleURL
                        .appendingPathComponent("Contents/Helpers/WhisprStreamUpdateInstaller")
                )
                Log.write("update: verified version \(release.version); terminating for replacement")
                NSApp.terminate(nil)
            } catch is CancellationError {
                guard self.updateOperationGeneration == generation else { return }
                self.status = .available(release)
            } catch {
                guard self.updateOperationGeneration == generation else { return }
                Log.write("update install failed: \(error.localizedDescription)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func openAvailableRelease() {
        if let lastRelease {
            NSWorkspace.shared.open(lastRelease.pageURL)
        } else if let repository, let url = Self.repositoryReleasesURL(repository) {
            NSWorkspace.shared.open(url)
        }
    }

    func cancelUpdate() {
        updateTask?.cancel()
    }

    /// Drives the real update UI through its states without network or disk
    /// changes. The runtime bundle-identifier gate keeps this out of public
    /// release behavior even though local app builds use release optimization.
    func presentSimulatedUpdate(
        version: String = "1.1.0",
        allowInThisBuild: Bool = DeveloperTestMode.isAvailable
    ) {
        guard allowInThisBuild else { return }
        if case .downloading = status { return }
        if case .installing = status { return }
        guard let pageURL = URL(string: "https://github.com/Leo6Leo/whispr-stream/releases"),
              let archiveURL = URL(string: "https://github.com/Leo6Leo/whispr-stream/releases/download/preview/WhisprStream-macos-arm64.zip"),
              let signatureURL = URL(string: "https://github.com/Leo6Leo/whispr-stream/releases/download/preview/WhisprStream-macos-arm64.zip.ed25519")
        else { return }

        let release = Release(
            version: version,
            pageURL: pageURL,
            archiveURL: archiveURL,
            signatureURL: signatureURL,
            archiveBytes: 1
        )
        updateTask?.cancel()
        updateOperationGeneration &+= 1
        updateTask = nil
        isSimulatingUpdate = true
        lastRelease = release
        status = .available(release)
    }

    private func installSimulatedUpdate(_ release: Release) {
        status = .downloading(release)
        updateOperationGeneration &+= 1
        let generation = updateOperationGeneration
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.updateOperationGeneration == generation {
                    self.updateTask = nil
                }
            }

            do {
                try await Task.sleep(nanoseconds: 900_000_000)
                guard self.updateOperationGeneration == generation else { return }
                self.status = .installing(release)
                try await Task.sleep(nanoseconds: 1_100_000_000)
                guard self.updateOperationGeneration == generation else { return }
                self.isSimulatingUpdate = false
                self.status = .upToDate
            } catch is CancellationError {
                guard self.updateOperationGeneration == generation else { return }
                self.status = .available(release)
            } catch {
                guard self.updateOperationGeneration == generation else { return }
                self.status = .available(release)
            }
        }
    }

    // MARK: - Discovery

    nonisolated static func fetchLatestRelease(
        for repository: String,
        session: URLSession,
        developerFeedURL: URL? = nil
    ) async throws -> GitHubRelease {
        let endpoint: URL
        if let developerFeedURL {
            guard isLocalDeveloperURL(developerFeedURL) else {
                throw UpdateError.invalidDeveloperFeed
            }
            endpoint = developerFeedURL
        } else {
            guard let githubEndpoint = URL(
                string: "https://api.github.com/repos/\(repository)/releases/latest"
            ) else {
                throw UpdateError.invalidRepository
            }
            endpoint = githubEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhisprStream", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.unavailable }
        guard response.statusCode == 200 else {
            throw response.statusCode == 404 ? UpdateError.noPublishedRelease : UpdateError.unavailable
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw UpdateError.noPublishedRelease }
        return release
    }

    nonisolated static func release(
        from githubRelease: GitHubRelease,
        currentVersion: String,
        allowDeveloperAssetURLs: Bool = false
    ) throws -> Release? {
        guard let latest = SemanticVersion(githubRelease.tagName),
              let current = SemanticVersion(currentVersion) else {
            throw UpdateError.invalidVersion
        }
        guard latest > current else { return nil }
        guard isSecureGitHubURL(githubRelease.pageURL) else { throw UpdateError.invalidReleaseURL }

        let archives = githubRelease.assets.filter { $0.name == archiveAssetName }
        let signatures = githubRelease.assets.filter { $0.name == signatureAssetName }
        guard archives.count == 1, signatures.count == 1 else { throw UpdateError.missingAssets }
        let archive = archives[0]
        let signature = signatures[0]
        guard archive.size > 0, archive.size <= maximumArchiveBytes,
              signature.size > 0, signature.size <= Int64(maximumSignatureBytes),
              isAllowedAssetURL(
                  archive.downloadURL,
                  allowDeveloperAssetURLs: allowDeveloperAssetURLs
              ),
              isAllowedAssetURL(
                  signature.downloadURL,
                  allowDeveloperAssetURLs: allowDeveloperAssetURLs
              ) else {
            throw UpdateError.invalidAssets
        }

        return Release(
            version: latest.description,
            pageURL: githubRelease.pageURL,
            archiveURL: archive.downloadURL,
            signatureURL: signature.downloadURL,
            archiveBytes: archive.size
        )
    }

    nonisolated static func isValidRepository(_ repository: String) -> Bool {
        repository.range(
            of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$",
            options: .regularExpression
        ) != nil
    }

    nonisolated static func repositoryReleasesURL(_ repository: String) -> URL? {
        guard isValidRepository(repository) else { return nil }
        return URL(string: "https://github.com/\(repository)/releases")
    }

    nonisolated static func isValidPublicKey(_ encoded: String?) -> Bool {
        guard let encoded,
              let data = Data(base64Encoded: encoded), data.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else {
            return false
        }
        return true
    }

    nonisolated static func configuredUpdateRepository(
        bundleValue: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
#if DEBUG
        return environment["WHISPR_UPDATE_REPOSITORY"] ?? bundleValue
#else
        // Repository and signing key are release trust roots. A process
        // environment inherited from Terminal or launchctl must not replace
        // values sealed into the signed public app.
        return bundleValue
#endif
    }

    nonisolated static func configuredUpdatePublicKey(
        bundleValue: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
#if DEBUG
        return environment["WHISPR_UPDATE_PUBLIC_KEY"] ?? bundleValue
#else
        return bundleValue
#endif
    }

    nonisolated static func developerFeedURLFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
#if DEBUG
        guard let rawValue = environment["WHISPR_UPDATE_FEED_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return URL(string: rawValue)
#else
        return nil
#endif
    }

    private nonisolated static func isSecureGitHubURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }

    private nonisolated static func isAllowedAssetURL(
        _ url: URL,
        allowDeveloperAssetURLs: Bool
    ) -> Bool {
        isSecureGitHubURL(url)
            || (allowDeveloperAssetURLs && isLocalDeveloperURL(url))
    }

    nonisolated static func isLocalDeveloperURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    // MARK: - Download and validation

    nonisolated static func downloadAndPrepare(
        release: Release,
        publicKey: String,
        expectedBundleIdentifier: String,
        session: URLSession
    ) async throws -> PreparedUpdate {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "WhisprStream-update-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let (temporaryArchive, archiveResponse) = try await session.download(from: release.archiveURL)
            try validateHTTPResponse(archiveResponse)
            let archive = root.appendingPathComponent(archiveAssetName)
            try manager.moveItem(at: temporaryArchive, to: archive)
            let actualBytes = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard Int64(actualBytes) == release.archiveBytes else { throw UpdateError.archiveSizeMismatch }

            let (signatureData, signatureResponse) = try await session.data(from: release.signatureURL)
            try validateHTTPResponse(signatureResponse)
            guard signatureData.count <= maximumSignatureBytes else { throw UpdateError.invalidSignature }
            try verifySignature(archive: archive, signatureData: signatureData, publicKey: publicKey)

            let extraction = root.appendingPathComponent("extracted", isDirectory: true)
            try manager.createDirectory(at: extraction, withIntermediateDirectories: false)
            try runDitto(["-x", "-k", archive.path, extraction.path])

            let candidates = try manager.contentsOfDirectory(
                at: extraction,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ).filter { $0.lastPathComponent == "WhisprStream.app" }
            guard candidates.count == 1 else { throw UpdateError.invalidArchive }
            let app = candidates[0]
            try validateReplacementBundle(
                at: app,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedVersion: release.version,
                expectedPublicKey: publicKey
            )
            // URLSession/ditto can preserve macOS's download quarantine. At
            // this point the complete archive has passed our pinned Ed25519
            // signature and bundle checks, so clear quarantine only from this
            // verified replacement. Otherwise a self-signed update may be
            // blocked on relaunch even though the user approved the installed
            // copy previously.
            try clearQuarantineRecursively(at: app)
            return PreparedUpdate(root: root, app: app)
        } catch {
            try? manager.removeItem(at: root)
            throw error
        }
    }

    nonisolated static func verifySignature(
        archive: URL,
        signatureData: Data,
        publicKey: String
    ) throws {
        let encodedSignature = String(data: signatureData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedSignature,
              let signature = Data(base64Encoded: encodedSignature), signature.count == 64,
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw UpdateError.invalidSignature
        }
        let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: archiveData) else {
            throw UpdateError.invalidSignature
        }
    }

    nonisolated static func validateReplacementBundle(
        at app: URL,
        expectedBundleIdentifier: String,
        expectedVersion: String,
        expectedPublicKey: String,
        currentOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == expectedBundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == expectedVersion,
              bundle.object(forInfoDictionaryKey: "WhisprUpdatePublicKey") as? String
                == expectedPublicKey,
              let minimumOS = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
              supports(minimumSystemVersion: minimumOS, currentOS: currentOS),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidReplacement
        }
    }

    nonisolated static func supports(
        minimumSystemVersion: String,
        currentOS: OperatingSystemVersion
    ) -> Bool {
        let parts = minimumSystemVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        var values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return false }
        while values.count < 3 { values.append(0) }
        return (values[0], values[1], values[2])
            <= (currentOS.majorVersion, currentOS.minorVersion, currentOS.patchVersion)
    }

    private nonisolated static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
    }

    private nonisolated static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidArchive }
    }

    nonisolated static func clearQuarantineRecursively(at root: URL) throws {
        let manager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw UpdateError.cannotClearQuarantine
        }

        try removeQuarantineAttribute(at: root)
        for case let item as URL in enumerator {
            try removeQuarantineAttribute(at: item)
        }
        if enumerationError != nil {
            throw UpdateError.cannotClearQuarantine
        }
    }

    private nonisolated static func removeQuarantineAttribute(at url: URL) throws {
        errno = 0
        let result = url.path.withCString {
            removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
        guard result == 0 || errno == ENOATTR else {
            throw UpdateError.cannotClearQuarantine
        }
    }

    // MARK: - Replacement handoff

    nonisolated static func stageAndLaunchInstaller(
        prepared: PreparedUpdate,
        targetApp: URL,
        helperSource: URL
    ) async throws {
        try await Task.detached {
            let manager = FileManager.default
            defer { try? manager.removeItem(at: prepared.root) }

            let target = targetApp.standardizedFileURL
            let parent = target.deletingLastPathComponent()
            guard target.pathExtension == "app", parent.path != "/",
                  manager.isWritableFile(atPath: parent.path) else {
                throw UpdateError.readOnlyInstallLocation
            }
            guard manager.isExecutableFile(atPath: helperSource.path) else {
                throw UpdateError.missingInstaller
            }

            let staged = parent.appendingPathComponent(
                ".WhisprStream.update-\(UUID().uuidString).app",
                isDirectory: true
            )
            do {
                try manager.copyItem(at: prepared.app, to: staged)
            } catch {
                throw UpdateError.cannotStageReplacement
            }

            let helperRoot = manager.temporaryDirectory.appendingPathComponent(
                "WhisprStream-installer-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try manager.createDirectory(
                    at: helperRoot,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let helper = helperRoot.appendingPathComponent("WhisprStreamUpdateInstaller")
                let readyFile = helperRoot.appendingPathComponent("ready")
                let healthFile = helperRoot.appendingPathComponent("health")
                let healthToken = UUID().uuidString
                try manager.copyItem(at: helperSource, to: helper)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

                let process = Process()
                process.executableURL = helper
                process.arguments = [
                    "--wait-pid", String(ProcessInfo.processInfo.processIdentifier),
                    "--staged-app", staged.path,
                    "--target-app", target.path,
                    "--cleanup-root", helperRoot.path,
                    "--ready-file", readyFile.path,
                    "--health-file", healthFile.path,
                    "--health-token", healthToken,
                ]
                try process.run()
                let deadline = Date().addingTimeInterval(5)
                while !manager.fileExists(atPath: readyFile.path) {
                    guard process.isRunning, Date() < deadline else {
                        throw UpdateError.cannotLaunchInstaller
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch is CancellationError {
                try? manager.removeItem(at: staged)
                try? manager.removeItem(at: helperRoot)
                throw CancellationError()
            } catch {
                try? manager.removeItem(at: staged)
                try? manager.removeItem(at: helperRoot)
                throw UpdateError.cannotLaunchInstaller
            }
        }.value
    }
}

struct PreparedUpdate: Sendable {
    let root: URL
    let app: URL
}

struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let downloadURL: URL
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let pageURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case draft, prerelease, assets
    }
}

enum UpdateError: LocalizedError {
    case invalidRepository
    case invalidDeveloperFeed
    case invalidVersion
    case noPublishedRelease
    case unavailable
    case invalidReleaseURL
    case missingAssets
    case invalidAssets
    case downloadFailed
    case archiveSizeMismatch
    case invalidSignature
    case invalidArchive
    case invalidReplacement
    case cannotClearQuarantine
    case readOnlyInstallLocation
    case missingInstaller
    case cannotStageReplacement
    case cannotLaunchInstaller

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "The GitHub update feed is invalid."
        case .invalidDeveloperFeed:
            return "The developer update feed must use HTTP on this Mac only."
        case .invalidVersion:
            return "The published release does not use a supported version number."
        case .noPublishedRelease:
            return "There is no published update yet."
        case .unavailable:
            return "Could not reach GitHub to check for updates."
        case .invalidReleaseURL:
            return "GitHub returned an invalid release URL."
        case .missingAssets:
            return "The release is missing its app ZIP or update signature."
        case .invalidAssets:
            return "The release contains invalid update assets."
        case .downloadFailed:
            return "The update could not be downloaded."
        case .archiveSizeMismatch:
            return "The downloaded update has an unexpected size."
        case .invalidSignature:
            return "The update signature is invalid. Nothing was installed."
        case .invalidArchive:
            return "The update archive has an invalid layout."
        case .invalidReplacement:
            return "The downloaded app does not match this WhisprStream release."
        case .cannotClearQuarantine:
            return "macOS would not allow the verified update to be prepared safely."
        case .readOnlyInstallLocation:
            return "WhisprStream cannot update from this location. Move it to Applications, reopen it, and try again."
        case .missingInstaller:
            return "This build is missing its update installer."
        case .cannotStageReplacement:
            return "The update cannot be prepared beside the installed app."
        case .cannotLaunchInstaller:
            return "The verified update is ready, but the installer could not start."
        }
    }
}

/// Stable semantic versions used by GitHub release tags and bundle metadata.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}
