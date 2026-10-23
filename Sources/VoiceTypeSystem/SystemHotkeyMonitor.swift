import AppKit
import CoreGraphics
import VoiceTypeCore

/// Passive NSEvent monitors (require Accessibility trust). They observe only; no key is swallowed or altered.
public final class SystemHotkeyMonitor: HotkeyMonitoring {
    public var onEvent: ((SessionEvent) -> Void)?
    private var interpreter = HotkeyInterpreter()
    private var monitors: [Any] = []
    public private(set) var installedWhileTrusted = false
    public private(set) var rightOptionPressCount = 0
    public init() {}

    public func install() {
        uninstall()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        guard AXIsProcessTrusted() else { return }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event) })
        if let global = global {
            monitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.handle(event); return event })
        if let local = local {
            monitors.append(local)
        }
        installedWhileTrusted = AXIsProcessTrusted() && global != nil && local != nil
    }

    public func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        installedWhileTrusted = false
        let wasDown = interpreter.rightOptionDown
        interpreter = HotkeyInterpreter()
        if wasDown { onEvent?(.rightOptionUp) }
    }

    private func handle(_ event: NSEvent) {
        let events: [SessionEvent]
        switch event.type {
        case .flagsChanged:
            let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
            let sideBits = flags & (HotkeyInterpreter.rightOptionMask | HotkeyInterpreter.leftOptionMask)
            let physical: Bool? = sideBits == 0 && flags & HotkeyInterpreter.optionMask != 0
                ? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(HotkeyInterpreter.rightOptionKeyCode)) : nil
            events = interpreter.flagsChanged(keyCode: event.keyCode, flags: flags, physicalRightOptionDown: physical)
        case .keyDown: events = interpreter.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)
        default: events = []
        }
        events.forEach {
            if case .rightOptionDown = $0 { rightOptionPressCount += 1 }
            onEvent?($0)
        }
    }

    /// Called by the session guard: synthesizes a missed release from the physical modifier state.
    public func reconcilePhysicalState() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        interpreter.reconcile(physicalFlags: flags).forEach { onEvent?($0) }
    }
}
