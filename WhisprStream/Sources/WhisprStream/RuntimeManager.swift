import CryptoKit
import Darwin
import Foundation

struct RuntimeIntegrityError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Authenticates the complete installed runtime against a digest embedded in
/// the signed app. The digest includes every regular file and symlink, so
/// replacing code or adding an importable module changes the trusted root.
struct RuntimeIntegrityCheck {
    private static let formatMarker = Data("whispr-runtime-tree-v1\0".utf8)

    private enum EntryKind: UInt8 {
        case directory = 0x44 // D
        case file = 0x46 // F
        case symbolicLink = 0x4c // L
    }

    private struct Entry {
        let relativePath: String
        let relativePathData: Data
        let url: URL
        let kind: EntryKind
        let linkTarget: Data?
    }

    private struct FileMaterial {
        let size: Int
        let digest: Data
    }

    static func run(
        runtimeDirectory: URL,
        expectedDigest: String
    ) async -> Result<RuntimeManifest, RuntimeIntegrityError> {
        await Task.detached(priority: .utility) {
            runSynchronously(
                runtimeDirectory: runtimeDirectory,
                expectedDigest: expectedDigest
            )
        }.value
    }

    static func runSynchronously(
        runtimeDirectory: URL,
        expectedDigest: String
    ) -> Result<RuntimeManifest, RuntimeIntegrityError> {
        do {
            let actualDigest = try contentDigest(at: runtimeDirectory)
            guard actualDigest == expectedDigest.lowercased() else {
                return .failure(RuntimeIntegrityError(
                    message: "The installed speech engine was modified. Repair or reinstall it."
                ))
            }
            let manifestData = try Data(
                contentsOf: runtimeDirectory.appendingPathComponent("manifest.json")
            )
            let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: manifestData)
            return .success(manifest)
        } catch let error as RuntimeIntegrityError {
            return .failure(error)
        } catch {
            return .failure(RuntimeIntegrityError(
                message: "The installed speech engine could not be verified. Repair or reinstall it."
            ))
        }
    }

    static func contentDigest(at runtimeDirectory: URL) throws -> String {
        let forward = try digestSnapshot(
            entries: entries(at: runtimeDirectory),
            reverseReadOrder: false
        )
        let reverse = try digestSnapshot(
            entries: entries(at: runtimeDirectory),
            reverseReadOrder: true
        )
        guard forward == reverse else {
            throw RuntimeIntegrityError(message: "The speech engine changed while it was being verified.")
        }
        return forward
    }

    private static func digestSnapshot(
        entries: [Entry],
        reverseReadOrder: Bool
    ) throws -> String {
        var fileMaterials: [Data: FileMaterial] = [:]
        let readOrder = reverseReadOrder ? Array(entries.reversed()) : entries
        for entry in readOrder where entry.kind == .file {
            fileMaterials[entry.relativePathData] = try fileMaterial(of: entry.url)
        }

        var digest = SHA256()
        digest.update(data: formatMarker)
        for entry in entries {
            digest.update(data: Data([entry.kind.rawValue]))
            digest.update(data: lengthData(entry.relativePathData.count))
            digest.update(data: entry.relativePathData)
            switch entry.kind {
            case .directory:
                break
            case .file:
                guard let material = fileMaterials[entry.relativePathData] else {
                    throw RuntimeIntegrityError(message: "The speech engine contains an unreadable file.")
                }
                digest.update(data: lengthData(material.size))
                digest.update(data: material.digest)
            case .symbolicLink:
                guard let target = entry.linkTarget else {
                    throw RuntimeIntegrityError(message: "The speech engine contains an invalid symlink.")
                }
                digest.update(data: lengthData(target.count))
                digest.update(data: target)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func entries(at runtimeDirectory: URL) throws -> [Entry] {
        let manager = FileManager.default
        let requestedRoot = runtimeDirectory.standardizedFileURL
        let rootValues = try requestedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RuntimeIntegrityError(message: "The speech engine directory is unsafe.")
        }
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw RuntimeIntegrityError(message: "The speech engine directory could not be read.")
        }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var result: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            let candidatePath = url.standardizedFileURL.path
            guard candidatePath.hasPrefix(prefix) else {
                throw RuntimeIntegrityError(message: "The speech engine contains an escaping path.")
            }
            let relativePath = String(candidatePath.dropFirst(prefix.count))
            guard !relativePath.isEmpty,
                  !relativePath.split(separator: "/").contains(".."),
                  let relativeData = relativePath.data(using: .utf8) else {
                throw RuntimeIntegrityError(message: "The speech engine contains an invalid path.")
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                let target = try manager.destinationOfSymbolicLink(atPath: url.path)
                guard !target.hasPrefix("/"), let targetData = target.data(using: .utf8) else {
                    throw RuntimeIntegrityError(message: "The speech engine contains an unsafe symlink.")
                }
                let resolved = url.deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                guard resolved.path == root.path || resolved.path.hasPrefix(prefix) else {
                    throw RuntimeIntegrityError(message: "The speech engine contains an escaping symlink.")
                }
                result.append(Entry(
                    relativePath: relativePath,
                    relativePathData: relativeData,
                    url: url,
                    kind: .symbolicLink,
                    linkTarget: targetData
                ))
            } else if values.isDirectory == true {
                result.append(Entry(
                    relativePath: relativePath,
                    relativePathData: relativeData,
                    url: url,
                    kind: .directory,
                    linkTarget: nil
                ))
            } else if values.isRegularFile == true {
                result.append(Entry(
                    relativePath: relativePath,
                    relativePathData: relativeData,
                    url: url,
                    kind: .file,
                    linkTarget: nil
                ))
            } else {
                throw RuntimeIntegrityError(message: "The speech engine contains an unsupported file type.")
            }
        }
        return result.sorted {
            $0.relativePathData.lexicographicallyPrecedes($1.relativePathData)
        }
    }

    private static func lengthData(_ value: Int) -> Data {
        var length = UInt64(value).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }

    private static func fileMaterial(of file: URL) throws -> FileMaterial {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RuntimeIntegrityError(message: "The speech engine contains an unreadable file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw RuntimeIntegrityError(message: "The speech engine contains an unsafe file.")
        }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw RuntimeIntegrityError(message: "The speech engine changed while it was being verified.")
        }
        return FileMaterial(size: Int(before.st_size), digest: Data(hasher.finalize()))
    }
}

struct RuntimeHealthError: Error {
    let message: String
}

struct RuntimeHealthCheck {
    static let timeout: TimeInterval = 20

    static func run(
        python: URL,
        manifest: RuntimeManifest,
        includeOptionalModels: Bool = FeatureFlags.optionalModelsEnabled
    ) async -> Result<Void, RuntimeHealthError> {
        await Task.detached(priority: .utility) {
            runSynchronously(
                python: python,
                manifest: manifest,
                includeOptionalModels: includeOptionalModels
            )
        }.value
    }

    static func runSynchronously(
        python: URL,
        manifest: RuntimeManifest,
        includeOptionalModels: Bool = FeatureFlags.optionalModelsEnabled
    ) -> Result<Void, RuntimeHealthError> {
        let expectedJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: manifest.dependencyVersions),
           let value = String(data: data, encoding: .utf8) {
            expectedJSON = value
        } else {
            return .failure(RuntimeHealthError(message: "The speech engine dependency manifest is invalid."))
        }
        let requiredJSON: String
        let requiredModules = FeatureFlags.requiredRuntimeModules(
            includeOptionalModels: includeOptionalModels
        )
        if let data = try? JSONSerialization.data(withJSONObject: requiredModules),
           let value = String(data: data, encoding: .utf8) {
            requiredJSON = value
        } else {
            return .failure(RuntimeHealthError(message: "The speech engine dependency requirements are invalid."))
        }

        let code = """
        import importlib, importlib.metadata, json, sys
        required = \(requiredJSON)
        expected = \(expectedJSON)
        if tuple(sys.version_info[:2]) != (3, 12):
            raise RuntimeError("Python 3.12 is required")
        for module, distribution in required.items():
            importlib.import_module(module)
            if distribution in expected:
                actual = importlib.metadata.version(distribution)
                if actual != expected[distribution]:
                    raise RuntimeError(f"{distribution} {actual} does not match {expected[distribution]}")
        print(json.dumps({"status": "ok"}))
        """

        let process = Process()
        process.executableURL = python
        process.arguments = PythonProcessEnvironment.codeArguments(code)
        process.environment = PythonProcessEnvironment.sanitized()
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failure(RuntimeHealthError(message: "The speech engine could not be started: \(error.localizedDescription)"))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failure(RuntimeHealthError(message: "The speech engine health check timed out."))
        }

        let stderr = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RuntimeHealthError(message: detail.isEmpty ? "The speech engine health check failed." : detail))
        }
        return .success(())
    }
}

struct RuntimeConfiguration {
    static func value(
        environmentValue: String?,
        bundleValue: String?,
        allowsEnvironmentOverride: Bool
    ) -> String? {
        allowsEnvironmentOverride ? environmentValue ?? bundleValue : bundleValue
    }
}

/// Locates, verifies, and atomically installs the private speech engine.
@MainActor
final class RuntimeManager: ObservableObject {
    static let shared = RuntimeManager()

    enum Phase: Equatable {
        case ready
        case missing
        case checking
        case incompatible(String)
        case checkingStorage
        case insufficientStorage(required: Int64, available: Int64)
        case downloading
        case verifying
        case installing
        case failed(String)

        /// Why an installed engine cannot be used as it is, or nil when it
        /// works or an install is under way.
        var repairReason: String? {
            switch self {
            case .missing: "The speech engine is not installed."
            case let .incompatible(reason), let .failed(reason): reason
            default: nil
            }
        }
    }

    /// Whether a phase change should interrupt someone who already finished
    /// setup: the engine went from working (or being checked) to needing a
    /// repair. Failures that end an install the user is watching are shown
    /// inline by the installer UI and must not also raise an alert.
    static func shouldPromptForRepair(from previous: Phase?, to current: Phase) -> Bool {
        guard current.repairReason != nil else { return false }
        switch previous {
        case nil, .ready, .checking: return true
        default: return false
        }
    }

    @Published private(set) var phase: Phase = .missing
    @Published private(set) var requiresRepairConfirmation = false

    private var installTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var simulatedRuntimeInstalled = false

    private init() { refresh() }

    var executableURL: URL? {
        if developerTestMode {
            guard simulatedRuntimeInstalled else { return nil }
            return developmentPythonURL
        }
        if isDevelopmentBuild,
           let override = ProcessInfo.processInfo.environment["WHISPR_PYTHON"],
           isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        let managed = runtimeDirectory.appendingPathComponent("bin/python3.12")
        guard phase == .ready,
              isExecutable(managed.path),
              let expectedContentChecksum else {
            return developmentPythonURL
        }
        switch RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: runtimeDirectory,
            expectedDigest: expectedContentChecksum
        ) {
        case let .success(manifest)
            where manifest.compatibilityError(requiredRuntimeVersion: requiredRuntimeVersion) == nil:
            return managed
        default:
            phase = .incompatible("The installed speech engine was modified. Repair or reinstall it.")
            return nil
        }
    }

    var isReady: Bool {
        if developerTestMode { return simulatedRuntimeInstalled && developmentPythonURL != nil }
        if isDevelopmentBuild,
           ProcessInfo.processInfo.environment["WHISPR_PYTHON"].map(isExecutable) == true {
            return true
        }
        if isDevelopmentBuild, developmentPythonURL != nil { return true }
        return phase == .ready
            && isExecutable(runtimeDirectory.appendingPathComponent("bin/python3.12").path)
            && expectedContentChecksum != nil
    }
    var isDeveloperTestMode: Bool { developerTestMode }
    var isDeveloperTestModeAvailable: Bool { DeveloperTestMode.isAvailable }
    var isUsingDevelopmentEngine: Bool {
        guard !developerTestMode else { return false }
        if isDevelopmentBuild,
           let override = ProcessInfo.processInfo.environment["WHISPR_PYTHON"] {
            return isExecutable(override)
        }
        return isDevelopmentBuild && developmentPythonURL != nil
    }
    var canManageEngineInstallation: Bool {
        if developerTestMode { return true }
        guard !isUsingDevelopmentEngine else { return false }
        return runtimeArchiveURL != nil
            && expectedChecksum != nil
            && expectedContentChecksum != nil
            && runtimeConfigurationVersion != nil
            && runtimeArchiveBytes != nil
            && runtimeInstalledBytes != nil
    }

    var installMessage: String? {
        guard !isReady else { return nil }
        if developerTestMode {
            return "Developer test mode simulates the engine download and reuses your local development runtime."
        }
        guard runtimeArchiveURL != nil, expectedChecksum != nil else {
            return "This build does not include a speech-engine installer."
        }
        return nil
    }

    var storageSummary: String? {
        guard let archiveBytes = runtimeArchiveBytes, let installedBytes = runtimeInstalledBytes else { return nil }
        let available = StorageCapacity.availableBytes(at: runtimeDirectory)
            .map(StorageCapacity.formatted) ?? "Unavailable"
        return "Download: \(StorageCapacity.formatted(archiveBytes)) · installed: \(StorageCapacity.formatted(installedBytes)) · available: \(available)"
    }

    func refresh() {
        guard installTask == nil else { return }
        if developerTestMode {
            phase = simulatedRuntimeInstalled && developmentPythonURL != nil ? .ready : .missing
            return
        }
        if isDevelopmentBuild,
           ProcessInfo.processInfo.environment["WHISPR_PYTHON"].map(isExecutable) == true {
            phase = .ready
            return
        }
        if developmentPythonURL != nil && isDevelopmentBuild {
            phase = .ready
            return
        }
        if case .checking = phase { return }

        guard FileManager.default.isExecutableFile(atPath: runtimeDirectory.appendingPathComponent("bin/python3.12").path) else {
            phase = FileManager.default.fileExists(atPath: runtimeDirectory.path) ? .incompatible("The installed speech engine is incomplete. Repair or reinstall it.") : .missing
            return
        }
        guard let expectedContentChecksum else {
            phase = .incompatible("This app does not contain a trusted speech-engine content digest.")
            return
        }
        phase = .checking
        healthTask?.cancel()
        let python = runtimeDirectory.appendingPathComponent("bin/python3.12")
        healthTask = Task { [weak self] in
            guard let self else { return }
            let integrity = await RuntimeIntegrityCheck.run(
                runtimeDirectory: self.runtimeDirectory,
                expectedDigest: expectedContentChecksum
            )
            guard !Task.isCancelled else { return }
            let manifest: RuntimeManifest
            switch integrity {
            case let .success(value):
                manifest = value
            case let .failure(error):
                self.healthTask = nil
                self.phase = .incompatible(error.message)
                return
            }
            if let problem = manifest.compatibilityError(
                requiredRuntimeVersion: self.requiredRuntimeVersion
            ) {
                self.healthTask = nil
                self.phase = .incompatible(problem)
                return
            }
            let result = await RuntimeHealthCheck.run(python: python, manifest: manifest)
            guard !Task.isCancelled else { return }
            self.healthTask = nil
            switch result {
            case .success:
                self.phase = .ready
            case let .failure(error):
                self.phase = .failed("Speech engine health check failed: \(error.message)")
            }
        }
    }

    /// Starts an install, or asks the caller to confirm replacement of a
    /// currently healthy engine. Models and preferences are never touched.
    func install() {
        // Local builds run from their prepared development environment and do
        // not contain a downloadable runtime archive. Never turn a healthy
        // development engine into an installer-configuration error.
        guard canManageEngineInstallation else {
            refresh()
            return
        }
        guard !isReady else {
            requiresRepairConfirmation = true
            return
        }
        beginInstall()
    }

    func confirmRepairInstall() {
        requiresRepairConfirmation = false
        beginInstall()
    }

    func cancelRepairConfirmation() {
        requiresRepairConfirmation = false
    }

    func cancelInstall() {
        guard case .installing = phase else {
            installTask?.cancel()
            installTask = nil
            refresh()
            return
        }
        // Atomic replacement is synchronous and is intentionally not cancellable.
    }

    /// Makes this process behave like a fresh install without changing real
    /// runtime, model, preference, or permission files.
    func resetDeveloperTestInstall() {
        guard developerTestMode else { return }
        cancelInstall()
        simulatedRuntimeInstalled = false
        ModelCatalog.resetDeveloperTestModels()
        phase = .missing
    }

    /// Enters the simulator without changing preferences, permissions, the
    /// managed runtime, or the real Hugging Face cache. This is available only
    /// in a local development build.
    func activateDeveloperTestMode() {
        guard DeveloperTestMode.isAvailable else { return }
        DeveloperTestMode.activate()
        resetDeveloperTestInstall()
        NotificationCenter.default.post(name: .whisprDeveloperTestModeActivated, object: nil)
    }

    private func beginInstall() {
        guard installTask == nil else { return }
        if developerTestMode {
            installSimulatedRuntime()
            return
        }
        guard let archiveURL = runtimeArchiveURL, let checksum = expectedChecksum,
              let contentChecksum = expectedContentChecksum,
              let archiveBytes = runtimeArchiveBytes, let installedBytes = runtimeInstalledBytes,
              let runtimeVersion = runtimeConfigurationVersion else {
            phase = .failed("The speech-engine installer is not fully configured for this build.")
            return
        }
        guard archiveURL.scheme?.lowercased() == "https" else {
            phase = .failed("The speech-engine installer must use HTTPS.")
            return
        }
        phase = .checkingStorage
        guard let required = StorageCapacity.requiredBytes(archiveBytes, installedBytes),
              let available = StorageCapacity.availableBytes(at: runtimeDirectory) else {
            phase = .failed("Could not determine available storage for the speech engine.")
            return
        }
        guard available >= required else {
            phase = .insufficientStorage(required: required, available: available)
            return
        }

        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            var candidateInstalled = false
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: archiveURL)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      (200...299).contains(response.statusCode) else {
                    throw RuntimeError.downloadFailed
                }
                self.phase = .verifying
                let currentAvailable = StorageCapacity.availableBytes(at: self.runtimeDirectory) ?? 0
                guard currentAvailable >= required else {
                    throw RuntimeError.insufficientStorage(required: required, available: currentAvailable)
                }
                _ = try Self.installArchive(
                    at: temporaryURL,
                    expectedChecksum: checksum,
                    expectedContentChecksum: contentChecksum,
                    destination: self.runtimeDirectory,
                    requiredRuntimeVersion: runtimeVersion
                )
                candidateInstalled = true
                self.phase = .installing
                let installedIntegrity = await RuntimeIntegrityCheck.run(
                    runtimeDirectory: self.runtimeDirectory,
                    expectedDigest: contentChecksum
                )
                try Task.checkCancellation()
                let manifest: RuntimeManifest
                switch installedIntegrity {
                case let .success(value):
                    manifest = value
                case let .failure(error):
                    throw error
                }
                guard manifest.runtimeVersion == runtimeVersion else {
                    throw RuntimeError.invalidArchive
                }
                switch await RuntimeHealthCheck.run(
                    python: self.runtimeDirectory.appendingPathComponent("bin/python3.12"),
                    manifest: manifest
                ) {
                case .success:
                    Self.finalizeInstalledRuntime(at: self.runtimeDirectory)
                    self.phase = .ready
                    Log.write("runtime installed at \(self.runtimeDirectory.path)")
                case let .failure(error):
                    Self.rollbackInstalledRuntime(at: self.runtimeDirectory)
                    self.phase = .failed("Speech engine health check failed: \(error.message)")
                }
            } catch is CancellationError {
                self.phase = .missing
            } catch let RuntimeError.insufficientStorage(required, available) {
                if candidateInstalled { Self.rollbackInstalledRuntime(at: self.runtimeDirectory) }
                self.phase = .insufficientStorage(required: required, available: available)
            } catch {
                if candidateInstalled { Self.rollbackInstalledRuntime(at: self.runtimeDirectory) }
                Log.write("runtime install failed: \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func installSimulatedRuntime() {
        guard developmentPythonURL != nil else {
            phase = .failed("Developer test mode needs WHISPR_PYTHON or a local development build.")
            return
        }
        phase = .downloading
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installTask = nil }
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
                try Task.checkCancellation()
                self.phase = .installing
                try await Task.sleep(nanoseconds: 450_000_000)
                try Task.checkCancellation()
                self.simulatedRuntimeInstalled = true
                // refresh() intentionally ignores calls while an install task
                // is active. Finish the simulated transition explicitly so it
                // cannot remain stuck in `.installing` until another refresh.
                self.phase = .ready
            } catch is CancellationError {
                self.phase = .missing
            } catch {
                self.phase = .failed("Could not simulate the speech-engine install.")
            }
        }
    }

    private var developerTestMode: Bool {
        DeveloperTestMode.isEnabled
    }

    private var isDevelopmentBuild: Bool {
#if WHISPR_RELEASE
        false
#else
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String ?? "").hasPrefix("dev.")
#endif
    }

    private var developmentPythonURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        if isDevelopmentBuild,
           let override = environment["WHISPR_PYTHON"],
           isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        if isDevelopmentBuild,
           let developmentPath = Bundle.main.object(forInfoDictionaryKey: "WhisprDevelopmentPythonPath") as? String,
           isExecutable(developmentPath) {
            return URL(fileURLWithPath: developmentPath)
        }
        return nil
    }

    private var runtimeArchiveURL: URL? {
        let value = configurationValue(
            plistKey: "WhisprRuntimeURL",
            environmentKey: "WHISPR_RUNTIME_URL"
        )
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private var expectedChecksum: String? {
        let value = configurationValue(
            plistKey: "WhisprRuntimeSHA256",
            environmentKey: "WHISPR_RUNTIME_SHA256"
        )
        guard let value,
              value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    private var expectedContentChecksum: String? {
        let value = configurationValue(
            plistKey: "WhisprRuntimeContentSHA256",
            environmentKey: "WHISPR_RUNTIME_CONTENT_SHA256"
        )
        guard let value,
              value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            return nil
        }
        return value.lowercased()
    }

    private var runtimeConfigurationVersion: String? {
        let value = configurationValue(
            plistKey: "WhisprRuntimeVersion",
            environmentKey: "WHISPR_RUNTIME_VERSION"
        )
        return value?.isEmpty == false ? value : nil
    }

    private var requiredRuntimeVersion: String { runtimeConfigurationVersion ?? "1.0.0" }

    private var runtimeArchiveBytes: Int64? { configurationBytes("WhisprRuntimeArchiveBytes") }
    private var runtimeInstalledBytes: Int64? { configurationBytes("WhisprRuntimeInstalledBytes") }

    private func configurationBytes(_ key: String) -> Int64? {
        let environmentKey: String
        switch key {
        case "WhisprRuntimeArchiveBytes": environmentKey = "WHISPR_RUNTIME_ARCHIVE_BYTES"
        case "WhisprRuntimeInstalledBytes": environmentKey = "WHISPR_RUNTIME_INSTALLED_BYTES"
        default: environmentKey = ""
        }
        let value = configurationValue(plistKey: key, environmentKey: environmentKey)
        guard let value, let bytes = Int64(value), bytes > 0 else { return nil }
        return bytes
    }

    private var runtimeDirectory: URL {
        if isDevelopmentBuild,
           let override = ProcessInfo.processInfo.environment["WHISPR_RUNTIME_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("WhisprStream/Runtime", isDirectory: true)
    }

    private func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }

    private func configurationValue(plistKey: String, environmentKey: String) -> String? {
        let bundleValue = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String
        let environmentValue = environmentKey.isEmpty
            ? nil
            : ProcessInfo.processInfo.environment[environmentKey]
        return RuntimeConfiguration.value(
            environmentValue: environmentValue,
            bundleValue: bundleValue,
            allowsEnvironmentOverride: isDevelopmentBuild && !environmentKey.isEmpty
        )
    }

    private enum RuntimeError: LocalizedError {
        case downloadFailed
        case checksumMismatch
        case invalidArchive
        case extractionFailed
        case insufficientStorage(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "Could not download the speech engine."
            case .checksumMismatch: return "The downloaded speech engine did not pass verification."
            case .invalidArchive: return "The downloaded speech engine is incomplete or incompatible."
            case .extractionFailed: return "Could not install the downloaded speech engine."
            case let .insufficientStorage(required, available):
                return "Not enough storage: \(StorageCapacity.formatted(required)) required, \(StorageCapacity.formatted(available)) available."
            }
        }
    }

    /// A staging directory makes interruption safe: the live runtime changes
    /// only after checksum, layout, manifest, and compatibility validation.
    static func installArchive(
        at archive: URL,
        expectedChecksum: String,
        expectedContentChecksum: String,
        destination: URL,
        requiredRuntimeVersion: String
    ) throws -> RuntimeManifest {
        guard try sha256(of: archive) == expectedChecksum.lowercased() else { throw RuntimeError.checksumMismatch }

        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("Runtime.staging.\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, staging.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeError.extractionFailed }

        let topLevel = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard topLevel.count == 1, topLevel.first?.lastPathComponent == "runtime" else {
            throw RuntimeError.invalidArchive
        }
        let extracted = staging.appendingPathComponent("runtime", isDirectory: true)
        let python = extracted.appendingPathComponent("bin/python3.12")
        guard manager.isExecutableFile(atPath: python.path) else {
            throw RuntimeError.invalidArchive
        }
        let manifest: RuntimeManifest
        switch RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: extracted,
            expectedDigest: expectedContentChecksum
        ) {
        case let .success(value): manifest = value
        case .failure: throw RuntimeError.invalidArchive
        }
        guard manifest.compatibilityError(requiredRuntimeVersion: requiredRuntimeVersion) == nil else {
            throw RuntimeError.invalidArchive
        }

        let previous = parent.appendingPathComponent("Runtime.previous", isDirectory: true)
        try? manager.removeItem(at: previous)
        if manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: destination, to: previous)
        }
        do {
            try manager.moveItem(at: extracted, to: destination)
        } catch {
            if manager.fileExists(atPath: previous.path), !manager.fileExists(atPath: destination.path) {
                try? manager.moveItem(at: previous, to: destination)
            }
            throw error
        }
        return manifest
    }

    private static func finalizeInstalledRuntime(at destination: URL) {
        let previous = destination.deletingLastPathComponent().appendingPathComponent("Runtime.previous", isDirectory: true)
        try? FileManager.default.removeItem(at: previous)
    }

    private static func rollbackInstalledRuntime(at destination: URL) {
        let manager = FileManager.default
        let previous = destination.deletingLastPathComponent().appendingPathComponent("Runtime.previous", isDirectory: true)
        try? manager.removeItem(at: destination)
        if manager.fileExists(atPath: previous.path) {
            try? manager.moveItem(at: previous, to: destination)
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
