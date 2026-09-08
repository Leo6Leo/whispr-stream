import CryptoKit
import XCTest
@testable import WhisprStream

final class AppUpdateManagerTests: XCTestCase {
    private let releasePage = URL(string: "https://github.com/Leo6Leo/whispr-stream/releases/tag/v1.0.2")!

    private func asset(_ name: String, size: Int64 = 100) -> GitHubRelease.Asset {
        GitHubRelease.Asset(
            name: name,
            downloadURL: URL(
                string: "https://github.com/Leo6Leo/whispr-stream/releases/download/v1.0.2/\(name)"
            )!,
            size: size
        )
    }

    private func release(
        tag: String = "v1.0.2",
        assets: [GitHubRelease.Asset]? = nil
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            pageURL: releasePage,
            draft: false,
            prerelease: false,
            assets: assets ?? [
                asset(AppUpdateManager.archiveAssetName),
                asset(AppUpdateManager.signatureAssetName),
            ]
        )
    }

    func testAutomaticPromptAppearsOnlyOnceForEachRelease() throws {
        let suiteName = "AppUpdatePromptPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = AppUpdatePromptPolicy(defaults: defaults)

        XCTAssertTrue(policy.shouldPresent(version: "1.1.0"))
        policy.markPresented(version: "1.1.0")
        XCTAssertFalse(policy.shouldPresent(version: "1.1.0"))
        XCTAssertTrue(policy.shouldPresent(version: "1.2.0"))
    }

    func testSelectsExactSignedAssetsForNewerStableRelease() throws {
        let update = try XCTUnwrap(
            AppUpdateManager.release(from: release(), currentVersion: "1.0.1")
        )

        XCTAssertEqual(update.version, "1.0.2")
        XCTAssertEqual(update.archiveBytes, 100)
        XCTAssertEqual(update.archiveURL.lastPathComponent, AppUpdateManager.archiveAssetName)
        XCTAssertEqual(update.signatureURL.lastPathComponent, AppUpdateManager.signatureAssetName)
        XCTAssertNil(try AppUpdateManager.release(from: release(), currentVersion: "1.0.2"))
    }

    func testRejectsMissingDuplicateOversizedAndNonGitHubAssets() {
        XCTAssertThrowsError(
            try AppUpdateManager.release(
                from: release(assets: [asset(AppUpdateManager.archiveAssetName)]),
                currentVersion: "1.0.1"
            )
        )
        XCTAssertThrowsError(
            try AppUpdateManager.release(
                from: release(assets: [
                    asset(AppUpdateManager.archiveAssetName),
                    asset(AppUpdateManager.archiveAssetName),
                    asset(AppUpdateManager.signatureAssetName),
                ]),
                currentVersion: "1.0.1"
            )
        )
        XCTAssertThrowsError(
            try AppUpdateManager.release(
                from: release(assets: [
                    asset(
                        AppUpdateManager.archiveAssetName,
                        size: AppUpdateManager.maximumArchiveBytes + 1
                    ),
                    asset(AppUpdateManager.signatureAssetName),
                ]),
                currentVersion: "1.0.1"
            )
        )

        let external = GitHubRelease.Asset(
            name: AppUpdateManager.archiveAssetName,
            downloadURL: URL(string: "https://example.com/update.zip")!,
            size: 100
        )
        XCTAssertThrowsError(
            try AppUpdateManager.release(
                from: release(assets: [external, asset(AppUpdateManager.signatureAssetName)]),
                currentVersion: "1.0.1"
            )
        )
    }

#if DEBUG
    func testDeveloperFeedAcceptsOnlyLoopbackHTTPAssetsWhenExplicitlyEnabled() throws {
        let archiveURL = URL(string: "http://127.0.0.1:8765/WhisprStream-macos-arm64.zip")!
        let signatureURL = URL(
            string: "http://localhost:8765/WhisprStream-macos-arm64.zip.ed25519"
        )!
        let localRelease = release(assets: [
            GitHubRelease.Asset(
                name: AppUpdateManager.archiveAssetName,
                downloadURL: archiveURL,
                size: 100
            ),
            GitHubRelease.Asset(
                name: AppUpdateManager.signatureAssetName,
                downloadURL: signatureURL,
                size: 89
            ),
        ])

        XCTAssertThrowsError(
            try AppUpdateManager.release(from: localRelease, currentVersion: "1.0.1")
        )
        XCTAssertNoThrow(
            try AppUpdateManager.release(
                from: localRelease,
                currentVersion: "1.0.1",
                allowDeveloperAssetURLs: true
            )
        )
        XCTAssertTrue(AppUpdateManager.isLocalDeveloperURL(archiveURL))
        XCTAssertTrue(AppUpdateManager.isLocalDeveloperURL(signatureURL))
        XCTAssertFalse(AppUpdateManager.isLocalDeveloperURL(URL(string: "https://127.0.0.1/a")!))
        XCTAssertFalse(AppUpdateManager.isLocalDeveloperURL(URL(string: "http://example.com/a")!))
        XCTAssertFalse(AppUpdateManager.isLocalDeveloperURL(URL(string: "http://user@localhost/a")!))
    }

    func testFetchLatestReleaseCanUseDeveloperFeed() async throws {
        let feedURL = URL(string: "http://127.0.0.1:8765/latest.json")!
        MockUpdateURLProtocol.responses = [feedURL: Data("""
        {
          "tag_name": "v1.0.2",
          "html_url": "https://github.com/Leo6Leo/whispr-stream/releases/tag/v1.0.2",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """.utf8)]
        defer { MockUpdateURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]

        let fetched = try await AppUpdateManager.fetchLatestRelease(
            for: "Leo6Leo/whispr-stream",
            session: URLSession(configuration: configuration),
            developerFeedURL: feedURL
        )

        XCTAssertEqual(fetched.tagName, "v1.0.2")
        do {
            _ = try await AppUpdateManager.fetchLatestRelease(
                for: "Leo6Leo/whispr-stream",
                session: URLSession(configuration: configuration),
                developerFeedURL: URL(string: "http://example.com/latest.json")!
            )
            XCTFail("Expected a non-loopback developer feed to be rejected")
        } catch UpdateError.invalidDeveloperFeed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testManagerDiscoversUpdateThroughDeveloperFeed() async throws {
        let feedURL = URL(string: "http://127.0.0.1:8765/latest.json")!
        let archiveURL = URL(string: "http://127.0.0.1:8765/WhisprStream-macos-arm64.zip")!
        let signatureURL = URL(
            string: "http://127.0.0.1:8765/WhisprStream-macos-arm64.zip.ed25519"
        )!
        MockUpdateURLProtocol.responses = [feedURL: Data("""
        {
          "tag_name": "v1.0.2",
          "html_url": "https://github.com/Leo6Leo/whispr-stream/releases/tag/v1.0.2",
          "draft": false,
          "prerelease": false,
          "assets": [
            {"name": "\(AppUpdateManager.archiveAssetName)", "browser_download_url": "\(archiveURL.absoluteString)", "size": 100},
            {"name": "\(AppUpdateManager.signatureAssetName)", "browser_download_url": "\(signatureURL.absoluteString)", "size": 89}
          ]
        }
        """.utf8)]
        defer { MockUpdateURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let manager = AppUpdateManager(
            repository: "Leo6Leo/whispr-stream",
            currentVersion: "1.0.1",
            bundleIdentifier: "com.leoleo.whisprstream",
            publicKey: key,
            appBundleURL: URL(fileURLWithPath: "/tmp/WhisprStream.app"),
            session: URLSession(configuration: configuration),
            developerFeedURL: feedURL
        )

        manager.checkForUpdates()
        for _ in 0..<100 {
            if case .available = manager.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case let .available(update) = manager.status else {
            return XCTFail("Expected a locally discovered update, got \(manager.status)")
        }
        XCTAssertEqual(update.version, "1.0.2")
        XCTAssertEqual(update.archiveURL, archiveURL)
    }

    @MainActor
    func testSimulatedUpdateSupersedesAnInFlightRealCheck() async throws {
        let feedURL = URL(string: "http://127.0.0.1:8765/latest.json")!
        MockUpdateURLProtocol.responses = [feedURL: Data("""
        {
          "tag_name": "v1.0.2",
          "html_url": "https://github.com/Leo6Leo/whispr-stream/releases/tag/v1.0.2",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """.utf8)]
        defer { MockUpdateURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let manager = AppUpdateManager(
            repository: "Leo6Leo/whispr-stream",
            currentVersion: "1.0.2",
            bundleIdentifier: "dev.local.whisprstream",
            publicKey: key,
            appBundleURL: URL(fileURLWithPath: "/tmp/WhisprStream.app"),
            session: URLSession(configuration: configuration),
            developerFeedURL: feedURL
        )

        manager.checkForUpdates()
        manager.presentSimulatedUpdate(version: "1.1.0", allowInThisBuild: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case let .available(release) = manager.status else {
            return XCTFail("Expected the simulated release to remain visible")
        }
        XCTAssertEqual(release.version, "1.1.0")
    }

    func testDeveloperFeedEnvironmentOverrideIsDebugOnlyAndRequiresAURL() {
        XCTAssertEqual(
            AppUpdateManager.developerFeedURLFromEnvironment([
                "WHISPR_UPDATE_FEED_URL": " http://127.0.0.1:8765/latest.json "
            ]),
            URL(string: "http://127.0.0.1:8765/latest.json")
        )
        XCTAssertNil(AppUpdateManager.developerFeedURLFromEnvironment([:]))
        XCTAssertNil(AppUpdateManager.developerFeedURLFromEnvironment([
            "WHISPR_UPDATE_FEED_URL": "http://["
        ]))
    }
#endif

    func testEd25519SignatureAcceptsExactArchiveAndRejectsTampering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStreamUpdateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("update.zip")
        let archiveData = Data("signed update".utf8)
        try archiveData.write(to: archive)
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: archiveData).base64EncodedString()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertNoThrow(try AppUpdateManager.verifySignature(
            archive: archive,
            signatureData: Data((signature + "\n").utf8),
            publicKey: publicKey
        ))

        try Data("tampered update".utf8).write(to: archive)
        XCTAssertThrowsError(try AppUpdateManager.verifySignature(
            archive: archive,
            signatureData: Data(signature.utf8),
            publicKey: publicKey
        ))
        XCTAssertThrowsError(try AppUpdateManager.verifySignature(
            archive: archive,
            signatureData: Data("not-base64".utf8),
            publicKey: publicKey
        ))
    }

    func testReplacementBundleMustKeepIdentityVersionKeyAndExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisprStreamBundleTests-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("WhisprStream.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.leoleo.whisprstream",
            "CFBundleShortVersionString": "1.0.2",
            "CFBundleVersion": "3",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "WhisprStream",
            "LSMinimumSystemVersion": "14.0",
            "WhisprUpdatePublicKey": key,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("WhisprStream")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        XCTAssertNoThrow(try AppUpdateManager.validateReplacementBundle(
            at: app,
            expectedBundleIdentifier: "com.leoleo.whisprstream",
            expectedVersion: "1.0.2",
            expectedPublicKey: key
        ))
        XCTAssertThrowsError(try AppUpdateManager.validateReplacementBundle(
            at: app,
            expectedBundleIdentifier: "com.attacker.fake",
            expectedVersion: "1.0.2",
            expectedPublicKey: key
        ))
        XCTAssertThrowsError(try AppUpdateManager.validateReplacementBundle(
            at: app,
            expectedBundleIdentifier: "com.leoleo.whisprstream",
            expectedVersion: "9.9.9",
            expectedPublicKey: key
        ))
    }

    func testPublicKeyValidationRequiresOneEd25519Key() {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(AppUpdateManager.isValidPublicKey(key))
        XCTAssertFalse(AppUpdateManager.isValidPublicKey(nil))
        XCTAssertFalse(AppUpdateManager.isValidPublicKey(Data(repeating: 0, count: 31).base64EncodedString()))
        XCTAssertFalse(AppUpdateManager.isValidPublicKey("not-base64"))
    }

    func testUpdateTrustRootEnvironmentOverridesAreDebugOnly() {
        let environment = [
            "WHISPR_UPDATE_REPOSITORY": "attacker/repository",
            "WHISPR_UPDATE_PUBLIC_KEY": "attacker-key",
        ]
        let repository = AppUpdateManager.configuredUpdateRepository(
            bundleValue: "Leo6Leo/whispr-stream",
            environment: environment
        )
        let key = AppUpdateManager.configuredUpdatePublicKey(
            bundleValue: "pinned-key",
            environment: environment
        )

#if DEBUG
        XCTAssertEqual(repository, "attacker/repository")
        XCTAssertEqual(key, "attacker-key")
#else
        XCTAssertEqual(repository, "Leo6Leo/whispr-stream")
        XCTAssertEqual(key, "pinned-key")
#endif
    }

    func testDownloadVerifiesExtractsAndValidatesReplacement() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("WhisprStreamDownloadTests-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("source")
        let app = source.appendingPathComponent("WhisprStream.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.leoleo.whisprstream",
            "CFBundleShortVersionString": "1.0.2",
            "CFBundleVersion": "3",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "WhisprStream",
            "LSMinimumSystemVersion": "14.0",
            "WhisprUpdatePublicKey": publicKey,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent("WhisprStream")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let archive = directory.appendingPathComponent("update.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        let archiveData = try Data(contentsOf: archive)
        let signature = try privateKey.signature(for: archiveData).base64EncodedString()
        let archiveURL = URL(string: "https://github.com/example/update.zip")!
        let signatureURL = URL(string: "https://github.com/example/update.zip.ed25519")!
        MockUpdateURLProtocol.responses = [
            archiveURL: archiveData,
            signatureURL: Data((signature + "\n").utf8),
        ]
        defer { MockUpdateURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let release = AppUpdateManager.Release(
            version: "1.0.2",
            pageURL: releasePage,
            archiveURL: archiveURL,
            signatureURL: signatureURL,
            archiveBytes: Int64(archiveData.count)
        )

        let prepared = try await AppUpdateManager.downloadAndPrepare(
            release: release,
            publicKey: publicKey,
            expectedBundleIdentifier: "com.leoleo.whisprstream",
            session: session
        )
        defer { try? manager.removeItem(at: prepared.root) }

        XCTAssertEqual(Bundle(url: prepared.app)?.bundleIdentifier, "com.leoleo.whisprstream")
        XCTAssertEqual(
            Bundle(url: prepared.app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "1.0.2"
        )
    }

    func testReplacementRejectsAnUnsupportedMinimumSystemVersion() {
        let current = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        XCTAssertTrue(AppUpdateManager.supports(minimumSystemVersion: "14.0", currentOS: current))
        XCTAssertTrue(AppUpdateManager.supports(minimumSystemVersion: "14.6.1", currentOS: current))
        XCTAssertFalse(AppUpdateManager.supports(minimumSystemVersion: "15.0", currentOS: current))
        XCTAssertFalse(AppUpdateManager.supports(minimumSystemVersion: "latest", currentOS: current))
    }

    func testQuarantineIsClearedOnlyFromPreparedBundleTree() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("WhisprStreamQuarantineTests-\(UUID().uuidString)")
        let app = directory.appendingPathComponent("WhisprStream.app")
        let executable = app.appendingPathComponent("Contents/MacOS/WhisprStream")
        try manager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: executable)
        defer { try? manager.removeItem(at: directory) }

        XCTAssertEqual(try xattr(["-w", "com.apple.quarantine", "0081;test", app.path]), 0)
        XCTAssertEqual(
            try xattr(["-w", "com.apple.quarantine", "0081;test", executable.path]),
            0
        )
        XCTAssertEqual(try xattr(["-p", "com.apple.quarantine", app.path]), 0)
        XCTAssertEqual(try xattr(["-p", "com.apple.quarantine", executable.path]), 0)

        try AppUpdateManager.clearQuarantineRecursively(at: app)

        XCTAssertNotEqual(try xattr(["-p", "com.apple.quarantine", app.path]), 0)
        XCTAssertNotEqual(try xattr(["-p", "com.apple.quarantine", executable.path]), 0)
    }

    private func xattr(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private final class MockUpdateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [URL: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let data = Self.responses[url],
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(data.count)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
