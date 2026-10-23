import Foundation

public typealias Milliseconds = Int64

public enum SessionState: String, Codable, CaseIterable { case idle, recording, finalizing, processing, inserting, done, error, cancelled }
public enum GestureMode: String, Codable { case pendingGesture, pushToTalk, handsFree }
public enum RecognitionPolicy: String, Codable { case onDevice, appleServerAllowed }
public enum InsertionStrategy: String, Codable { case ax, paste, copy }
public enum InsertionOutcome: Equatable { case verifiedSuccess, definiteFailure, unknown }
public enum CleanupChoice: String, Codable { case unset, keep, remove }
public struct CleanupPreferences: Codable, Equatable {
    public var isolatedFillers: CleanupChoice = .unset
    public var sentencePrefixes: CleanupChoice = .unset
    public init() {}
}
public struct SessionPreferences: Codable, Equatable {
    public var privacyMode = false
    public var appleServerConsent = false
    public var polishEnabled = false
    public var preferZDR = false
    public var allowPaste = true
    public var cleanup = CleanupPreferences()
    public init() {}
}
public struct SafetySignals: Equatable {
    /// nil means unavailable AX data, not a danger signal.
    public var secureTextField: Bool?
    public var secureEventInput: Bool
    public var blocks: Bool { secureTextField == true || secureEventInput }
    public init(secureTextField: Bool? = nil, secureEventInput: Bool = false) {
        self.secureTextField = secureTextField; self.secureEventInput = secureEventInput
    }
}
public struct SessionEnvironment: Equatable {
    public var microphonePermission = true
    public var speechPermission = true
    public var hotkeyPermission = true
    public var deviceAvailable = true
    public var recognitionAvailable = true
    public var supportsOnDevice = true
    public var online = true
    /// Capability metadata only: the core never receives an actual API key.
    public var hasModelKey = false
    public var foregroundPID: Int32 = 100
    public var safety = SafetySignals()
    public init() {}
}
public struct OperationToken: Hashable, Codable {
    public let session: UInt64
    public let operation: UInt64
    public init(session: UInt64, operation: UInt64) { self.session = session; self.operation = operation }
}
/// Hard watchdogs. 180ms remains the design target; live adapters may need a wider
/// verification watchdog so slow-but-real AX/paste confirmation is not mislabeled.
public struct SessionTiming: Equatable {
    public var insertionWatchdog: Milliseconds
    public init(insertionWatchdog: Milliseconds = 180) { self.insertionWatchdog = insertionWatchdog }
}
public enum TimerKind: String, Codable { case hold, audioStart, recordingLimit, finalResult, audioStop, model, insertion, segment, recovery }
public struct SessionTimer: Hashable {
    public let token: OperationToken
    public let kind: TimerKind
    public let deadline: Milliseconds
    public init(token: OperationToken, kind: TimerKind, deadline: Milliseconds) {
        self.token = token; self.kind = kind; self.deadline = deadline
    }
}
public enum StopReason: String, Codable { case released, handsFreeTap, recordingLimit, deviceEnded, recognitionFailed, deviceFailed }
public enum CancellationReason: String, Codable { case escape, hud, accidentalNoSpeech, combination, sleeping, locked, quitting, listenerLost, serverConsentRevoked, privacyEnabled }
public enum FailureReason: String, Codable { case permissionMissing, deviceUnavailable, recognitionUnavailable, onDeviceRequired, serverConsentRequired, noSpeech, recognitionFailed, audioStartFailed, audioStopFailed, unsafeTarget, processingFailed, deliveryFailed, insertionUnknown }
public enum ModelPath: String, Codable { case off, polished, skippedPrivacyMode, skippedNoKey, skippedOffline, skippedLongText, skippedDeadline, timeout, invalidOutput, requestFailed }
public enum DeliveryPath: String, Codable { case insertedAX, insertedPaste, copiedOnly }
public enum InterruptReason { case sleeping, locked, quitting, listenerLost, permissionRevoked, deviceDisconnected }

public struct SessionMetrics: Codable, Equatable {
    public var sessionID: UInt64
    public var timestamps: [String: Milliseconds] = [:]
    public var recognitionPolicy: RecognitionPolicy?
    public var recognitionSource: String?
    public var modelPath: ModelPath = .off
    public var deliveryPath: DeliveryPath?
    public var stopReason: StopReason?
    public var cancellation: CancellationReason?
    public var failure: FailureReason?
    public var appChanged = false
    public var preferZDR = false
    public var cancelTooLate = false
    public var terminalState: SessionState?
    public init(sessionID: UInt64) { self.sessionID = sessionID }
    public func elapsed(_ start: String, _ end: String) -> Milliseconds? {
        guard let a = timestamps[start], let b = timestamps[end] else { return nil }
        return b - a
    }
    public var firstCaptionLatency: Milliseconds? { elapsed("firstVoice", "firstCaption") }
    public var stopToInsertion: Milliseconds? {
        guard deliveryPath == .insertedAX || deliveryPath == .insertedPaste else { return nil }
        return elapsed("stopIntent", "delivered")
    }
    public var stopToCopy: Milliseconds? { deliveryPath == .copiedOnly ? elapsed("stopIntent", "delivered") : nil }
}

public struct TranscriptChunk {
    public let token: OperationToken
    public let audioEnd: Milliseconds?
    public let text: String
    public init(token: OperationToken, audioEnd: Milliseconds? = nil, text: String) {
        self.token = token; self.audioEnd = audioEnd; self.text = text
    }
}
public struct SessionContext {
    public let id: UInt64
    public var preferences: SessionPreferences
    public var policy: RecognitionPolicy?
    public var mode: GestureMode = .pendingGesture
    public var keyDownAt: Milliseconds
    public var startedPID: Int32
    public var appChanged = false
    public var audioStartedAt: Milliseconds?
    public var audioClosed = false
    public var audioToken: OperationToken?
    public var stopToken: OperationToken?
    public var recognizerToken: OperationToken?
    public var acceptedRecognizers: Set<OperationToken> = []
    public var committedAudioEnd: Milliseconds = -1
    public var seenAudioEnds: Set<Milliseconds> = []
    public var transcriptChunks: [TranscriptChunk] = []
    public var committedSegments: [String] {
        transcriptChunks.sorted {
            $0.token.operation == $1.token.operation ? ($0.audioEnd ?? .max) < ($1.audioEnd ?? .max) : $0.token.operation < $1.token.operation
        }.map { $0.text }
    }
    public var pendingPartials: [OperationToken: String] = [:]
    public var partial = ""
    public var final: String?
    public var finalUsedPartial = false
    public var frozenText = ""
    public var localText = ""
    public var deliveryText = ""
    public var recoveryText = ""
    public var hasVoice = false
    public var stoppedAt: Milliseconds?
    public var activeOperation: OperationToken?
    public var strategy: InsertionStrategy = .ax
    public var prepared = false
    public var writeCommitted = false
    public var cleanupComplete = false
    public var resetRequested = false
    public var deadlines: [TimerKind: SessionTimer] = [:]
    public var metrics: SessionMetrics
}

public enum ModuleResponse {
    case audioStarted
    case audioStartFailed
    case audioStopped
    case audioStopFailed
    case audioEnded
    case voiceDetected
    /// Cumulative hypothesis for this recognizer task; replaces previous hypotheses.
    case partial(String)
    /// Complete result for this task; replaces its provisional/committed subfragments.
    case final(String)
    /// Canonical non-overlapping fragment. The adapter maps replay overlap to a stable global audioEnd identity.
    case segmentFinal(text: String, audioEnd: Milliseconds)
    case recognitionFailed
    case localProcessed(String)
    case localFailed
    case modelResult(text: String, complete: Bool)
    case modelFailed
    case insertionPrepared(available: Bool)
    case insertionResult(InsertionOutcome)
}
public enum SessionEvent {
    case rightOptionDown(eligible: Bool)
    case rightOptionUp
    case escape
    case cancelFromHUD
    case combinationKey
    case applicationChanged(Int32)
    case privacyChanged(Bool)
    case serverConsentChanged(Bool)
    case cleanupPreferencesChanged(CleanupPreferences)
    case environmentChanged(SessionEnvironment)
    case safetyChanged(SafetySignals)
    case interrupted(InterruptReason)
    case timer(SessionTimer)
    case response(OperationToken, ModuleResponse)
    case cleanupFinished(UInt64)
    case reset
    /// Sent atomically by the coordinator immediately before a module's write.
    case commitWrite(OperationToken)
}
public enum SessionEffect {
    case startAudio(OperationToken)
    case stopAudio(OperationToken)
    case closeLateAudio(OperationToken)
    case startRecognition(OperationToken, RecognitionPolicy)
    case rotateRecognition(previous: OperationToken, next: OperationToken, policy: RecognitionPolicy)
    case endRecognition(UInt64)
    case cancelRecognition(UInt64)
    case cleanText(OperationToken, String, CleanupPreferences)
    case polishText(OperationToken, String, CleanupPreferences, preferZDR: Bool)
    case cancelModel(UInt64)
    case prepareInsertion(OperationToken, InsertionStrategy, String)
    case writeInsertion(OperationToken, InsertionStrategy, String)
    case schedule(SessionTimer)
    case cancelTimers(UInt64)
    case cleanup(UInt64)
    case recordMetrics(SessionMetrics)
}
