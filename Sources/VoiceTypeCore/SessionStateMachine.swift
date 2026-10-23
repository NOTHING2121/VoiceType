import Foundation

/// Deterministic reducer. No clocks, permissions, microphone, network, or UI APIs.
public struct SessionStateMachine {
    public private(set) var state: SessionState = .idle
    public private(set) var context: SessionContext?
    public private(set) var preferences: SessionPreferences
    public private(set) var environment: SessionEnvironment
    public private(set) var rightOptionIsDown = false
    public private(set) var lastTime: Milliseconds = 0
    private var nextSession: UInt64 = 0
    private var nextOperation: UInt64 = 0
    private var effects: [SessionEffect] = []
    public init(preferences: SessionPreferences = .init(), environment: SessionEnvironment = .init()) {
        self.preferences = preferences; self.environment = environment
    }
    public var isActive: Bool { [.recording, .finalizing, .processing, .inserting].contains(state) }
    public var hudMessage: String? {
        guard state == .done, context?.metrics.deliveryPath == .copiedOnly else { return nil }
        return "已复制，按 command+v粘贴"
    }
    public func isCurrent(_ token: OperationToken) -> Bool {
        isActive && context?.id == token.session && context?.activeOperation == token
    }

    @discardableResult public mutating func send(_ event: SessionEvent, at timestamp: Milliseconds) -> [SessionEffect] {
        effects = []
        let now = max(lastTime, timestamp)
        lastTime = now
        expireDue(at: now)
        switch event {
        case .rightOptionDown(let eligible):
            guard eligible, !rightOptionIsDown else { break }
            rightOptionIsDown = true
            if state == .idle { begin(at: now) }
            else if state == .recording, context?.mode == .handsFree {
                context?.keyDownAt = now
                schedule(.hold, at: now + 250)
            }
        case .rightOptionUp:
            let wasDown = rightOptionIsDown
            rightOptionIsDown = false
            if state == .recording, wasDown, let c = context {
                let held = now - c.keyDownAt
                removeTimer(.hold)
                if c.mode == .pendingGesture {
                    if held >= 250 { context?.mode = .pushToTalk; stop(.released, at: now) }
                    else { context?.mode = .handsFree }
                } else if c.mode == .pushToTalk { stop(.released, at: now) }
                else { stop(.handsFreeTap, at: now) }
            }
            resetIfReady()
        case .escape: cancel(.escape, at: now)
        case .cancelFromHUD: cancel(.hud, at: now)
        case .combinationKey:
            if state == .recording, rightOptionIsDown { cancel(.combination, at: now) }
        case .applicationChanged(let pid):
            environment.foregroundPID = pid
            if isActive, pid != context?.startedPID {
                context?.appChanged = true; context?.metrics.appChanged = true
                if state == .inserting, context?.writeCommitted == false { prepare(.copy, at: now) }
            }
        case .environmentChanged(let value):
            environment = value
            if isActive {
                if value.safety.blocks { fail(.unsafeTarget, at: now) }
                else if !value.microphonePermission || !value.speechPermission || !value.hotkeyPermission { fail(.permissionMissing, at: now) }
                else if !value.deviceAvailable && state == .recording { deviceFailed(at: now) }
            }
        case .safetyChanged(let signals):
            environment.safety = signals
            if isActive && signals.blocks { fail(.unsafeTarget, at: now) }
        case .privacyChanged(let enabled):
            preferences.privacyMode = enabled
            if enabled, isActive {
                context?.preferences.privacyMode = true
                if context?.policy == .appleServerAllowed && [.recording, .finalizing].contains(state) { cancel(.privacyEnabled, at: now) }
                else if state == .processing, context?.metrics.timestamps["modelRequested"] != nil {
                    effects.append(.cancelModel(context!.id)); chooseLocal(.skippedPrivacyMode, at: now)
                }
                else if state == .inserting, context?.writeCommitted == false, context?.metrics.modelPath == .polished {
                    let local = context!.localText, strategy = context!.strategy
                    effects.append(.cancelModel(context!.id))
                    context?.deliveryText = local; context?.metrics.modelPath = .skippedPrivacyMode
                    mark("modelDiscarded", now); prepare(strategy, at: now)
                }
            }
        case .serverConsentChanged(let allowed):
            preferences.appleServerConsent = allowed
            if !allowed, context?.policy == .appleServerAllowed, [.recording, .finalizing].contains(state) { cancel(.serverConsentRevoked, at: now) }
        case .cleanupPreferencesChanged(let value): preferences.cleanup = value
        case .interrupted(let reason):
            switch reason {
            case .sleeping: cancel(.sleeping, at: now)
            case .locked: cancel(.locked, at: now)
            case .quitting: cancel(.quitting, at: now)
            case .listenerLost: cancel(.listenerLost, at: now)
            case .permissionRevoked: if isActive { fail(.permissionMissing, at: now) }
            case .deviceDisconnected: if state == .recording { deviceFailed(at: now) }
            }
            if reason == .locked || reason == .quitting || reason == .sleeping { clearText() }
        case .timer: break // expireDue already evaluates deadlines, independent of callback order.
        case .response(let token, let response): respond(token, response, at: now)
        case .cleanupFinished(let id):
            if context?.id == id && !isActive { context?.cleanupComplete = true; resetIfReady() }
        case .reset:
            if !isActive && state != .idle { context?.resetRequested = true; resetIfReady() }
        case .commitWrite(let token):
            if state == .inserting, context?.activeOperation == token, context?.prepared == true, context?.writeCommitted == false {
                if environment.safety.blocks { fail(.unsafeTarget, at: now) }
                else if environment.foregroundPID != context?.startedPID && context?.strategy != .copy {
                    context?.appChanged = true; context?.metrics.appChanged = true; prepare(.copy, at: now)
                } else {
                    context?.writeCommitted = true
                    mark("writeCommitted", now)
                }
            }
        }
        return effects
    }

    private mutating func token() -> OperationToken {
        nextOperation += 1
        return OperationToken(session: context!.id, operation: nextOperation)
    }
    private mutating func mark(_ name: String, _ time: Milliseconds, once: Bool = false) {
        if !once || context?.metrics.timestamps[name] == nil { context?.metrics.timestamps[name] = time }
    }
    private mutating func schedule(_ kind: TimerKind, at deadline: Milliseconds) {
        let timer = SessionTimer(token: token(), kind: kind, deadline: deadline)
        context?.deadlines[kind] = timer; effects.append(.schedule(timer))
    }
    private mutating func removeTimer(_ kind: TimerKind) { context?.deadlines.removeValue(forKey: kind) }
    private mutating func expireDue(at now: Milliseconds) {
        let due = (context?.deadlines.values.filter { $0.deadline <= now } ?? []).sorted {
            if $0.deadline == $1.deadline { return $0.token.operation < $1.token.operation }
            return $0.deadline < $1.deadline
        }
        for timer in due where context?.deadlines[timer.kind] == timer {
            removeTimer(timer.kind)
            switch timer.kind {
            case .hold:
                if state == .recording && rightOptionIsDown { context?.mode = .pushToTalk }
            case .audioStart:
                if state == .recording && context?.audioStartedAt == nil { fail(.audioStartFailed, at: now) }
            case .recordingLimit:
                if state == .recording { stop(.recordingLimit, at: timer.deadline) }
            case .audioStop:
                if state == .finalizing && context?.audioClosed != true { fail(.audioStopFailed, at: now) }
            case .finalResult:
                if state == .finalizing { finishFinalizing(at: now, deadline: true) }
            case .model:
                if state == .processing { effects.append(.cancelModel(context!.id)); chooseLocal(.timeout, at: now) }
            case .insertion:
                if state == .inserting { fail(context?.writeCommitted == true ? .insertionUnknown : .deliveryFailed, at: now) }
            case .segment:
                if state == .recording { rotateRecognizer(at: now) }
            case .recovery: if !isActive { clearText() }
            }
        }
    }
    private mutating func begin(at now: Milliseconds) {
        nextSession += 1
        context = SessionContext(id: nextSession, preferences: preferences, keyDownAt: now, startedPID: environment.foregroundPID, metrics: SessionMetrics(sessionID: nextSession))
        mark("keyDown", now); context?.metrics.preferZDR = preferences.preferZDR
        if environment.safety.blocks { fail(.unsafeTarget, at: now); return }
        if !environment.microphonePermission || !environment.speechPermission || !environment.hotkeyPermission { fail(.permissionMissing, at: now); return }
        if !environment.deviceAvailable { fail(.deviceUnavailable, at: now); return }
        if !environment.recognitionAvailable { fail(.recognitionUnavailable, at: now); return }
        let policy: RecognitionPolicy
        if environment.supportsOnDevice { policy = .onDevice }
        else if preferences.privacyMode { fail(.onDeviceRequired, at: now); return }
        else if !preferences.appleServerConsent { fail(.serverConsentRequired, at: now); return }
        else if !environment.online { fail(.recognitionUnavailable, at: now); return }
        else { policy = .appleServerAllowed }
        state = .recording
        context?.policy = policy; context?.metrics.recognitionPolicy = policy
        let audio = token(); context?.audioToken = audio; effects.append(.startAudio(audio))
        let speech = token(); context?.recognizerToken = speech; context?.acceptedRecognizers.insert(speech)
        effects.append(.startRecognition(speech, policy))
        schedule(.hold, at: now + 250)
        schedule(.audioStart, at: now + 1_000)
    }
    private mutating func stop(_ reason: StopReason, at now: Milliseconds) {
        guard state == .recording else { return }
        state = .finalizing; context?.stoppedAt = now; context?.metrics.stopReason = reason; mark("stopIntent", now)
        removeTimer(.hold); removeTimer(.audioStart); removeTimer(.recordingLimit); removeTimer(.segment)
        let stopToken = token(); context?.stopToken = stopToken
        effects += [.stopAudio(stopToken), .endRecognition(context!.id)]
        schedule(.audioStop, at: now + 500)
        schedule(.finalResult, at: now + 500)
    }
    private mutating func deviceFailed(at now: Milliseconds) {
        if !snapshot().isEmpty { stop(.deviceFailed, at: now) } else { fail(.deviceUnavailable, at: now) }
    }
    private func snapshot() -> String {
        guard let c = context else { return "" }
        var tokens = Set(c.transcriptChunks.map { $0.token }).union(c.pendingPartials.keys)
        if let current = c.recognizerToken { tokens.insert(current) }
        let pieces = tokens.sorted { $0.operation < $1.operation }.flatMap { op -> [String] in
            if op == c.recognizerToken, !c.partial.isEmpty { return [c.partial] }
            if let pending = c.pendingPartials[op], !pending.isEmpty { return [pending] }
            return c.transcriptChunks.filter { $0.token == op }.sorted { ($0.audioEnd ?? .max) < ($1.audioEnd ?? .max) }.map { $0.text }
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private mutating func commitComplete(_ text: String, token op: OperationToken) {
        context?.transcriptChunks.removeAll { $0.token == op }
        context?.transcriptChunks.append(.init(token: op, text: text))
    }
    private mutating func rotateRecognizer(at now: Milliseconds) {
        guard let c = context, let previous = c.recognizerToken, let policy = c.policy else { return }
        if !c.partial.isEmpty { context?.pendingPartials[previous] = c.partial; context?.partial = "" }
        let next = token(); context?.recognizerToken = next; context?.acceptedRecognizers.insert(next)
        effects.append(.rotateRecognition(previous: previous, next: next, policy: policy))
        if policy == .appleServerAllowed { schedule(.segment, at: now + 45_000) }
    }
    private mutating func respond(_ op: OperationToken, _ response: ModuleResponse, at now: Milliseconds) {
        // Late audio ownership is always actively closed, even after reset/new session.
        if case .audioStarted = response {
            guard state == .recording, context?.audioToken == op, context?.audioStartedAt == nil else {
                if context?.audioToken != op || state != .recording { effects.append(.closeLateAudio(op)) }
                return
            }
            context?.audioStartedAt = now; mark("audioStarted", now)
            removeTimer(.audioStart)
            schedule(.recordingLimit, at: now + 300_000)
            if context?.policy == .appleServerAllowed { schedule(.segment, at: now + 45_000) }
            return
        }
        guard context?.id == op.session, isActive else { return }
        switch response {
        case .audioStarted: break
        case .audioStartFailed:
            if state == .recording, context?.audioToken == op, context?.audioStartedAt == nil { fail(.audioStartFailed, at: now) }
        case .audioStopped:
            if state == .finalizing, context?.stopToken == op {
                context?.audioClosed = true; mark("audioClosed", now); removeTimer(.audioStop)
                finishFinalizing(at: now, deadline: false)
            }
        case .audioStopFailed:
            if state == .finalizing, context?.stopToken == op { fail(.audioStopFailed, at: now) }
        case .audioEnded:
            if state == .recording, context?.audioToken == op {
                if snapshot().isEmpty { fail(.noSpeech, at: now) } else { stop(.deviceEnded, at: now) }
            }
        case .voiceDetected:
            if [.recording, .finalizing].contains(state), context?.audioToken == op { context?.hasVoice = true; mark("firstVoice", now, once: true) }
        case .partial(let text):
            guard [.recording, .finalizing].contains(state), context?.recognizerToken == op, context?.acceptedRecognizers.contains(op) == true else { return }
            context?.partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { mark("firstCaption", now, once: true) }
        case .final(let text):
            guard [.recording, .finalizing].contains(state), context?.acceptedRecognizers.contains(op) == true else { return }
            context?.acceptedRecognizers.remove(op)
            let nonempty = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if nonempty { mark("firstCaption", now, once: true); context?.pendingPartials.removeValue(forKey: op) }
            if state == .recording {
                if nonempty { commitComplete(text, token: op) }
                if context?.recognizerToken == op, nonempty { context?.partial = "" }
                if context?.recognizerToken == op { rotateRecognizer(at: now) }
            } else if context?.recognizerToken == op {
                let usedPartial = !nonempty && context?.partial.isEmpty == false
                context?.finalUsedPartial = usedPartial
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { context?.partial = text }
                let completed = snapshot()
                context?.final = completed; finishFinalizing(at: now, deadline: false)
            } else if nonempty {
                commitComplete(text, token: op)
                finishFinalizing(at: now, deadline: false)
            } else if state == .finalizing {
                finishFinalizing(at: now, deadline: false)
            }
        case .segmentFinal(let text, let end):
            guard [.recording, .finalizing].contains(state), context?.acceptedRecognizers.contains(op) == true, end >= 0, context?.seenAudioEnds.contains(end) == false else { return }
            let watermark = max(end, context!.committedAudioEnd)
            context?.committedAudioEnd = watermark; context?.seenAudioEnds.insert(end)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mark("firstCaption", now, once: true); context?.pendingPartials.removeValue(forKey: op)
                context?.transcriptChunks.append(.init(token: op, audioEnd: end, text: text))
                if context?.recognizerToken == op { context?.partial = "" }
            }
        case .recognitionFailed:
            guard [.recording, .finalizing].contains(state), context?.acceptedRecognizers.contains(op) == true else { return }
            context?.acceptedRecognizers.remove(op)
            if context?.recognizerToken != op {
                if state == .finalizing { finishFinalizing(at: now, deadline: false) }
                return
            }
            if snapshot().isEmpty { fail(.recognitionFailed, at: now) }
            else if state == .recording {
                stop(.recognitionFailed, at: now)
                let saved = snapshot(); context?.final = saved; context?.finalUsedPartial = true
            }
            else { let saved = snapshot(); context?.final = saved; context?.finalUsedPartial = true; finishFinalizing(at: now, deadline: false) }
        case .localProcessed(let text):
            guard state == .processing, context?.activeOperation == op, context?.metrics.timestamps["modelRequested"] == nil else { return }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty && !context!.frozenText.isEmpty { localFinished(context!.frozenText, at: now) }
            else { localFinished(cleaned, at: now) }
        case .localFailed:
            if state == .processing, context?.activeOperation == op, context?.metrics.timestamps["modelRequested"] == nil { localFinished(context!.frozenText, at: now) }
        case .modelResult(let text, let complete):
            guard state == .processing, context?.activeOperation == op, context?.metrics.timestamps["modelRequested"] != nil else { return }
            if TextProcessor.isValidModelOutput(text, original: context!.localText, preferences: context!.preferences.cleanup, complete: complete) {
                context?.deliveryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                context?.metrics.modelPath = .polished; mark("modelReturned", now); removeTimer(.model); beginInsertion(at: now)
            } else { chooseLocal(.invalidOutput, at: now) }
        case .modelFailed:
            if state == .processing, context?.activeOperation == op, context?.metrics.timestamps["modelRequested"] != nil { chooseLocal(.requestFailed, at: now) }
        case .insertionPrepared(let available):
            guard state == .inserting, context?.activeOperation == op, context?.prepared == false, context?.writeCommitted == false else { return }
            if environment.safety.blocks { fail(.unsafeTarget, at: now); return }
            if context?.appChanged == true && context?.strategy != .copy { prepare(.copy, at: now); return }
            if available {
                context?.prepared = true
                effects.append(.writeInsertion(op, context!.strategy, context!.deliveryText))
            } else { nextInsertion(at: now) }
        case .insertionResult(let result):
            guard state == .inserting, context?.activeOperation == op, context?.writeCommitted == true else { return }
            switch result {
            case .verifiedSuccess:
                let strategy = context!.strategy
                context?.metrics.deliveryPath = strategy == .ax ? .insertedAX : strategy == .paste ? .insertedPaste : .copiedOnly
                mark("delivered", now); terminal(.done, at: now)
            case .definiteFailure:
                // Module attests no mutation took place. A confirmed failed attempt may advance.
                if context?.metrics.cancelTooLate == true { fail(.insertionUnknown, at: now) }
                else { context?.writeCommitted = false; context?.prepared = false; nextInsertion(at: now) }
            case .unknown: fail(.insertionUnknown, at: now)
            }
        }
    }
    private mutating func finishFinalizing(at now: Milliseconds, deadline: Bool) {
        guard state == .finalizing, context?.audioClosed == true else { return }
        guard deadline || context?.final != nil else { return }
        if !deadline && !context!.acceptedRecognizers.isEmpty { return }
        let chosen = snapshot()
        let duration = context!.stoppedAt! - (context!.audioStartedAt ?? context!.keyDownAt)
        if duration < 300 && !context!.hasVoice && chosen.isEmpty { cancel(.accidentalNoSpeech, at: now); return }
        if chosen.isEmpty { fail(.noSpeech, at: now); return }
        let source = deadline || context!.finalUsedPartial || !context!.pendingPartials.isEmpty ? "partial" : "final"
        context?.metrics.recognitionSource = source
        context?.frozenText = chosen; mark("recognitionFrozen", now)
        removeTimer(.finalResult); effects.append(.cancelRecognition(context!.id))
        state = .processing
        let local = token(); context?.activeOperation = local
        effects.append(.cleanText(local, chosen, context!.preferences.cleanup))
    }
    private mutating func localFinished(_ text: String, at now: Milliseconds) {
        guard !text.isEmpty else { fail(.processingFailed, at: now); return }
        context?.localText = text; mark("localFinished", now)
        let c = context!
        let path: ModelPath?
        if c.preferences.privacyMode { path = .skippedPrivacyMode }
        else if !c.preferences.polishEnabled { path = .off }
        else if !environment.hasModelKey { path = .skippedNoKey }
        else if !environment.online { path = .skippedOffline }
        else if text.unicodeScalars.count > 600 { path = .skippedLongText }
        else if now >= (c.stoppedAt ?? now) + 1_180 { path = .skippedDeadline }
        else { path = nil }
        if let path = path { chooseLocal(path, at: now); return }
        let model = token(); context?.activeOperation = model; mark("modelRequested", now)
        let deadline = min(now + 650, c.stoppedAt! + 1_180)
        schedule(.model, at: deadline)
        effects.append(.polishText(model, text, c.preferences.cleanup, preferZDR: c.preferences.preferZDR))
    }
    private mutating func chooseLocal(_ path: ModelPath, at now: Milliseconds) {
        guard state == .processing else { return }
        let localText = context!.localText
        context?.metrics.modelPath = path; context?.deliveryText = localText
        if context?.metrics.timestamps["modelRequested"] != nil { mark("modelResolved", now) }
        removeTimer(.model); beginInsertion(at: now)
    }
    private mutating func beginInsertion(at now: Milliseconds) {
        state = .inserting
        if environment.foregroundPID != context?.startedPID { context?.appChanged = true; context?.metrics.appChanged = true }
        if environment.safety.blocks { fail(.unsafeTarget, at: now); return }
        prepare(context!.appChanged ? .copy : .ax, at: now)
    }
    private mutating func prepare(_ strategy: InsertionStrategy, at now: Milliseconds) {
        guard state == .inserting else { return }
        context?.strategy = strategy; context?.prepared = false; context?.writeCommitted = false
        let op = token(); context?.activeOperation = op
        mark("insertionStarted", now, once: true)
        if context?.deadlines[.insertion] == nil { schedule(.insertion, at: context!.metrics.timestamps["insertionStarted"]! + 180) }
        effects.append(.prepareInsertion(op, strategy, context!.deliveryText))
    }
    private mutating func nextInsertion(at now: Milliseconds) {
        switch context!.strategy {
        case .ax: prepare(context!.preferences.allowPaste ? .paste : .copy, at: now)
        case .paste: prepare(.copy, at: now)
        case .copy: fail(.deliveryFailed, at: now)
        }
    }
    private mutating func cancel(_ reason: CancellationReason, at now: Milliseconds) {
        guard isActive else { return }
        if state == .inserting && context?.writeCommitted == true {
            context?.metrics.cancelTooLate = true
            // Wait for this one result or its deadline; do not issue Undo or another write.
            return
        }
        context?.metrics.cancellation = reason; terminal(.cancelled, at: now)
    }
    private mutating func fail(_ reason: FailureReason, at now: Milliseconds) {
        context?.metrics.failure = reason; terminal(.error, at: now)
    }
    private mutating func terminal(_ terminalState: SessionState, at now: Milliseconds) {
        guard let c = context, ![.done, .error, .cancelled].contains(state) else { return }
        state = terminalState
        context?.metrics.terminalState = terminalState; mark("terminal", now)
        context?.recoveryText = terminalState == .cancelled || c.metrics.failure == .unsafeTarget ? "" : (c.deliveryText.isEmpty ? c.frozenText : c.deliveryText)
        context?.partial = ""; context?.final = nil; context?.transcriptChunks = []; context?.seenAudioEnds = []; context?.pendingPartials = [:]; context?.frozenText = ""; context?.localText = ""; context?.deliveryText = ""
        context?.activeOperation = nil; context?.acceptedRecognizers = []; context?.deadlines = [:]
        effects += [.cancelTimers(c.id), .cancelRecognition(c.id), .cancelModel(c.id), .cleanup(c.id), .recordMetrics(context!.metrics)]
        if !context!.recoveryText.isEmpty { schedule(.recovery, at: now + 60_000) }
    }
    private mutating func clearText() {
        context?.partial = ""; context?.final = nil; context?.transcriptChunks = []; context?.seenAudioEnds = []; context?.pendingPartials = [:]; context?.frozenText = ""; context?.localText = ""; context?.deliveryText = ""; context?.recoveryText = ""
    }
    private mutating func resetIfReady() {
        if !isActive, state != .idle, context?.cleanupComplete == true, context?.resetRequested == true, !rightOptionIsDown {
            clearText(); context = nil; state = .idle
        }
    }
}
