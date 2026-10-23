import AVFoundation
import VoiceTypeCore

public enum AudioFormatting {
    /// Speech and voice detection consume 16 kHz mono Float32.
    public static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    public static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { let sample = channels[0][index]; sum += sample * sample }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}

/// Reports sustained energy once per session; recognition text also counts as voice in the reducer.
public final class VoiceActivityDetector {
    public let thresholdDB: Float
    public let requiredBuffers: Int
    private var consecutive = 0
    public private(set) var detected = false
    public init(thresholdDB: Float = -45, requiredBuffers: Int = 2) {
        self.thresholdDB = thresholdDB; self.requiredBuffers = requiredBuffers
    }
    public func process(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard !detected else { return false }
        consecutive = AudioFormatting.rmsDecibels(buffer) > thresholdDB ? consecutive + 1 : 0
        if consecutive >= requiredBuffers { detected = true; return true }
        return false
    }
}

/// Microphone is opened only by `start` and closed by stop/cleanup/closeLate; idle never taps input.
public final class SystemAudioRecorder: AudioRecording {
    /// Called on the audio thread with 16 kHz mono buffers. Set once before the first session.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var engine: AVAudioEngine?
    private var activeToken: OperationToken?
    private var configurationObserver: NSObjectProtocol?
    public init() {}

    public static var permissionGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public var isCapturing: Bool { engine != nil }

    private func reply(_ token: OperationToken, _ response: ModuleResponse, _ callback: @escaping ModuleCallback) {
        DispatchQueue.main.async { callback(token, response) }
    }

    public func start(_ token: OperationToken, callback: @escaping ModuleCallback) {
        teardown()
        guard Self.permissionGranted else { reply(token, .audioStartFailed, callback); return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: AudioFormatting.speechFormat) else {
            reply(token, .audioStartFailed, callback); return
        }
        let detector = VoiceActivityDetector()
        let sink = onBuffer
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let converted = AudioFormatting.convert(buffer, using: converter) else { return }
            sink?(converted)
            if detector.process(converted) { DispatchQueue.main.async { callback(token, .voiceDetected) } }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            reply(token, .audioStartFailed, callback); return
        }
        self.engine = engine
        activeToken = token
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self = self, self.activeToken == token else { return }
            self.teardown()
            callback(token, .audioEnded)
        }
        reply(token, .audioStarted, callback)
    }

    public func stop(_ token: OperationToken, callback: @escaping ModuleCallback) {
        teardown()
        reply(token, .audioStopped, callback)
    }

    public func closeLate(_ token: OperationToken) {
        if activeToken == token { teardown() }
    }

    public func cleanup(session: UInt64, completion: @escaping () -> Void) {
        if activeToken == nil || activeToken?.session == session { teardown() }
        DispatchQueue.main.async(execute: completion)
    }

    private func teardown() {
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        activeToken = nil
    }
}
