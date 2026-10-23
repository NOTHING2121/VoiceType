import AppKit
import AVFoundation
import Network
import Speech
import VoiceTypeCore

/// Snapshot of system facts for the reducer. Reading these never opens the microphone or prompts.
public final class SystemEnvironmentProbe {
    private let monitor = NWPathMonitor()
    private var online = true
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async { self?.online = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "VoiceType.network"))
    }
    deinit { monitor.cancel() }

    public func current(recognizer: SFSpeechRecognizer?) -> SessionEnvironment {
        var environment = SessionEnvironment()
        environment.microphonePermission = SystemAudioRecorder.permissionGranted
        environment.speechPermission = SpeechTranscriber.permissionGranted
        environment.hotkeyPermission = AXSupport.isTrusted
        environment.deviceAvailable = AVCaptureDevice.default(for: .audio) != nil
        environment.recognitionAvailable = recognizer?.isAvailable ?? false
        environment.supportsOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        environment.online = online
        environment.hasModelKey = false
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        environment.foregroundPID = pid ?? 0
        environment.safety = SafetyProbe.current(pid: pid)
        return environment
    }
}
