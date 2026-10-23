import AVFoundation
import Speech
import VoiceTypeCore

/// SFSpeechRecognizer streaming adapter. Buffers arrive on the audio thread; results are delivered on main.
public final class SpeechTranscriber: Transcribing {
    private struct Entry { let request: SFSpeechAudioBufferRecognitionRequest; let task: SFSpeechRecognitionTask }
    private let lock = NSLock()
    private var sink: SFSpeechAudioBufferRecognitionRequest?   // guarded by lock
    private var entries: [OperationToken: Entry] = [:]         // main queue only
    public private(set) var recognizer: SFSpeechRecognizer?
    public private(set) var localeIdentifier: String

    public init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    public static var permissionGranted: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    public static var supportedLocaleIdentifiers: [String] {
        SFSpeechRecognizer.supportedLocales().map { RecognitionLocaleResolver.normalize($0.identifier) }.sorted()
    }

    /// Only call between sessions; a running task keeps the recognizer it started with.
    public func setLocale(_ identifier: String) {
        guard identifier != localeIdentifier, entries.isEmpty else { return }
        localeIdentifier = identifier
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    /// Audio-thread entry point.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = sink; lock.unlock()
        request?.append(buffer)
    }

    public func start(_ token: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        begin(token, policy: policy, callback: callback)
    }

    public func rotate(previous: OperationToken, next: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        entries[previous]?.request.endAudio()
        begin(next, policy: policy, callback: callback)
    }

    public func end(session: UInt64) {
        setSink(nil)
        for (token, entry) in entries where token.session == session { entry.request.endAudio() }
    }

    public func cancel(session: UInt64) {
        for (token, entry) in entries where token.session == session {
            entries.removeValue(forKey: token)
            if currentSink === entry.request { setSink(nil) }
            entry.task.cancel()
        }
    }

    private var currentSink: SFSpeechAudioBufferRecognitionRequest? { lock.lock(); defer { lock.unlock() }; return sink }
    private func setSink(_ request: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); sink = request; lock.unlock() }

    private func begin(_ token: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback) {
        guard let recognizer = recognizer, recognizer.isAvailable, Self.permissionGranted else {
            DispatchQueue.main.async { callback(token, .recognitionFailed) }
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = policy == .onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error as NSError?
            DispatchQueue.main.async {
                guard let self = self, self.entries[token] != nil else { return }
                if let text = text {
                    if isFinal { self.finish(token); callback(token, .final(text)); return }
                    callback(token, .partial(text))
                }
                if let failure = failure {
                    self.finish(token)
                    callback(token, Self.isNoSpeech(failure) ? .final("") : .recognitionFailed)
                }
            }
        }
        entries[token] = Entry(request: request, task: task)
        setSink(request)
    }

    private func finish(_ token: OperationToken) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        if currentSink === entry.request { setSink(nil) }
    }

    /// "No speech detected" ends the task without text; the reducer then decides noSpeech vs. accidental tap.
    static func isNoSpeech(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain" && error.code == 1110
    }
}
