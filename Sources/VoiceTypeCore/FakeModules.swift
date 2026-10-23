import Foundation

/// Scriptable modules only. These classes never import AVFoundation, Speech, AppKit or call HTTP.
public final class FakeAudioRecorder: AudioRecording {
    public let clock: VirtualScheduler
    public var startDelay: Milliseconds = 0
    public var stopDelay: Milliseconds = 20
    public var cleanupDelay: Milliseconds = 0
    public var voiceDelay: Milliseconds? = 10
    public var failStart = false
    public var failStop = false
    public var neverStart = false
    public var neverStop = false
    public private(set) var starts: [OperationToken] = []
    public private(set) var stops: [OperationToken] = []
    public private(set) var lateCloses: [OperationToken] = []
    public private(set) var active: Set<OperationToken> = []
    public init(clock: VirtualScheduler) { self.clock = clock }
    public func start(_ token: OperationToken, callback: @escaping ModuleCallback) {
        starts.append(token)
        guard !neverStart else { return }
        clock.after(startDelay) { [weak self] in
            guard let self = self else { return }
            if self.failStart { callback(token, .audioStartFailed) }
            else {
                self.active.insert(token); callback(token, .audioStarted)
                if let delay = self.voiceDelay { self.clock.after(delay) { callback(token, .voiceDetected) } }
            }
        }
    }
    public func stop(_ token: OperationToken, callback: @escaping ModuleCallback) {
        stops.append(token)
        guard !neverStop else { return }
        clock.after(stopDelay) { [weak self] in
            guard let self = self else { return }
            if self.failStop { callback(token, .audioStopFailed) }
            else { self.active = self.active.filter { $0.session != token.session }; callback(token, .audioStopped) }
        }
    }
    public func closeLate(_ token: OperationToken) { lateCloses.append(token); active.remove(token) }
    public func cleanup(session: UInt64, completion: @escaping () -> Void) {
        clock.after(cleanupDelay) { [weak self] in self?.active = self?.active.filter { $0.session != session } ?? []; completion() }
    }
}

public struct SpeechEmission {
    public let delay: Milliseconds
    public let response: ModuleResponse
    public init(delay: Milliseconds, response: ModuleResponse) { self.delay = delay; self.response = response }
}
public struct FakeSpeechSegment {
    public let emissions: [SpeechEmission]
    public let finalText: String?
    public let finalDelay: Milliseconds
    public init(emissions: [SpeechEmission] = [], finalText: String? = "", finalDelay: Milliseconds = 30) {
        self.emissions = emissions; self.finalText = finalText; self.finalDelay = finalDelay
    }
}
public final class FakeTranscriber: Transcribing {
    public let clock: VirtualScheduler
    public var emissions: [SpeechEmission] = [.init(delay: 80, response: .partial("测试文本。"))]
    public var finalText: String? = "测试文本。"
    public var finalDelay: Milliseconds = 30
    public var continuationSegments: [FakeSpeechSegment] = []
    public private(set) var starts: [(OperationToken, RecognitionPolicy)] = []
    public private(set) var rotations: [(OperationToken, OperationToken)] = []
    public private(set) var ended: [UInt64] = []
    public private(set) var cancelled: [UInt64] = []
    private var callbacks: [OperationToken: ModuleCallback] = [:]
    private var current: [UInt64: OperationToken] = [:]
    private var indices: [OperationToken: Int] = [:]
    private var finished: Set<OperationToken> = []
    public init(clock: VirtualScheduler) { self.clock = clock }
    public func start(_ token: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        startSegment(token, index: 0, policy: policy, callback: callback)
    }
    private func continuation(_ index: Int) -> FakeSpeechSegment {
        index > 0 && index <= continuationSegments.count ? continuationSegments[index - 1] : .init()
    }
    private func startSegment(_ token: OperationToken, index: Int, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        starts.append((token, policy)); callbacks[token] = callback; current[token.session] = token
        indices[token] = index
        let script = index == 0 ? emissions : continuation(index).emissions
        for emission in script {
            clock.after(emission.delay) { [weak self] in
                if case .final = emission.response { self?.finished.insert(token) }
                callback(token, emission.response)
            }
        }
    }
    public func rotate(previous: OperationToken, next: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        rotations.append((previous, next))
        let index = (indices[previous] ?? 0) + 1
        finish(previous)
        startSegment(next, index: index, policy: policy, callback: callback)
    }
    public func end(session: UInt64) {
        ended.append(session)
        if let op = current[session] { finish(op) }
    }
    private func finish(_ op: OperationToken) {
        guard let index = indices[op], !finished.contains(op), let callback = callbacks[op] else { return }
        let text = index == 0 ? finalText : continuation(index).finalText
        let finalDelay = index == 0 ? self.finalDelay : continuation(index).finalDelay
        guard let text = text else { return }
        finished.insert(op)
        clock.after(finalDelay) { callback(op, .final(text)) }
    }
    public func cancel(session: UInt64) {
        cancelled.append(session)
        // Deliberately permit already enqueued callbacks to arrive: the reducer must reject them.
        current.removeValue(forKey: session)
        callbacks = callbacks.filter { $0.key.session != session }
        indices = indices.filter { $0.key.session != session }
        finished = finished.filter { $0.session != session }
    }
}

public enum FakeModelResult { case echo, success(String, complete: Bool), failure, never }
public final class FakeTextProcessor: TextProcessing {
    public let clock: VirtualScheduler
    public var localDelay: Milliseconds = 5
    public var modelDelay: Milliseconds = 100
    public var localOverride: String?
    public var failLocal = false
    public var modelResult: FakeModelResult = .echo
    public private(set) var localRequests: [(OperationToken, String, CleanupPreferences)] = []
    public private(set) var modelRequests: [(OperationToken, String, Bool)] = []
    public private(set) var cancellations: [UInt64] = []
    public init(clock: VirtualScheduler) { self.clock = clock }
    public func clean(_ token: OperationToken, text: String, preferences: CleanupPreferences, callback: @escaping ModuleCallback) {
        localRequests.append((token, text, preferences))
        let output = localOverride ?? TextProcessor().clean(text, preferences: preferences)
        let failed = failLocal
        clock.after(localDelay) { callback(token, failed ? .localFailed : .localProcessed(output)) }
    }
    public func polish(_ token: OperationToken, text: String, preferences: CleanupPreferences, preferZDR: Bool, callback: @escaping ModuleCallback) {
        modelRequests.append((token, text, preferZDR))
        let result = modelResult
        if case .never = result { return }
        clock.after(modelDelay) {
            switch result {
            case .echo: callback(token, .modelResult(text: text, complete: true))
            case .success(let output, let complete): callback(token, .modelResult(text: output, complete: complete))
            case .failure: callback(token, .modelFailed)
            case .never: break
            }
        }
    }
    public func cancel(session: UInt64) { cancellations.append(session) }
}

/// Convenient dependency graph for integration tests; not attached to the menu-bar UI.
public final class FakeSessionSystem {
    public let clock = VirtualScheduler()
    public let hotkeys = FakeHotkeyMonitor()
    public let audio: FakeAudioRecorder
    public let transcriber: FakeTranscriber
    public let processor: FakeTextProcessor
    public let clipboard = FakeClipboard()
    public let inserter: FakeTextInserter
    public let hud = FakeHUD()
    public let metrics = InMemoryMetrics()
    public let coordinator: SessionCoordinator
    public init(preferences: SessionPreferences = .init(), environment: SessionEnvironment = .init()) {
        audio = FakeAudioRecorder(clock: clock)
        transcriber = FakeTranscriber(clock: clock)
        processor = FakeTextProcessor(clock: clock)
        inserter = FakeTextInserter(clock: clock, clipboard: clipboard)
        coordinator = SessionCoordinator(machine: .init(preferences: preferences, environment: environment), scheduler: clock, audio: audio, transcriber: transcriber, processor: processor, inserter: inserter, hud: hud, metrics: metrics)
        coordinator.connect(hotkeys)
    }
    public func start() { hotkeys.emit(.rightOptionDown(eligible: true)); clock.advance(by: 0) }
    public func holdAndRelease(after duration: Milliseconds = 400) { start(); clock.advance(by: duration); hotkeys.emit(.rightOptionUp) }
    public func finish(after duration: Milliseconds = 1_500) { clock.advance(by: duration) }
}
