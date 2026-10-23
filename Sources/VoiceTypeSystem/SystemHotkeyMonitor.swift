import AppKit
import CoreGraphics
import VoiceTypeCore

/// Passive NSEvent monitors (require Accessibility trust). They observe only; no key is swallowed or altered.
public final class SystemHotkeyMonitor: HotkeyMonitoring {
    public var onEvent: ((SessionEvent) -> Void)?
    private var interpreter = HotkeyInterpreter()
    private var monitors: [Any] = []
    public private(set) var installedWhileTrusted = false
    public init() {}

    public func install() {
        uninstall()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event); return event }) {
            monitors.append(local)
        }
        installedWhileTrusted = AXIsProcessTrusted() && !monitors.isEmpty
    }

    public func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        installedWhileTrusted = false
    }

    private func handle(_ event: NSEvent) {
        let events: [SessionEvent]
        switch event.type {
        case .flagsChanged: events = interpreter.flagsChanged(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
        case .keyDown: events = interpreter.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)
        default: events = []
        }
        events.forEach { onEvent?($0) }
    }

    /// Called by the session guard: synthesizes a missed release from the physical modifier state.
    public func reconcilePhysicalState() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        interpreter.reconcile(physicalFlags: flags).forEach { onEvent?($0) }
    }
}
