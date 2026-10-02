import Foundation

// Inert platform boundaries; capture/restore itself comes from TextInserter.
typealias CFTypeRef = AnyObject
typealias CFString = String
typealias CGWindowID = UInt32
let kAXSelectedTextRangeAttribute = "AXSelectedTextRange"
let kAXWindowAttribute = "AXWindow"
let kAXFocusedWindowAttribute = "AXFocusedWindow"
let kAXValueAttribute = "AXValue"
let kAXFocusedAttribute = "AXFocused"
let kAXRaiseAction = "AXRaise"
let kCGWindowOwnerPID = "pid", kCGWindowLayer = "layer", kCGWindowNumber = "number"
let kCGNullWindowID: UInt32 = 0
let kCFBooleanTrue = NSNumber(value: true)
enum AXError { case success }
final class AXUIElement: NSObject {
    let pid: pid_t
    var attributes: [String: AnyObject] = [:]
    init(_ pid: pid_t) { self.pid = pid }
}
struct CGWindowListOption: OptionSet {
    let rawValue: Int
    static let optionOnScreenOnly = Self(rawValue: 1)
    static let excludeDesktopElements = Self(rawValue: 2)
}
enum Platform {
    static var focused: AXUIElement?
    static var roots: [pid_t: AXUIElement] = [:]
    static var windowIDs: [CGWindowID] = [100]
    static var acceptsActivation = true
    static var acceptsRaise = true
}
final class NSRunningApplication {
    static let current = NSRunningApplication(ProcessInfo.processInfo.processIdentifier)
    let processIdentifier: pid_t
    let bundleIdentifier: String? = "test.custom-editor"
    var isTerminated = false
    var activations = 0
    init(_ pid: pid_t) { processIdentifier = pid }
    func activate(from app: NSRunningApplication, options: [Int]) {
        activations += 1
        if Platform.acceptsActivation { NSWorkspace.shared.frontmostApplication = self }
    }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
final class Application {
    var yieldedTo: NSRunningApplication?
    func yieldActivation(to app: NSRunningApplication) { yieldedTo = app }
}
let NSApp = Application()
enum Log { static func write(_ message: String) {} }
func CFEqual(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
    (lhs as? NSObject)?.isEqual(rhs) == true
}
func AXUIElementGetPid(_ element: AXUIElement, _ pid: inout pid_t) -> AXError {
    pid = element.pid
    return .success
}
func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement {
    if let root = Platform.roots[pid] { return root }
    let root = AXUIElement(pid)
    Platform.roots[pid] = root
    return root
}
func AXUIElementPerformAction(_ window: AXUIElement, _ action: String) {
    if Platform.acceptsRaise {
        AXUIElementCreateApplication(window.pid).attributes[kAXFocusedWindowAttribute] = window
    }
}
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ name: String, _ value: AnyObject) {
    if name == kAXFocusedAttribute { Platform.focused = element }
    else { element.attributes[name] = value }
}
func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ relativeTo: UInt32) -> Any? {
    Platform.windowIDs.map { [kCGWindowOwnerPID: NSNumber(value: 42),
                              kCGWindowLayer: NSNumber(value: 0),
                              kCGWindowNumber: NSNumber(value: $0)] }
}

// PRODUCTION_REVIEW_TARGET
    private static func focusedTextElement() -> AXUIElement? { Platform.focused }
    private static func attributeValue(of element: AXUIElement, named name: String) -> CFTypeRef? {
        element.attributes[name]
    }
    private static func uiElementAttribute(of element: AXUIElement, named name: String) -> AXUIElement? {
        element.attributes[name] as? AXUIElement
    }
}

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

MainActor.assumeIsolated {
    let scenario = CommandLine.arguments[1]
    let app = NSRunningApplication(42)
    NSWorkspace.shared.frontmostApplication = app
    let window = AXUIElement(42)
    let field = AXUIElement(scenario == "foreign-element" ? 43 : 42)
    let root = AXUIElementCreateApplication(42)
    if ["no-selection", "range", "text-markers", "document-changed"].contains(scenario) {
        Platform.focused = field
        field.attributes[kAXWindowAttribute] = window
        field.attributes[kAXValueAttribute] = "Existing draft" as NSString
        root.attributes[kAXFocusedWindowAttribute] = window
    } else if scenario == "foreign-element" {
        Platform.focused = field
    }
    let selectionName = scenario == "text-markers" ? "AXSelectedTextMarkerRange" : kAXSelectedTextRangeAttribute
    if scenario == "range" || scenario == "text-markers" {
        field.attributes[selectionName] = "original caret" as NSString
    }
    if scenario == "unknown-window" { Platform.windowIDs = [] }
    let target = TextInserter.captureReviewTarget()
    check(target != nil, "lack of Accessibility must not discard the original application")
    check(target?.application === app, "capture retains the dictation application")
    if scenario == "no-accessibility" || scenario == "foreign-element" {
        check(target?.element == nil && target?.selection == nil, "fallback does not invent an AX caret")
        check(target?.windowID == 100, "opaque editor retains its original window")
    }

    // The chooser steals focus, then the user confirms.
    NSWorkspace.shared.frontmostApplication = .current
    Platform.focused = nil
    if scenario == "document-changed" { field.attributes[kAXValueAttribute] = "Edited draft" as NSString }
    if scenario == "window-changed" { Platform.windowIDs = [200] }
    if scenario == "window-closed" { Platform.windowIDs = [] }
    if scenario == "application-quit" { app.isTerminated = true }
    if scenario == "activation-refused" { Platform.acceptsActivation = false }
    if scenario == "range" || scenario == "text-markers" {
        field.attributes[selectionName] = "moved caret" as NSString
    }
    var completed = false
    var restoredPID: pid_t?
    TextInserter.restoreReviewTarget(target, isCurrent: { scenario != "stale-review" }) {
        check(!completed, "restoration completes only once")
        completed = true
        restoredPID = $0
    }
    let deadline = Date().addingTimeInterval(2)
    while !completed && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    check(completed, "restore always completes, including failure paths")
    let shouldRestore = ["no-accessibility", "no-selection", "range", "text-markers", "foreign-element"].contains(scenario)
    check(restoredPID == (shouldRestore ? 42 : nil), "only the original live target can receive pasted text")
    if shouldRestore {
        check(NSWorkspace.shared.frontmostApplication === app, "target owns focus before paste")
        check(NSApp.yieldedTo === app, "chooser cooperatively returns activation")
    }
    if scenario == "range" || scenario == "text-markers" {
        check(field.attributes[selectionName] as? String == "original caret", "exact caret still restored for accessible editors")
    }
    if scenario == "stale-review" || scenario == "application-quit" {
        check(app.activations == 0, "stale or terminated targets cannot steal focus")
    }
    print("PASS \(scenario)")
}
