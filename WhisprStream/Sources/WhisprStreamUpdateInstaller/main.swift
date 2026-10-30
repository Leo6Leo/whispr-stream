import AppKit
import Darwin
import Foundation

private let expectedBundleIdentifier = "com.leoleo.whisprstream"
private let healthFileArgument = "--whispr-update-health-file"
private let healthTokenArgument = "--whispr-update-health-token"
private let launchStabilityInterval: TimeInterval = 2

private var launchHealthTimeout: TimeInterval {
#if DEBUG
    if let rawValue = ProcessInfo.processInfo.environment["WHISPR_UPDATE_HEALTH_TIMEOUT"],
       let value = TimeInterval(rawValue), (1...60).contains(value) {
        return value
    }
#endif
    return 20
}

private enum InstallerError: LocalizedError {
    case invalidArguments
    case unsafePath
    case invalidBundle
    case readySignalFailed
    case healthSignalFailed
    case appDidNotTerminate
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The update installer received invalid arguments."
        case .unsafePath:
            return "The update installer rejected an unsafe path."
        case .invalidBundle:
            return "The staged update is not a valid WhisprStream app."
        case .readySignalFailed:
            return "The update installer could not signal that it is ready."
        case .healthSignalFailed:
            return "The update installer could not prepare its launch health check."
        case .appDidNotTerminate:
            return "WhisprStream did not terminate before the update deadline."
        case let .replacementFailed(message):
            return "The app could not be replaced: \(message)"
        }
    }
}

private struct Arguments {
    let parentPID: pid_t
    let stagedApp: URL
    let targetApp: URL
    let cleanupRoot: URL
    let readyFile: URL
    let healthFile: URL
    let healthToken: String

    init(_ values: [String]) throws {
        guard values.count == 15 else { throw InstallerError.invalidArguments }
        var parsed: [String: String] = [:]
        var index = 1
        while index < values.count {
            parsed[values[index]] = values[index + 1]
            index += 2
        }
        guard let rawPID = parsed["--wait-pid"],
              let pid = Int32(rawPID), pid > 1,
              let staged = parsed["--staged-app"],
              let target = parsed["--target-app"],
              let cleanup = parsed["--cleanup-root"],
              let ready = parsed["--ready-file"],
              let health = parsed["--health-file"],
              let token = parsed["--health-token"],
              UUID(uuidString: token) != nil else {
            throw InstallerError.invalidArguments
        }
        parentPID = pid
        stagedApp = URL(fileURLWithPath: staged, isDirectory: true).standardizedFileURL
        targetApp = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
        cleanupRoot = URL(fileURLWithPath: cleanup, isDirectory: true).standardizedFileURL
        readyFile = URL(fileURLWithPath: ready, isDirectory: false).standardizedFileURL
        healthFile = URL(fileURLWithPath: health, isDirectory: false).standardizedFileURL
        healthToken = token
    }
}

private func isDirectoryWithoutSymlink(at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
        return false
    }
    return values.isDirectory == true && values.isSymbolicLink != true
}

private func validate(_ arguments: Arguments) throws {
    let parent = arguments.targetApp.deletingLastPathComponent().standardizedFileURL
    let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
    guard parent.path != "/",
          arguments.targetApp.pathExtension == "app",
          arguments.stagedApp.pathExtension == "app",
          arguments.stagedApp.deletingLastPathComponent().standardizedFileURL == parent,
          arguments.stagedApp.lastPathComponent.hasPrefix(".WhisprStream.update-"),
          arguments.cleanupRoot.deletingLastPathComponent().standardizedFileURL == temporary,
          arguments.cleanupRoot.lastPathComponent.hasPrefix("WhisprStream-installer-"),
          arguments.readyFile.deletingLastPathComponent().standardizedFileURL
            == arguments.cleanupRoot,
          arguments.readyFile.lastPathComponent == "ready",
          arguments.healthFile.deletingLastPathComponent().standardizedFileURL
            == arguments.cleanupRoot,
          arguments.healthFile.lastPathComponent == "health",
          isDirectoryWithoutSymlink(at: arguments.cleanupRoot),
          isDirectoryWithoutSymlink(at: arguments.targetApp),
          isDirectoryWithoutSymlink(at: arguments.stagedApp) else {
        throw InstallerError.unsafePath
    }
    guard Bundle(url: arguments.targetApp)?.bundleIdentifier == expectedBundleIdentifier,
          Bundle(url: arguments.stagedApp)?.bundleIdentifier == expectedBundleIdentifier else {
        throw InstallerError.invalidBundle
    }
}

private func writeLog(_ message: String) {
    let manager = FileManager.default
    guard let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
    let directory = library.appendingPathComponent("Logs", isDirectory: true)
    try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("WhisprStream.log")
    if !manager.fileExists(atPath: url.path) {
        _ = manager.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(Data("[whispr updater] \(message)\n".utf8))
}

private func waitForParentToExit(_ pid: pid_t, timeout: TimeInterval = 60) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        errno = 0
        if kill(pid, 0) != 0, errno == ESRCH { return }
        Thread.sleep(forTimeInterval: 0.1)
    }
    throw InstallerError.appDidNotTerminate
}

@discardableResult
private func relaunch(_ app: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", app.path]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

/// Every signal in this file goes through these two helpers, which refuse any
/// pid that does not name exactly one process. `kill(-1, sig)` signals every
/// process the user owns and `kill(0, sig)` the whole process group, and
/// `NSRunningApplication.processIdentifier` is -1 for an app that already
/// exited, so an unguarded pid here once terminated the user's entire session.
private func isSinglePID(_ pid: pid_t) -> Bool {
    pid > 1
}

private func isRunning(_ pid: pid_t) -> Bool {
    guard isSinglePID(pid) else { return false }
    errno = 0
    if kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}

private func stop(_ pid: pid_t) {
    guard isSinglePID(pid), isRunning(pid) else { return }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(2)
    while isRunning(pid), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if isRunning(pid) {
        kill(pid, SIGKILL)
    }
}

/// The kernel's view of a path, for comparison with `proc_pidpath` output.
/// Foundation's `resolvingSymlinksInPath()` strips `/private`, which the kernel
/// keeps, so it cannot be used here.
private func canonicalPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Process identifiers of every running process whose executable is `executable`.
///
/// LaunchServices only reports a pid for apps that check in with it (AppKit
/// apps); for anything else `NSRunningApplication.processIdentifier` is -1, so
/// the helper identifies the new instance by its executable path instead. The
/// previous instance has already exited by the time this runs, so any process
/// running the installed executable is the one this helper launched.
private func processIDs(runningExecutable executable: URL) -> [pid_t] {
    let target = canonicalPath(executable)
    let needed = proc_listallpids(nil, 0)
    guard needed > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(needed) * 2)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    // PROC_PIDPATHINFO_MAXSIZE, which the Swift Darwin overlay does not export.
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.prefix(Int(count)).filter { pid in
        guard isSinglePID(pid) else { return false }
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == target
    }
}

/// What LaunchServices has said so far about a launch it was asked for. Its
/// completion handler fires only once the app has checked in with
/// LaunchServices, which for an app that never does (a plain executable in a
/// bundle) means when the process exits, so callers must not wait for it.
private final class LaunchServicesReport: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var reportedPID: pid_t?

    func record(_ running: NSRunningApplication?, _ error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        failure = error
        if let pid = running?.processIdentifier, isSinglePID(pid) {
            reportedPID = pid
        }
    }

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failure != nil
    }

    var pid: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return reportedPID
    }
}

/// Launches the app through LaunchServices and confirms it reports a healthy
/// launch and stays alive for `launchStabilityInterval` afterwards.
///
/// The new app must not be spawned as a child of this helper. macOS attributes
/// privacy permissions (microphone, accessibility) to a process's "responsible
/// process", which posix_spawn children inherit from their spawner. This helper
/// was itself spawned by the old WhisprStream, so a child here would be charged
/// to the old, already-exited pid and the microphone would stay denied until the
/// user quit and relaunched by hand. LaunchServices makes the new app its own
/// responsible process, exactly like a launch from Finder or the Dock.
private func launchAndConfirmHealth(
    _ app: URL,
    healthFile: URL,
    token: String
) -> Bool {
    guard let bundle = Bundle(url: app),
          let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
          !executableName.isEmpty,
          !executableName.contains("/") else {
        return false
    }
    let executable = app
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(executableName, isDirectory: false)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.promptsUserIfNeeded = false
    configuration.arguments = [
        healthFileArgument, healthFile.path,
        healthTokenArgument, token,
    ]
    let report = LaunchServicesReport()
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, error in
        report.record(running, error)
    }

    let deadline = Date().addingTimeInterval(launchHealthTimeout)
    var pid: pid_t?
    var signalReceivedAt: Date?
    var healthy = false
    while Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        if report.failed { break }
        if pid == nil {
            pid = report.pid ?? processIDs(runningExecutable: executable).first
        }
        if let pid, !isRunning(pid) { break }
        if let contents = try? String(contentsOf: healthFile, encoding: .utf8),
           contents == token {
            if signalReceivedAt == nil {
                signalReceivedAt = Date()
            }
            if Date().timeIntervalSince(signalReceivedAt!) >= launchStabilityInterval {
                if pid == nil {
                    pid = processIDs(runningExecutable: executable).first
                }
                if let pid, isRunning(pid) {
                    healthy = true
                }
                break
            }
        }
    }
    if healthy { return true }

    // Leave no half-started new instance behind before the rollback relaunches
    // the previous version.
    if let pid { stop(pid) }
    for stray in processIDs(runningExecutable: executable) {
        stop(stray)
    }
    return false
}

private func install(_ arguments: Arguments) throws {
    try waitForParentToExit(arguments.parentPID)

    let manager = FileManager.default
    let parent = arguments.targetApp.deletingLastPathComponent()
    let backup = parent.appendingPathComponent(
        ".WhisprStream.update-backup-\(UUID().uuidString).app",
        isDirectory: true
    )
    var movedOriginal = false

    do {
        try manager.moveItem(at: arguments.targetApp, to: backup)
        movedOriginal = true
        try manager.moveItem(at: arguments.stagedApp, to: arguments.targetApp)
    } catch {
        if movedOriginal, !manager.fileExists(atPath: arguments.targetApp.path) {
            try? manager.moveItem(at: backup, to: arguments.targetApp)
        }
        relaunch(arguments.targetApp)
        throw InstallerError.replacementFailed(error.localizedDescription)
    }

    guard launchAndConfirmHealth(
        arguments.targetApp,
        healthFile: arguments.healthFile,
        token: arguments.healthToken
    ) else {
        let failedReplacement = parent.appendingPathComponent(
            ".WhisprStream.update-failed-\(UUID().uuidString).app",
            isDirectory: true
        )
        do {
            try manager.moveItem(at: arguments.targetApp, to: failedReplacement)
            do {
                try manager.moveItem(at: backup, to: arguments.targetApp)
            } catch {
                // Keep a usable app at the original path even if restoring the
                // backup itself fails. The untouched backup remains beside it
                // for manual recovery.
                try? manager.moveItem(at: failedReplacement, to: arguments.targetApp)
                throw error
            }
            relaunch(arguments.targetApp)
            try? manager.removeItem(at: failedReplacement)
            throw InstallerError.replacementFailed(
                "the new version did not report a healthy launch; the previous version was restored"
            )
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.replacementFailed(
                "the new version did not relaunch and rollback failed: \(error.localizedDescription)"
            )
        }
    }
    try? manager.removeItem(at: backup)
}

@main
private enum WhisprStreamUpdateInstaller {
    static func main() {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            try validate(arguments)
            defer {
                try? FileManager.default.removeItem(at: arguments.stagedApp)
                try? FileManager.default.removeItem(at: arguments.cleanupRoot)
            }
            guard FileManager.default.createFile(
                atPath: arguments.healthFile.path,
                contents: Data()
            ) else {
                throw InstallerError.healthSignalFailed
            }
            // Publish readiness only after every file needed for the handoff
            // exists. The running app may terminate as soon as it sees this.
            guard FileManager.default.createFile(
                atPath: arguments.readyFile.path,
                contents: Data()
            ) else {
                throw InstallerError.readySignalFailed
            }
            try install(arguments)
            writeLog("installed update at \(arguments.targetApp.path)")
        } catch {
            writeLog("update failed: \(error.localizedDescription)")
            FileHandle.standardError.write(Data("WhisprStream update failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
