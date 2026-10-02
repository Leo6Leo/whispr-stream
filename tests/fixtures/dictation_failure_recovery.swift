// I/O doubles only. The Python runner inserts current production methods below.
enum Phase: Equatable { case idle, listening, thinking, inserted, failed(String) }
struct DictationReview: Equatable {}
enum InjectedFailure: Error { case failed }
enum Log { static func write(_ message: String) {} }

final class ASRService {
    enum Event {
        case ready(ms: Int), partial(committed: String, tail: String)
        case final(text: String, secs: Double, ms: Int, review: DictationReview?)
        case error(String), terminated(String)
    }
    var onEvent: ((Event) -> Void)?
    var shouldFailStart = false
    var shutdowns = 0, starts = 0, begins = 0, stops = 0
    func start() throws { starts += 1; if shouldFailStart { throw InjectedFailure.failed } }
    func shutdown() { shutdowns += 1 }
    func beginUtterance(shortUtteranceLanguage: String?) { begins += 1 }
    func stopUtterance() { stops += 1 }
    func setContext(_ terms: String) {}
    func sendAudio(_ pcm: Data) {}
}
final class Capture {
    var capturing = false, shouldFailStart = false
    var onBuffer: ((Data, Float) -> Void)?
    var onFailure: ((Error) -> Void)?
    func start() throws {
        capturing = true
        if shouldFailStart { throw InjectedFailure.failed }
    }
    func stop() { capturing = false }
}
final class HotKeyMonitor {
    var active = false
    var onStart: (() -> Bool)?
    var onStop: (() -> Void)?
    init(shortcut: Int, mode: Int) {}
    func cancelActiveDictation() { active = false }
    func rebind(shortcut: Int, mode: Int) {}
    func setSuspendedForShortcutCapture(_ suspended: Bool) {}
}
final class State {
    var phase: Phase = .idle
    var level: CGFloat = 0
    var lastAudioSecs = 0.0, lastDurationMS = 0
    var committed = "", tail = "", timerRunning = false
    func startDictationTimer() { timerRunning = true }
    func stopDictationTimer() { timerRunning = false }
    func reset() { committed = ""; tail = ""; level = 0; stopDictationTimer() }
}
final class Settings {
    struct Model { let rawValue = "test" }
    let model = Model()
    var autoInsert = false, contextAwareCapitalization = false, isReloadingModel = false
    var copyToClipboard = true
    var reviewUncertainWords = false, learnFromCorrections = true, isCapturingTriggerShortcut = false
    var triggerShortcut = 0, activationMode = 0, shortUtteranceLanguage = "auto"
    var onHotKeyConfigurationChange: (() -> Void)?
    var onTriggerShortcutCaptureChange: ((Bool) -> Void)?
    var onContextChange: ((String) -> Void)?
    var onLearningChange: (() -> Void)?
    var onModelChange: ((Model) -> Void)?
    var onShortUtteranceLanguageChange: ((String) -> Void)?
    func playStart() {}
    func playFeedback() {}
}
enum TranscriptFormatter {
    static func adjustedForCursor(_ text: String, precedingText: String?) -> String { text }
    static func textForInsertion(_ text: String) -> String { text + " " }
}
enum ShortUtteranceLanguageResolver {
    static func modelLanguage(for value: String) -> String? { nil }
}
final class Panel {
    var presentationGeneration = 0, isVisible = false
    var onPresent: (() -> Void)?
    func present() { onPresent?(); presentationGeneration += 1; isVisible = true }
    func dismiss(completion: (() -> Void)? = nil) { isVisible = false; completion?() }
}
final class Windows { func dismissFirstDictationCoach() {} }
final class TargetApplication {
    var activations = 0
    func activate(options: [Int]) { activations += 1 }
}
enum TextInserter {
    struct ReviewTarget { let application: TargetApplication }
    struct Delivery {
        let insertAtCursor: Bool
        let copyToClipboard: Bool
        let targetProcessID: Int32?
    }
    static var pendingRestore: (() -> Void)?
    static var restorationIsCurrent: (() -> Bool)?
    static var restoreResult: Int32? = 42
    static var restorationTarget: ReviewTarget?
    static var deliveries: [String] = []
    static var deliveryRequests: [Delivery] = []
    static var pendingDeliveries: [() -> Void] = []
    static var contextCompletions: [(String?) -> Void] = []
    static var contextReads = 0, targetReads = 0
    static var readableContext: String?
    static var contextSnapshot: ReviewTarget?
    static func captureReviewTarget() -> ReviewTarget? { targetReads += 1; return contextSnapshot }
    static func textBeforeCursor() -> String? { contextReads += 1; return readableContext }
    static func resolveTextBeforeCursor(fallback: String?, allowWhilePhysicalModifiersPressed: Bool,
                                        completion: @escaping (String?) -> Void) {
        contextCompletions.append(completion)
    }
    static func deliver(_ text: String, insertionText: String?, insertAtCursor: Bool,
                        copyToClipboard: Bool, targetProcessID: Int32?, completion: (() -> Void)?) {
        deliveries.append(text)
        deliveryRequests.append(Delivery(insertAtCursor: insertAtCursor,
                                         copyToClipboard: copyToClipboard,
                                         targetProcessID: targetProcessID))
        if insertAtCursor {
            pendingDeliveries.append { completion?() }
        } else {
            completion?()
        }
    }
    static func finishDelivery() { pendingDeliveries.removeFirst()() }
    static func finishContext(_ text: String?) { contextCompletions.removeFirst()(text) }
    static func restoreReviewTarget(_ target: ReviewTarget?, isCurrent: @escaping () -> Bool,
                                    completion: @escaping (Int32?) -> Void) {
        restorationIsCurrent = isCurrent
        restorationTarget = target
        // Deliberately invoke even a stale completion: AppDelegate must fence it.
        pendingRestore = { completion(restoreResult) }
    }
}
final class DictationReviewPanel {
    let completion: (String?, Bool) -> Void
    var cancellations = 0
    init(review: DictationReview, savesChoices: Bool, completion: @escaping (String?, Bool) -> Void) {
        self.completion = completion
    }
    func show() {}
    func cancel() { cancellations += 1; completion(nil, false) }
}
final class CorrectionStore {
    static let shared = CorrectionStore()
    var onChange: (() -> Void)?
    var records = 0
    func record(_ review: DictationReview, chosenText: String, model: String, manual: Bool) { records += 1 }
}

final class Harness {
    static let speechEngineStartupTimeout: TimeInterval = 20
    let capture = Capture(), state = State(), settings = Settings(), panel = Panel(), windows = Windows()
    var asr: ASRService!, hotkey: HotKeyMonitor!
    var isASRReady = false, shouldShowFirstDictationCoach = false
    var hasResolvedPrecedingText = false, isResolvingPrecedingText = false
    var precedingTextAtDictationStart: String?, resolvedPrecedingText: String?
    var reviewPanel: DictationReviewPanel?, reviewTarget: TextInserter.ReviewTarget?
    var speechEngineStartupWork: DispatchWorkItem?, dismissWork: DispatchWorkItem?
    var speechEngineStartedAt: TimeInterval?
    var speechEngineGeneration = 0, cursorContextGeneration = 0
    var activeCursorContextGeneration: Int?
    var needsCursorSnapshotAfterDelivery = false
    var pendingTranscriptDeliveries = 0
    var transcriptDeliveryGate = TranscriptDeliveryGate()
    var services: [ASRService] = []
    var delivered: [String] { TextInserter.deliveries }
    var failNextLaunch = false
    func makeService() throws -> ASRService {
        let service = ASRService()
        service.shouldFailStart = failNextLaunch
        failNextLaunch = false
        services.append(service)
        return service
    }
    func refreshStatusMenu() {}
    func refreshLearnedContext() {}
    func scheduleAutomaticUpdatePrompt() {}
    func markFirstDictationCoachHandled() {}
    func presentFirstDictationCoachIfReady() {}
    func prepareDelivery(_ text: String, review: DictationReview? = nil) -> DeferredTranscriptDelivery {
        DeferredTranscriptDelivery(text: text, adjustForCursor: false, review: review)
    }

    // PRODUCTION_METHODS
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
func readyApp() -> Harness {
    let app = Harness()
    app.startSpeechEngine()
    app.asr.onEvent?(.ready(ms: 1))
    return app
}
func listeningApp() -> Harness {
    let app = readyApp()
    check(app.beginDictation(), "ready engine accepts dictation")
    app.hotkey.active = true
    return app
}
let scenario = CommandLine.arguments[1]
switch scenario {
case "background-startup":
    let app = Harness()
    app.startSpeechEngine()
    let service = app.asr!
    check(!app.capture.capturing && !app.state.timerRunning, "background startup never opens microphone")
    check(app.state.phase == .idle && !app.panel.isVisible, "background startup has no HUD")
    service.onEvent?(.ready(ms: 1))
    check(app.isASRReady && app.speechEngineStartupWork == nil, "startup acknowledges readiness and cancels timeout")
    check(app.state.phase == .idle && !app.panel.isVisible && app.dismissWork == nil, "readiness stays silent")
    check(service.begins == 0 && service.stops == 0, "idle engine receives no utterances")
    app.startSpeechEngine()
    check(app.services.count == 1 && service.starts == 1, "resident model is reused")
    for _ in 0..<2 {
        check(app.beginDictation(), "resident engine starts on first shortcut")
        app.endDictation()
        service.onEvent?(.final(text: "", secs: 1, ms: 1, review: nil))
    }
    check(app.services.count == 1 && app.isASRReady, "readiness remains valid between dictations")
case "record-during-startup":
    let app = Harness()
    app.startSpeechEngine()
    let service = app.asr!
    check(!app.isASRReady && app.beginDictation(), "cold engine accepts first shortcut")
    check(app.capture.capturing && app.state.timerRunning, "capture and safety limit start before readiness")
    check(app.state.phase == .listening && app.panel.isVisible && service.begins == 1, "recording HUD replaces warmup")
    check(!app.beginDictation() && service.begins == 1, "duplicate start cannot reset queued audio")
    let presentation = app.panel.presentationGeneration
    service.onEvent?(.ready(ms: 1))
    check(app.capture.capturing && app.state.phase == .listening, "readiness preserves active recording")
    check(app.panel.presentationGeneration == presentation && app.dismissWork == nil, "readiness never shows or dismisses a HUD")
    app.endDictation()
    check(service.stops == 1 && !app.capture.capturing, "release stops cold-start recording normally")
case "release-during-startup":
    let app = Harness()
    check(app.beginDictation(), "first shortcut launches engine and records")
    let service = app.asr!
    app.endDictation()
    check(!app.isASRReady && app.state.phase == .thinking, "early release waits for transcript")
    check(!app.capture.capturing && !app.state.timerRunning && service.stops == 1, "early release stops capture and queues finalization")
    check(!app.beginDictation(), "pending cold-start final cannot be replaced")
    service.onEvent?(.ready(ms: 1))
    check(app.state.phase == .thinking && app.panel.isVisible, "readiness does not dismiss pending transcript")
    service.onEvent?(.final(text: "first words", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["first words"], "cold-start utterance delivers without another shortcut")
case "record-during-reload":
    let app = readyApp()
    app.reloadASR()
    check(!app.isASRReady && app.settings.isReloadingModel, "model reload runs in background")
    check(app.beginDictation() && app.capture.capturing, "reload does not block capture")
    app.asr.onEvent?(.ready(ms: 1))
    check(!app.settings.isReloadingModel && app.state.phase == .listening, "reload readiness preserves recording")
    app.endDictation()
    app.asr.onEvent?(.final(text: "new model", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["new model"], "replacement model delivers queued dictation")
case "failures":
    for phase in [Phase.listening, .thinking, .idle] {
        for event in [ASRService.Event.error("injected"), .terminated("injected")] {
            let app = listeningApp()
            let service = app.asr!
            app.state.phase = phase
            app.state.level = 0.8
            app.settings.isReloadingModel = true
            let generation = app.speechEngineGeneration
            let timeout = app.speechEngineStartupWork
            _ = app.transcriptDeliveryGate.submit(app.prepareDelivery("aborted"), whileContextIsResolving: true)
            app.panel.onPresent = {
                check(!app.capture.capturing, "failure HUD must not precede capture stop")
                check(!app.state.timerRunning && !app.hotkey.active, "failure HUD must follow timer/key cleanup")
            }
            service.onEvent?(event)
            check(app.state.phase == .failed("injected"), "failure message remains visible")
            check(app.state.level == 0, "audio meter cleared")
            check(app.asr == nil && service.shutdowns == 1, "failed process retired exactly once")
            check(!app.isASRReady, "readiness revoked")
            check(!app.settings.isReloadingModel, "settings reload spinner stopped")
            check(app.speechEngineGeneration > generation, "old event generation retired")
            check(timeout?.isCancelled != false && app.speechEngineStartupWork == nil, "startup timeout cancelled")
            check(app.speechEngineStartedAt == nil, "startup timing cleared")
            check(app.transcriptDeliveryGate.pending == nil, "pending transcript discarded")
            app.endDictation() // Physical release arrives after the failure.
            check(service.stops == 0, "release must not finalize an aborted utterance")
            app.dismissWork?.perform()
            check(app.state.phase == .idle && !app.capture.capturing, "dismissal cannot leave microphone running")
        }
    }
case "late-events":
    let app = listeningApp()
    let old = app.asr!
    old.onEvent?(.error("injected"))
    check(app.beginDictation(), "first retry starts recording while engine restarts")
    let fresh = app.asr!
    check(fresh !== old, "retry creates a new process")
    fresh.onEvent?(.ready(ms: 1))
    check(app.capture.capturing && app.state.phase == .listening, "new generation keeps recording after readiness")
    old.onEvent?(.partial(committed: "stale", tail: "tail"))
    old.onEvent?(.error("stale error"))
    old.onEvent?(.terminated("stale exit"))
    check(app.state.phase == .listening && app.state.committed.isEmpty, "old callbacks cannot corrupt the recording")
    app.endDictation()
    old.onEvent?(.final(text: "stale final", secs: 1, ms: 1, review: nil))
    old.onEvent?(.ready(ms: 1))
    check(app.delivered.isEmpty && app.state.phase == .thinking, "old final/readiness cannot consume new session")
    fresh.onEvent?(.final(text: "current", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["current"], "only current final is delivered")
case "retry":
    let app = listeningApp()
    let monitor = app.hotkey!
    app.asr.onEvent?(.terminated("injected"))
    check(app.hotkey.onStart?() == true, "next shortcut retries engine and starts capture")
    check(app.services.count == 2 && app.hotkey === monitor, "retry reuses keyboard monitor")
    check(app.capture.capturing && app.state.phase == .listening, "retry records immediately")
    app.asr.onEvent?(.ready(ms: 1))
    check(app.capture.capturing && app.state.phase == .listening, "readiness does not interrupt recording")
case "launch-failure":
    let app = Harness()
    app.failNextLaunch = true
    app.startSpeechEngine()
    check(app.asr == nil && app.hotkey?.onStart != nil, "input survives process launch failure")
    check(app.hotkey.onStart?() == true && app.asr != nil, "shortcut recovers failed launch and records")
    let service = app.asr!
    app.speechEngineStartupWork?.perform()
    check(app.asr == nil && service.shutdowns == 1, "startup timeout uses complete failure cleanup")
    check(!app.capture.capturing && !app.isASRReady, "timeout leaves microphone off and engine unready")
case "microphone-failure":
    let app = readyApp()
    app.capture.shouldFailStart = true
    let service = app.asr!
    check(!app.beginDictation(), "microphone launch failure rejects recording")
    check(!app.capture.capturing && app.asr == nil && service.shutdowns == 1, "microphone launch failure retires utterance")
    let route = listeningApp()
    route.capture.onFailure?(InjectedFailure.failed)
    check(!route.capture.capturing && route.asr == nil && !route.hotkey.active, "route failure cancels active capture and key state")
case "review-cancel":
    let app = readyApp()
    app.state.phase = .thinking
    let target = TargetApplication()
    app.reviewTarget = TextInserter.ReviewTarget(application: target)
    app.presentReview(DictationReview(), precedingText: nil)
    let review = app.reviewPanel!
    app.asr.onEvent?(.terminated("injected"))
    check(review.cancellations == 1 && app.reviewPanel == nil && app.reviewTarget == nil, "failure closes pending review")
    review.completion("stale selection", false)
    check(app.delivered.isEmpty && CorrectionStore.shared.records == 0, "stale review cannot insert or learn text")
    check(target.activations == 0 && app.state.phase == .failed("injected"), "cancel callback cannot reactivate target or overwrite failure")
case "review-restore":
    let app = readyApp()
    app.settings.autoInsert = true
    app.state.phase = .thinking
    app.presentReview(DictationReview(), precedingText: nil)
    app.reviewPanel!.completion("chosen", false)
    check(TextInserter.restorationIsCurrent?() == true, "live review can restore focus")
    app.asr.onEvent?(.error("injected"))
    check(TextInserter.restorationIsCurrent?() == false, "focus restoration observes engine invalidation")
    TextInserter.pendingRestore?()
    check(app.delivered.isEmpty && app.state.phase == .failed("injected"), "late focus callback cannot paste after failure")
case "review-insert", "review-fallback":
    let app = readyApp()
    app.settings.autoInsert = true
    app.settings.copyToClipboard = false
    app.settings.reviewUncertainWords = true
    let target = TargetApplication()
    TextInserter.contextSnapshot = TextInserter.ReviewTarget(application: target)
    check(app.beginDictation(), "review dictation starts")
    app.endDictation()
    app.asr.onEvent?(.final(text: "uncertain", secs: 1, ms: 1, review: DictationReview()))
    check(app.reviewPanel != nil && app.delivered.isEmpty, "uncertain text waits for confirmation")
    app.reviewPanel!.completion("confirmed choice", false)
    check(app.reviewPanel == nil && app.delivered.isEmpty, "confirmation waits for focus before inserting")
    check(TextInserter.restorationTarget?.application === target, "confirmation restores the dictation target")
    if scenario == "review-fallback" { TextInserter.restoreResult = nil }
    TextInserter.pendingRestore?()
    check(app.delivered == ["confirmed choice"], "confirmed text is delivered exactly once")
    let delivery = TextInserter.deliveryRequests.last!
    if scenario == "review-insert" {
        check(delivery.insertAtCursor && delivery.targetProcessID == 42, "confirmed text automatically pastes into the restored application")
        check(!delivery.copyToClipboard, "successful insertion preserves clipboard preference")
        check(app.state.phase == .inserted, "successful confirmation shows success")
        TextInserter.finishDelivery()
    } else {
        check(!delivery.insertAtCursor && delivery.copyToClipboard, "failed restoration safely retains text on clipboard")
        check(app.state.phase == .failed("Copied — return to your original field to paste"), "fallback explains how to retrieve text")
    }
    check(app.pendingTranscriptDeliveries == 0, "confirmation leaves no pending delivery")
    check(app.dismissWork != nil, "confirmation schedules HUD dismissal on both paths")
    app.dismissWork?.perform()
    check(!app.panel.isVisible && app.state.phase == .idle, "confirmation cannot leave the preview stuck")
case "reload":
    let app = listeningApp()
    let service = app.asr!
    app.reloadASR()
    check(!app.capture.capturing && !app.hotkey.active && service.shutdowns == 1, "model reload cancels active recording")
    app.endDictation()
    check(app.asr.stops == 0, "late release cannot stop replacement engine")
    app.failNextLaunch = true
    app.reloadASR()
    check(app.asr == nil && !app.settings.isReloadingModel, "failed model reload uses failure cleanup")
case "normal":
    let app = listeningApp()
    let service = app.asr!
    app.endDictation()
    check(!app.capture.capturing && !app.state.timerRunning, "normal release stops recording")
    check(app.state.phase == .thinking && service.stops == 1 && service.shutdowns == 0, "normal release finalizes without retiring engine")
    service.onEvent?(.final(text: "normal", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["normal"], "normal final still delivers")
case "retry-failure-dismiss":
    let app = readyApp()
    app.asr.onEvent?(.terminated("injected"))
    for _ in 0..<2 {
        app.failNextLaunch = true
        check(!app.beginDictation(), "failed shortcut retry does not record")
        check(app.panel.isVisible, "retry failure shows its message")
        app.dismissWork?.perform()
        check(!app.panel.isVisible && app.state.phase == .idle, "retry failure can dismiss back to idle")
    }
    check(app.beginDictation() && app.capture.capturing, "later retry records during startup")
    app.asr.onEvent?(.ready(ms: 1))
    check(app.state.phase == .listening && app.capture.capturing, "later successful retry keeps recording")
case "clipboard-probe-waits":
    let app = readyApp()
    app.settings.autoInsert = true
    app.settings.contextAwareCapitalization = true
    app.deliverFinalTranscript("first", precedingText: nil, adjustForCursor: false)
    check(app.pendingTranscriptDeliveries == 1, "first paste is in flight")
    check(app.beginDictation() && app.capture.capturing, "next recording starts without waiting for clipboard")
    check(TextInserter.contextCompletions.isEmpty, "next probe cannot touch clipboard before first paste completes")
    app.endDictation()
    app.asr.onEvent?(.final(text: "second", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["first"], "second final waits for previous paste")
    TextInserter.finishDelivery()
    check(TextInserter.contextCompletions.count == 1, "completed paste starts exactly one waiting probe")
    check(app.delivered == ["first"], "second final also waits for its cursor probe")
    TextInserter.finishContext("first ")
    check(app.delivered == ["first", "second"], "second final delivers after both clipboard owners settle")
    TextInserter.finishDelivery()
    check(app.pendingTranscriptDeliveries == 0, "all deliveries complete")
case "clipboard-final-waits":
    let app = readyApp()
    app.settings.autoInsert = true
    app.deliverFinalTranscript("first", precedingText: nil, adjustForCursor: false)
    check(app.beginDictation(), "new recording is allowed with context feature off")
    app.endDictation()
    app.asr.onEvent?(.final(text: "second", secs: 1, ms: 1, review: nil))
    check(app.delivered == ["first"], "even a final without a probe waits for the previous clipboard operation")
    TextInserter.finishDelivery()
    check(app.delivered == ["first", "second"], "queued final resumes when clipboard is free")
    check(TextInserter.contextCompletions.isEmpty, "disabled context feature never probes")
    TextInserter.finishDelivery()
case "deferred-context-snapshot":
    let app = readyApp()
    app.settings.autoInsert = true
    app.settings.contextAwareCapitalization = true
    app.settings.reviewUncertainWords = true
    app.deliverFinalTranscript("first", precedingText: nil, adjustForCursor: false)
    TextInserter.readableContext = "before first paste"
    check(app.beginDictation(), "recording starts immediately")
    check(TextInserter.contextReads == 0 && TextInserter.targetReads == 0, "cursor snapshot waits for first insertion")
    let target = TargetApplication()
    TextInserter.contextSnapshot = TextInserter.ReviewTarget(application: target)
    TextInserter.readableContext = "after first paste "
    TextInserter.finishDelivery()
    check(app.resolvedPrecedingText == "after first paste ", "capitalization uses the post-paste context")
    check(app.reviewTarget?.application === target, "word review remembers the post-paste target")
    check(TextInserter.contextCompletions.isEmpty, "readable context avoids keyboard probing")
case "deferred-probe-cancelled":
    for reload in [false, true] {
        for finalAlreadyReceived in [false, true] {
            let app = readyApp()
            app.settings.autoInsert = true
            app.settings.contextAwareCapitalization = true
            app.deliverFinalTranscript("first", precedingText: nil, adjustForCursor: false)
            let deliveredCount = app.delivered.count
            check(app.beginDictation(), "recording starts during previous delivery")
            if finalAlreadyReceived {
                app.endDictation()
                app.asr.onEvent?(.final(text: "aborted", secs: 1, ms: 1, review: nil))
            }
            if reload { app.reloadASR() } else { app.asr.onEvent?(.error("injected")) }
            TextInserter.finishDelivery()
            check(TextInserter.contextCompletions.isEmpty, "cancelled recording cannot start a delayed keyboard probe")
            check(app.pendingTranscriptDeliveries == 0, "cancellation still allows previous paste to finish")
            check(app.delivered.count == deliveredCount, "cancelled queued final is never inserted")
        }
    }
default: fatalError("Unknown scenario: \(scenario)")
}
print("PASS \(scenario): \(checks) checks")
