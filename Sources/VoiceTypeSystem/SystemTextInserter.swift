import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VoiceTypeCore

/// AX → paste → copy. Never infers success from an AX return code or a posted key event.
public final class SystemTextInserter: TextInserting {
    /// Reports an explicit danger signal to the coordinator (reducer fails with unsafeTarget).
    public var safetyHandler: ((SafetySignals) -> Void)?
    public let clipboard: ClipboardManager
    private let frontmostPID: () -> pid_t?
    /// Offsets from the write; AX usually reflects synchronously, paste needs the target's event loop.
    static let axChecks: [TimeInterval] = [0, 0.03, 0.07, 0.12]
    static let pasteChecks: [TimeInterval] = [0.03, 0.07, 0.12, 0.2]

    private struct Prepared { var element: AXUIElement?; var before: TextFieldSnapshot?; var original: PasteboardSnapshot? }
    private var prepared: [OperationToken: Prepared] = [:]

    public init(clipboard: ClipboardManager = ClipboardManager(),
                frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.clipboard = clipboard; self.frontmostPID = frontmostPID
    }

    private func blocked() -> Bool {
        let signals = SafetyProbe.current(pid: frontmostPID())
        guard signals.blocks else { return false }
        safetyHandler?(signals)
        return true
    }

    private func reply(_ token: OperationToken, _ response: ModuleResponse, _ callback: @escaping ModuleCallback) {
        DispatchQueue.main.async { callback(token, response) }
    }

    public func prepare(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback) {
        prepared = prepared.filter { $0.key.session == token.session }
        if blocked() { return }
        switch strategy {
        case .ax:
            // AX is only used where the result can be verified; otherwise go straight to paste.
            guard let element = AXSupport.focusedElement(pid: frontmostPID()),
                  AXSupport.isSettable(element, kAXSelectedTextAttribute),
                  let before = AXSupport.snapshot(element), before.characterCount != nil else {
                reply(token, .insertionPrepared(available: false), callback); return
            }
            prepared[token] = Prepared(element: element, before: before, original: nil)
        case .paste:
            // Posting Cmd+V needs Accessibility trust; an incomplete clipboard backup means copy instead.
            guard AXSupport.isTrusted, let original = clipboard.captureOriginal() else {
                reply(token, .insertionPrepared(available: false), callback); return
            }
            let element = AXSupport.focusedElement(pid: frontmostPID())
            prepared[token] = Prepared(element: element, before: element.flatMap(AXSupport.snapshot), original: original)
        case .copy:
            prepared[token] = Prepared(element: nil, before: nil, original: nil)
        }
        reply(token, .insertionPrepared(available: true), callback)
    }

    public func write(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback) {
        guard let item = prepared.removeValue(forKey: token) else { reply(token, .insertionResult(.definiteFailure), callback); return }
        if blocked() { reply(token, .insertionResult(.definiteFailure), callback); return }
        switch strategy {
        case .ax:
            guard let element = item.element, let before = item.before else { reply(token, .insertionResult(.definiteFailure), callback); return }
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            verify(element, before, text, checks: Self.axChecks, unchanged: .definiteFailure, token, callback)
        case .paste:
            guard let original = item.original else { reply(token, .insertionResult(.definiteFailure), callback); return }
            guard let owned = clipboard.writeForPaste(text) else {
                original.restore(to: clipboard.pasteboard)
                reply(token, .insertionResult(.definiteFailure), callback); return
            }
            guard Self.postCommandV() else {
                original.restore(to: clipboard.pasteboard)
                reply(token, .insertionResult(.definiteFailure), callback); return
            }
            clipboard.scheduleRestore(original, owned: owned)
            if let element = item.element, let before = item.before {
                // A paste that cannot be observed is unknown, never a reason to paste again.
                verify(element, before, text, checks: Self.pasteChecks, unchanged: .unknown, token, callback)
            } else {
                reply(token, .insertionResult(.unknown), callback)
            }
        case .copy:
            reply(token, .insertionResult(clipboard.writeForManualPaste(text) ? .verifiedSuccess : .definiteFailure), callback)
        }
    }

    private func verify(_ element: AXUIElement, _ before: TextFieldSnapshot, _ text: String, checks: [TimeInterval],
                        unchanged: InsertionOutcome, _ token: OperationToken, _ callback: @escaping ModuleCallback) {
        let start = DispatchTime.now()
        func check(_ index: Int) {
            DispatchQueue.main.asyncAfter(deadline: start + checks[index]) {
                let observation = AXSupport.observe(element, before: before, text: text)
                if observation == .inserted { callback(token, .insertionResult(.verifiedSuccess)); return }
                if index + 1 < checks.count { check(index + 1); return }
                callback(token, .insertionResult(observation == .unchanged ? unchanged : .unknown))
            }
        }
        check(0)
    }

    static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
