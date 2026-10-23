import AppKit
import VoiceTypeCore
import VoiceTypeSystem

/// Wires live adapters to the single-source-of-truth coordinator. Every callback is delivered on main.
final class LiveSession {
    let scheduler = LiveScheduler()
    let audio = SystemAudioRecorder()
    let transcriber: SpeechTranscriber
    let processor = LocalTextProcessor()
    let clipboard = ClipboardManager()
    let inserter: SystemTextInserter
    let hud = HUDController()
    let metrics = MetricsLog()
    let hotkeys = SystemHotkeyMonitor()
    let probe = SystemEnvironmentProbe()
    private(set) var coordinator: SessionCoordinator!
    var interceptHotkey: ((SessionEvent) -> Bool)?
    var onMachineChange: ((SessionStateMachine) -> Void)?
    var onStateChange: ((SessionState) -> Void)?
    private var guardTimer: Timer?
    private var resetScheduled = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// 180ms stays the target; the hard watchdog leaves room for bounded AX + paste verification.
    static let timing = SessionTiming(insertionWatchdog: 500)

    init(preferences: SessionPreferences, localeIdentifier: String) {
        transcriber = SpeechTranscriber(localeIdentifier: localeIdentifier)
        inserter = SystemTextInserter(clipboard: clipboard)
        let speech = transcriber
        audio.onBuffer = { buffer in speech.append(buffer) }
        coordinator = SessionCoordinator(
            machine: SessionStateMachine(preferences: preferences, environment: probe.current(recognizer: transcriber.recognizer), timing: Self.timing),
            scheduler: scheduler, audio: audio, transcriber: transcriber, processor: processor,
            inserter: inserter, hud: hud, metrics: metrics)
        metrics.locale = { speech.localeIdentifier }
        clipboard.onRestore = { [metrics] result in metrics.recordClipboard(result) }
        inserter.safetyHandler = { [weak self] signals in self?.coordinator.send(.safetyChanged(signals)) }
        coordinator.insertionPreflight = { [probe, hotkeys] in
            var environment = probe.current(recognizer: speech.recognizer)
            environment.hotkeyPermission = hotkeys.installedWhileTrusted
            return environment
        }
        hotkeys.isSessionActive = { [weak self] in self?.coordinator.machine.isActive ?? false }
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        coordinator.onAfterSend = { [weak self] machine in self?.afterSend(machine) }
        observeSystem()
    }

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    var state: SessionState { coordinator.machine.state }

    func send(_ event: SessionEvent) { coordinator.send(event) }

    private func handle(_ event: SessionEvent) {
        if interceptHotkey?(event) == true { return }
        switch event {
        case .escape, .interrupted(.listenerLost):
            coordinator.send(event, deferringSideEffects: true)
            return
        default: break
        }
        if case .rightOptionDown = event, coordinator.machine.state == .idle {
            // Fresh permissions, on-device capability, foreground PID and the two danger signals at key down.
            var environment = probe.current(recognizer: transcriber.recognizer)
            environment.hotkeyPermission = hotkeys.installedWhileTrusted
            coordinator.send(.environmentChanged(environment))
        }
        coordinator.send(event)
    }

    private func afterSend(_ machine: SessionStateMachine) {
        if [.done, .error, .cancelled].contains(machine.state), !resetScheduled {
            resetScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.resetScheduled = false
                self?.coordinator.send(.reset)
            }
        }
        if machine.isActive { startGuard() } else { stopGuard() }
        onMachineChange?(machine)
        onStateChange?(machine.state)
    }

    /// Short-period guard while a session is active: danger signals, revoked permissions, missed key release.
    private func startGuard() {
        guard guardTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.guardTick() }
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
    }

    private func stopGuard() { guardTimer?.invalidate(); guardTimer = nil }

    private func guardTick() {
        guard coordinator.machine.isActive else { stopGuard(); return }
        let signals = SafetyProbe.current(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        if signals.blocks { coordinator.send(.safetyChanged(signals)); return }
        if !hotkeys.installedWhileTrusted { coordinator.send(.interrupted(.listenerLost)); return }
        if !SystemAudioRecorder.permissionGranted || !SpeechTranscriber.permissionGranted {
            coordinator.send(.interrupted(.permissionRevoked)); return
        }
        hotkeys.reconcilePhysicalState()
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.coordinator.send(.applicationChanged(app.processIdentifier))
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.coordinator.send(.interrupted(.sleeping))
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.coordinator.send(.interrupted(.locked))
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.coordinator.send(.interrupted(.locked))
        }))
        let app = NotificationCenter.default
        observers.append((app, app.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.coordinator.send(.interrupted(.quitting))
        }))
    }
}
