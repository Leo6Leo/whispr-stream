import AppKit
import Foundation

/// Repairs a launch performed by an older updater helper.
///
/// Helpers before 1.0.4 spawned the replacement app as their own child. macOS
/// attributes privacy permissions to a process's "responsible process", which
/// a spawned child inherits, so the new app was charged to the already exited
/// previous version and the microphone stayed silent until the user quit and
/// reopened it by hand. When this process finds itself in that position it
/// relaunches through LaunchServices once the helper has finished, which makes
/// the new instance its own responsible process. Launches by the current
/// helper (which already uses LaunchServices) and by the user never qualify.
enum UpdateRelaunch {
    /// How long to wait for the helper that spawned us to exit. It returns
    /// about two seconds after the health signal; leaving earlier would make
    /// it treat the exit as a failed launch and restore the previous version.
    static let helperExitTimeout: TimeInterval = 30
    static let pollInterval: TimeInterval = 0.1

    /// The decision, kept pure so it can be tested without a helper.
    ///
    /// The parent process is the reliable signal. A LaunchServices launch is
    /// always a child of launchd (pid 1); an old helper's `Process.run()`
    /// child has the helper as its parent. The responsibility API is only a
    /// secondary trigger: once the process it names has exited, it reports the
    /// app as responsible for itself even though TCC still denies it, which is
    /// exactly what happened with a real 1.0.3 helper.
    static func isNeeded(
        launchedByUpdater: Bool,
        parentProcess: pid_t,
        isOwnResponsibleProcess: Bool?
    ) -> Bool {
        guard launchedByUpdater else { return false }
        if parentProcess != 1 { return true }
        return isOwnResponsibleProcess == false
    }

    /// Call once from `applicationDidFinishLaunching`, with the parent pid
    /// read as early as possible (the helper exits two seconds after the
    /// health signal). Returns immediately; the relaunch, if any, happens
    /// after the helper exits.
    static func performIfNeeded(launchedByUpdater: Bool, parentProcess helper: pid_t) {
        let pid = getpid()
        let responsible = ProcessResponsibility.responsiblePID(for: pid)
        Log.write("launch: pid=\(pid) parent=\(helper) responsible=\(responsible.map(String.init) ?? "unknown")")
        guard isNeeded(
            launchedByUpdater: launchedByUpdater,
            parentProcess: helper,
            isOwnResponsibleProcess: responsible.map { $0 == pid }
        ) else { return }

        Log.write("update relaunch: spawned as a child of helper \(helper); relaunching through LaunchServices once it exits")
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(helperExitTimeout)
            while getppid() == helper, Date() < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }
            DispatchQueue.main.async {
                guard getppid() != helper else {
                    Log.write("update relaunch: helper \(helper) still running after \(Int(helperExitTimeout)) s; staying in this process")
                    return
                }
                relaunch()
            }
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { running, error in
            DispatchQueue.main.async {
                if let running {
                    Log.write("update relaunch: new instance pid=\(running.processIdentifier); terminating pid=\(getpid())")
                    NSApp.terminate(nil)
                } else {
                    Log.write("update relaunch failed: \(error?.localizedDescription ?? "unknown error"); staying in this process")
                }
            }
        }
    }
}

/// `responsibility_get_pid_responsible_for_pid` has no public header, so it
/// is resolved at run time. A missing symbol reads as "unknown" (`nil`).
enum ProcessResponsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        // RTLD_DEFAULT is a macro the Swift Darwin overlay does not export.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        let result = lookup(pid)
        return result > 0 ? result : nil
    }
}
