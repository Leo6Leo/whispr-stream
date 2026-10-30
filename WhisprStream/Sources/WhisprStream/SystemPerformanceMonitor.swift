import Dispatch
import Foundation

/// A coarse, user-facing explanation for system conditions that can slow
/// on-device inference. These are pressure signals, not proof that a specific
/// transcription was delayed, so the HUD deliberately says "may be slower."
enum SystemPerformanceCondition: Equatable {
    case normal
    case memoryPressure
    case thermalPressure
    case memoryAndThermalPressure

    init(memoryPressure: Bool, thermalState: ProcessInfo.ThermalState) {
        let thermalPressure = thermalState == .serious || thermalState == .critical
        switch (memoryPressure, thermalPressure) {
        case (false, false): self = .normal
        case (true, false): self = .memoryPressure
        case (false, true): self = .thermalPressure
        case (true, true): self = .memoryAndThermalPressure
        }
    }

    var hudMessage: String? {
        switch self {
        case .normal:
            return nil
        case .memoryPressure:
            return "Memory pressure is high · Transcription may be slower"
        case .thermalPressure:
            return "Mac is running hot · Transcription may be slower"
        case .memoryAndThermalPressure:
            return "Mac is under heavy load · Transcription may be slower"
        }
    }

    var logValue: String {
        switch self {
        case .normal: return "normal"
        case .memoryPressure: return "memory-pressure"
        case .thermalPressure: return "thermal-pressure"
        case .memoryAndThermalPressure: return "memory-and-thermal-pressure"
        }
    }
}

/// Observes macOS pressure notifications without polling or estimating from a
/// misleading raw memory-use percentage. All callbacks are delivered on the
/// main actor so they can update the app's observable state directly.
@MainActor
final class SystemPerformanceMonitor {
    var onChange: ((SystemPerformanceCondition) -> Void)?

    private let processInfo: ProcessInfo
    private let notificationCenter: NotificationCenter
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    private var hasMemoryPressure = false
    private var condition = SystemPerformanceCondition.normal

    init(
        processInfo: ProcessInfo = .processInfo,
        notificationCenter: NotificationCenter = .default
    ) {
        self.processInfo = processInfo
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleMemoryPressureEvent()
            }
        }
        source.resume()

        thermalObserver = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: processInfo,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishIfChanged()
            }
        }
        publishIfChanged(force: true)
    }

    deinit {
        memoryPressureSource?.cancel()
        if let thermalObserver {
            notificationCenter.removeObserver(thermalObserver)
        }
    }

    private func handleMemoryPressureEvent() {
        guard let event = memoryPressureSource?.data else { return }
        if event.contains(.critical) || event.contains(.warning) {
            hasMemoryPressure = true
        } else if event.contains(.normal) {
            hasMemoryPressure = false
        }
        publishIfChanged()
    }

    private func publishIfChanged(force: Bool = false) {
        let next = SystemPerformanceCondition(
            memoryPressure: hasMemoryPressure,
            thermalState: processInfo.thermalState
        )
        guard force || next != condition else { return }
        condition = next
        onChange?(next)
    }
}
