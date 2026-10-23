import AppKit
import CoreGraphics
import VoiceTypeCore

/// Keep the proven NSEvent right-Option monitors; a filtering tap owns only active-session Esc.
/// All callbacks and lifecycle operations run on the main run loop. Ordinary keys are untouched.
public final class SystemHotkeyMonitor: HotkeyMonitoring {
    public var onEvent: ((SessionEvent) -> Void)?
    /// Reads the reducer's current state, not a second copy of the session lifecycle.
    public var isSessionActive: () -> Bool = { false }
    private var interpreter = HotkeyInterpreter()
    private var escapeFilter = EscapeKeyFilter()
    private var monitors: [Any] = []
    private var escapeTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    public private(set) var reconnectAutomatically = true
    public private(set) var rightOptionPressCount = 0
    public var installedWhileTrusted: Bool {
        guard AXIsProcessTrusted(), monitors.count == 2, let tap = escapeTap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }
    public init() {}
    deinit { removeResources() }

    public func install() {
        uninstall()
        reconnectAutomatically = true
        guard AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<SystemHotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            return monitor.handleTap(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        escapeTap = tap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in self?.handle(event); return event }) {
            monitors.append(local)
        }
        if !installedWhileTrusted { uninstall() }
    }

    public func uninstall() {
        let hadResources = escapeTap != nil || !monitors.isEmpty
        // Cancel BEFORE releasing the old held key; otherwise a reconnect could finalize and insert.
        if hadResources { onEvent?(.interrupted(.listenerLost)) }
        let wasDown = interpreter.rightOptionDown
        removeResources()
        interpreter = HotkeyInterpreter()
        escapeFilter = EscapeKeyFilter()
        if wasDown { onEvent?(.rightOptionUp) }
    }

    private func removeResources() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let tap = escapeTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        escapeTap = nil
        tapSource = nil
    }

    /// Also tested with constructed (never posted) CGEvents, without global listeners or permissions.
    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A timeout may be reconnected later, but a user-disabled tap needs explicit reconnect.
            reconnectAutomatically = type != .tapDisabledByUserInput
            onEvent?(.interrupted(.listenerLost))
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let decision = escapeFilter.handle(keyCode: keyCode, isKeyDown: type == .keyDown,
                                           isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                                           sessionActive: isSessionActive())
        switch decision {
        case .passThrough: return Unmanaged.passUnretained(event)
        case .consume(let cancel):
            if cancel { onEvent?(.escape) }
            return nil
        }
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
        case .keyDown:
            // Esc is handled only by the filtering tap, including when VoiceType itself is frontmost.
            guard event.keyCode != HotkeyInterpreter.escapeKeyCode else { return }
            events = interpreter.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat)
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
