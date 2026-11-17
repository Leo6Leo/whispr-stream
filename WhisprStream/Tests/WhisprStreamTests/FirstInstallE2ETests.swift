import Darwin
import XCTest
@testable import WhisprStream

/// Opt-in first-install checks that drive the app's own runtime installer
/// (`RuntimeManager.installArchive`, `RuntimeIntegrityCheck`,
/// `RuntimeHealthCheck`) with the real release runtime archive and the pins
/// from a release candidate's Info.plist.
///
/// Run through `WhisprStream/test-first-install-e2e.sh`, which builds this
/// target in the release configuration (the public dependency gate excludes
/// optional models) and sets:
///
/// - `WHISPR_E2E_RUNTIME_ZIP`: the runtime archive to install.
/// - `WHISPR_E2E_APP`: the extracted candidate app whose Info.plist pins it.
/// - `WHISPR_E2E_INSTALL_ROOT` (optional): an empty Application Support
///   directory; the final good install is left there for the Python phase.
/// - `WHISPR_E2E_SMALL_VOLUME` (optional): a mounted volume too small for the
///   runtime, for the insufficient-space case.
///
/// Without those variables every test is skipped, so the default
/// `swift test` run is unchanged.
@MainActor
final class FirstInstallE2ETests: XCTestCase {
    private struct Pins {
        let archiveSHA256: String
        let contentSHA256: String
        let runtimeVersion: String
        let archiveBytes: Int64
        let installedBytes: Int64
    }

    private var archive: URL!
    private var pins: Pins!
    private var scratch: URL!

    /// Called first by every test; XCTest's setUp overrides are nonisolated.
    private func prepare() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let zip = environment["WHISPR_E2E_RUNTIME_ZIP"], !zip.isEmpty,
              let app = environment["WHISPR_E2E_APP"], !app.isEmpty else {
            throw XCTSkip("set WHISPR_E2E_RUNTIME_ZIP and WHISPR_E2E_APP (see test-first-install-e2e.sh)")
        }
        guard !FeatureFlags.optionalModelsEnabled else {
            throw XCTSkip("build with -c release: the public 1.0.x runtime omits optional-model dependencies")
        }
        archive = URL(fileURLWithPath: zip)
        let plistURL = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: plistURL) as? [String: Any])
        func string(_ key: String) throws -> String {
            try XCTUnwrap(info[key] as? String, "candidate Info.plist lacks \(key)")
        }
        pins = Pins(
            archiveSHA256: try string("WhisprRuntimeSHA256").lowercased(),
            contentSHA256: try string("WhisprRuntimeContentSHA256").lowercased(),
            runtimeVersion: try string("WhisprRuntimeVersion"),
            archiveBytes: try XCTUnwrap(Int64(try string("WhisprRuntimeArchiveBytes"))),
            installedBytes: try XCTUnwrap(Int64(try string("WhisprRuntimeInstalledBytes")))
        )
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-first-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let created = scratch!
        addTeardownBlock { try? FileManager.default.removeItem(at: created) }
    }

    /// Same layout the app uses: Application Support/WhisprStream/Runtime.
    private func runtimeDestination(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("WhisprStream/Runtime", isDirectory: true)
    }

    private func install(
        archive: URL,
        checksum: String? = nil,
        contentChecksum: String? = nil,
        destination: URL
    ) throws -> RuntimeManifest {
        try RuntimeManager.installArchive(
            at: archive,
            expectedChecksum: checksum ?? pins.archiveSHA256,
            expectedContentChecksum: contentChecksum ?? pins.contentSHA256,
            destination: destination,
            requiredRuntimeVersion: pins.runtimeVersion
        )
    }

    private func leftoverStaging(next destination: URL) -> [String] {
        let parent = destination.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { $0.hasPrefix("Runtime.staging.") }
    }

    private func flipped(_ hex: String) -> String {
        let last = hex.last == "0" ? "1" : "0"
        return String(hex.dropLast()) + last
    }

    /// Simulates launching the app from a shell with a hostile Python setup.
    /// RuntimeHealthCheck reads ProcessInfo's environment, so set it in-process
    /// and restore it afterwards.
    private func withHostilePythonEnvironment<T>(_ body: () throws -> T) rethrows -> T {
        let poison = scratch.appendingPathComponent("poison", isDirectory: true)
        try? FileManager.default.createDirectory(at: poison, withIntermediateDirectories: true)
        for module in ["numpy", "mlx", "huggingface_hub", "mlx_qwen3_asr"] {
            let package = poison.appendingPathComponent(module, isDirectory: true)
            try? FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try? Data("raise ImportError('poisoned \(module) from PYTHONPATH')\n".utf8)
                .write(to: package.appendingPathComponent("__init__.py"))
        }
        let hostile: [String: String] = [
            "PYTHONPATH": poison.path,
            "PYTHONHOME": scratch.appendingPathComponent("no-such-python-home").path,
            "PYTHONSTARTUP": poison.appendingPathComponent("startup.py").path,
            "VIRTUAL_ENV": scratch.appendingPathComponent("venv").path,
            "CONDA_PREFIX": scratch.appendingPathComponent("conda").path,
            "CONDA_DEFAULT_ENV": "poisoned",
            "DYLD_LIBRARY_PATH": poison.path,
            "PATH": "/opt/homebrew/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
        ]
        var previous: [String: String?] = [:]
        for (key, value) in hostile {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return try body()
    }

    // MARK: - Tests

    func testCandidatePinsDescribeTheRuntimeArchive() throws {
        try prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, pins.archiveBytes,
                       "WhisprRuntimeArchiveBytes must equal the archive size used by the storage preflight")
        XCTAssertEqual(try RuntimeManager.sha256(of: archive), pins.archiveSHA256)
    }

    func testFreshInstallPassesIntegrityAndHealthUnderHostilePythonEnvironment() throws {
        try prepare()
        let environment = ProcessInfo.processInfo.environment
        let support = environment["WHISPR_E2E_INSTALL_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? scratch.appendingPathComponent("Application Support", isDirectory: true)
        let destination = runtimeDestination(in: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "the install root must start without a runtime (fresh Mac)")

        let manifest = try install(archive: archive, destination: destination)
        XCTAssertEqual(manifest.runtimeVersion, pins.runtimeVersion)
        XCTAssertNil(manifest.compatibilityError(requiredRuntimeVersion: pins.runtimeVersion))
        XCTAssertEqual(leftoverStaging(next: destination), [])
        XCTAssertEqual(manifest.payloadBytes, pins.installedBytes,
                       "WhisprRuntimeInstalledBytes must match the runtime manifest payload")

        XCTAssertEqual(try RuntimeIntegrityCheck.contentDigest(at: destination), pins.contentSHA256)
        guard case .success = RuntimeIntegrityCheck.runSynchronously(
            runtimeDirectory: destination, expectedDigest: pins.contentSHA256
        ) else { return XCTFail("installed runtime failed the app's integrity check") }

        let python = destination.appendingPathComponent("bin/python3.12")
        let (unsanitizedStatus, health) = withHostilePythonEnvironment {
            XCTAssertNotNil(ProcessInfo.processInfo.environment["PYTHONHOME"],
                            "the hostile environment must be visible to the app's code")
            // Control: the same interpreter with the raw hostile environment
            // must fail, or this test would not prove the sanitizer matters.
            let control = Process()
            control.executableURL = python
            control.arguments = ["-B", "-c", "import numpy"]  // -B: never write into the runtime
            control.standardOutput = FileHandle.nullDevice
            control.standardError = FileHandle.nullDevice
            try? control.run()
            control.waitUntilExit()
            return (
                control.terminationStatus,
                RuntimeHealthCheck.runSynchronously(python: python, manifest: manifest, includeOptionalModels: false)
            )
        }
        XCTAssertNotEqual(unsanitizedStatus, 0, "the hostile environment did not break an unsanitized Python")
        if case let .failure(error) = health {
            XCTFail("health check failed under a hostile Python environment: \(error.message)")
        }
        // The checks run Python inside the runtime; they must not leave
        // bytecode or anything else that would fail the next launch's check.
        XCTAssertEqual(try RuntimeIntegrityCheck.contentDigest(at: destination), pins.contentSHA256,
                       "running the runtime modified it; the next launch would demand a repair")
    }

    func testArchiveChecksumMismatchInstallsNothing() throws {
        try prepare()
        let destination = runtimeDestination(in: scratch.appendingPathComponent("checksum"))
        XCTAssertThrowsError(try install(
            archive: archive, checksum: flipped(pins.archiveSHA256), destination: destination
        )) { error in
            XCTAssertEqual(error.localizedDescription, "The downloaded speech engine did not pass verification.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(leftoverStaging(next: destination), [])
    }

    func testTruncatedDownloadInstallsNothing() throws {
        try prepare()
        // An interrupted download whose bytes were (wrongly) trusted: give the
        // installer the truncated file's own hash so it reaches extraction.
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let truncated = scratch.appendingPathComponent("truncated.zip")
        try data.prefix(data.count / 2).write(to: truncated)
        let destination = runtimeDestination(in: scratch.appendingPathComponent("truncated"))

        XCTAssertThrowsError(try install(
            archive: truncated,
            checksum: try RuntimeManager.sha256(of: truncated),
            destination: destination
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(leftoverStaging(next: destination), [])

        // The pinned checksum, which is what the app actually uses, rejects it
        // before extraction.
        XCTAssertThrowsError(try install(archive: truncated, destination: destination)) { error in
            XCTAssertEqual(error.localizedDescription, "The downloaded speech engine did not pass verification.")
        }
    }

    func testContentDigestMismatchInstallsNothing() throws {
        try prepare()
        let destination = runtimeDestination(in: scratch.appendingPathComponent("content"))
        XCTAssertThrowsError(try install(
            archive: archive, contentChecksum: flipped(pins.contentSHA256), destination: destination
        )) { error in
            XCTAssertEqual(error.localizedDescription, "The downloaded speech engine is incomplete or incompatible.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(leftoverStaging(next: destination), [])
    }

    func testFailedRepairKeepsTheWorkingRuntime() throws {
        try prepare()
        let destination = runtimeDestination(in: scratch.appendingPathComponent("repair"))
        _ = try install(archive: archive, destination: destination)

        XCTAssertThrowsError(try install(
            archive: archive, contentChecksum: flipped(pins.contentSHA256), destination: destination
        ))
        XCTAssertEqual(try RuntimeIntegrityCheck.contentDigest(at: destination), pins.contentSHA256,
                       "a failed repair must leave the previous engine usable")
        XCTAssertEqual(leftoverStaging(next: destination), [])
    }

    func testInsufficientSpaceIsDetectedAndLeavesNoPartialRuntime() throws {
        try prepare()
        guard let volume = ProcessInfo.processInfo.environment["WHISPR_E2E_SMALL_VOLUME"], !volume.isEmpty else {
            throw XCTSkip("set WHISPR_E2E_SMALL_VOLUME to a mounted small volume")
        }
        let support = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let destination = runtimeDestination(in: support)

        // The same arithmetic RuntimeManager.beginInstall uses before it
        // downloads anything; the app shows .insufficientStorage here.
        let required = try XCTUnwrap(StorageCapacity.requiredBytes(pins.archiveBytes, pins.installedBytes))
        let available = try XCTUnwrap(StorageCapacity.availableBytes(at: destination))
        XCTAssertLessThan(available, required)
        XCTAssertFalse(StorageCapacity.check(available: available, required: required).isEnough)

        // If space disappears after the preflight (the download finished, then
        // the disk filled), extraction must fail without a half-installed engine.
        XCTAssertThrowsError(try install(archive: archive, destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(leftoverStaging(next: destination), [])
    }
}
