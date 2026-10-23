import Foundation

/// Serial orchestration boundary. Live adapters must deliver every callback on the same serial (main) queue.
public final class SessionCoordinator {
    public private(set) var machine: SessionStateMachine
    public let scheduler: SessionScheduling
    public let audio: AudioRecording
    public let transcriber: Transcribing
    public let processor: TextProcessing
    public let inserter: TextInserting
    public let hud: HUDPresenting
    public let metrics: MetricsRecording
    public var autoRunEffects = true
    /// Observes the machine after each event (HUD lifetime, reset, safety polling). Must not mutate synchronously.
    public var onAfterSend: ((SessionStateMachine) -> Void)?
    private var queue: [SessionEffect] = []
    private var draining = false
    public private(set) var visitedStates: [SessionState] = [.idle]
    public var queuedEffectCount: Int { queue.count }
    public init(machine: SessionStateMachine = .init(), scheduler: SessionScheduling, audio: AudioRecording, transcriber: Transcribing, processor: TextProcessing, inserter: TextInserting, hud: HUDPresenting = FakeHUD(), metrics: MetricsRecording = InMemoryMetrics()) {
        self.machine = machine; self.scheduler = scheduler; self.audio = audio; self.transcriber = transcriber
        self.processor = processor; self.inserter = inserter; self.hud = hud; self.metrics = metrics
    }
    public func connect(_ hotkeys: HotkeyMonitoring) { hotkeys.onEvent = { [weak self] in self?.send($0) } }
    public func send(_ event: SessionEvent) {
        let before = machine.state
        queue += machine.send(event, at: scheduler.now)
        if before != machine.state { visitedStates.append(machine.state) }
        hud.update(state: machine.state, message: machine.hudMessage, caption: machine.liveCaption)
        if autoRunEffects { runEffects() }
        onAfterSend?(machine)
    }
    public func runEffects() {
        guard !draining else { return }
        draining = true
        while !queue.isEmpty { execute(queue.removeFirst()) }
        draining = false
    }
    public func runNextEffect() {
        guard !queue.isEmpty else { return }
        let wasDraining = draining; draining = true
        execute(queue.removeFirst()); draining = wasDraining
    }
    private var callback: ModuleCallback {
        { [weak self] token, response in self?.send(.response(token, response)) }
    }
    private func execute(_ effect: SessionEffect) {
        switch effect {
        case .startAudio(let token):
            guard machine.state == .recording, machine.context?.audioToken == token else { return }
            audio.start(token, callback: callback)
        case .stopAudio(let token):
            if machine.state == .finalizing, machine.context?.stopToken == token { audio.stop(token, callback: callback) }
        case .closeLateAudio(let token): audio.closeLate(token)
        case .startRecognition(let token, let policy):
            if machine.state == .recording, machine.context?.recognizerToken == token { transcriber.start(token, policy: policy, callback: callback) }
        case .rotateRecognition(let previous, let next, let policy):
            if machine.state == .recording, machine.context?.recognizerToken == next { transcriber.rotate(previous: previous, next: next, policy: policy, callback: callback) }
        case .endRecognition(let session):
            if machine.state == .finalizing, machine.context?.id == session { transcriber.end(session: session) }
        case .cancelRecognition(let session): transcriber.cancel(session: session)
        case .cleanText(let token, let text, let preferences):
            if machine.state == .processing, machine.isCurrent(token) { processor.clean(token, text: text, preferences: preferences, callback: callback) }
        case .polishText(let token, let text, let preferences, let preferZDR):
            if machine.state == .processing, machine.isCurrent(token) { processor.polish(token, text: text, preferences: preferences, preferZDR: preferZDR, callback: callback) }
        case .cancelModel(let session): processor.cancel(session: session)
        case .prepareInsertion(let token, let strategy, let text):
            if machine.state == .inserting, machine.isCurrent(token) { inserter.prepare(token, strategy: strategy, text: text, callback: callback) }
        case .writeInsertion(let token, let strategy, let text):
            guard machine.state == .inserting, machine.isCurrent(token), machine.context?.prepared == true, machine.context?.writeCommitted == false else { return }
            // No async gap between reducer authorization and the external write's entry point.
            send(.commitWrite(token))
            if machine.state == .inserting, machine.isCurrent(token), machine.context?.writeCommitted == true {
                inserter.write(token, strategy: strategy, text: text, callback: callback)
            }
        case .schedule(let timer):
            guard machine.context?.deadlines[timer.kind] == timer else { return }
            scheduler.schedule(at: timer.deadline, scope: .sessionTimer(timer.token.session)) { [weak self] in self?.send(.timer(timer)) }
        case .cancelTimers(let session): scheduler.cancelSessionTimers(session)
        case .cleanup(let session):
            audio.cleanup(session: session) { [weak self] in self?.send(.cleanupFinished(session)) }
        case .recordMetrics(let value): metrics.record(value)
        }
    }
}
