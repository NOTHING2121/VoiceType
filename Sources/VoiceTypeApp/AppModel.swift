import AppKit
import AVFoundation
import Speech
import VoiceTypeCore
import VoiceTypeSystem

enum PermissionState: String { case granted = "已授权", denied = "未授权", pending = "待授权" }

final class AppModel: ObservableObject {
    @Published var microphone: PermissionState = .pending
    @Published var speech: PermissionState = .pending
    @Published var accessibility: PermissionState = .pending
    @Published var sessionState: SessionState = .idle
    @Published var localeIdentifier: String
    @Published var privacyMode: Bool
    @Published var serverConsent: Bool
    @Published var onDeviceSupported = true

    let localeOptions: [String]
    private(set) var session: LiveSession?
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        let supported = SpeechTranscriber.supportedLocaleIdentifiers
        let resolved = RecognitionLocaleResolver.resolve(override: defaults.string(forKey: "recognitionLocale"),
                                                         preferred: Locale.preferredLanguages, supported: supported)
        localeIdentifier = resolved
        privacyMode = defaults.bool(forKey: "privacyMode")
        serverConsent = defaults.bool(forKey: "appleServerConsent")
        let preferredOptions = Locale.preferredLanguages.map {
            RecognitionLocaleResolver.resolve(override: nil, preferred: [$0], supported: supported)
        }
        var seen = Set<String>()
        localeOptions = ([resolved] + preferredOptions + ["zh-CN", "en-US"]).filter { supported.contains($0) && seen.insert($0).inserted }
    }

    var preferences: SessionPreferences {
        var value = SessionPreferences()
        value.privacyMode = privacyMode
        value.appleServerConsent = serverConsent
        value.polishEnabled = false
        value.allowPaste = true
        return value
    }

    func start() {
        let live = LiveSession(preferences: preferences, localeIdentifier: localeIdentifier)
        live.onStateChange = { [weak self] state in
            guard let self = self else { return }
            if self.sessionState != state { self.sessionState = state }
            if state == .idle { self.applyPendingLocale() }
        }
        session = live
        refresh()
        if AXIsProcessTrusted() { live.hotkeys.install() }
        requestMicrophone()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func refresh() {
        microphone = Self.state(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                denied: [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)))
        speech = Self.state(SFSpeechRecognizer.authorizationStatus() == .authorized,
                            denied: [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()))
        let trusted = AXIsProcessTrusted()
        accessibility = trusted ? .granted : .denied
        if let session = session, trusted, !session.hotkeys.installedWhileTrusted { session.hotkeys.install() }
        onDeviceSupported = session?.transcriber.recognizer?.supportsOnDeviceRecognition ?? true
    }

    private static func state(_ granted: Bool, denied: Bool) -> PermissionState { granted ? .granted : (denied ? .denied : .pending) }

    // Sequential system prompts at launch only — never during a dictation session.
    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { requestSpeech(); return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refresh(); self.requestSpeech() } }
    }

    private func requestSpeech() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { requestAccessibility(); return }
        SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.refresh(); self.requestAccessibility() } }
    }

    private func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    func setLocale(_ identifier: String) {
        localeIdentifier = identifier
        defaults.set(identifier, forKey: "recognitionLocale")
        applyPendingLocale()
    }

    private func applyPendingLocale() {
        guard let session = session, session.state == .idle, session.transcriber.localeIdentifier != localeIdentifier else { return }
        session.transcriber.setLocale(localeIdentifier)
        refresh()
    }

    func setPrivacyMode(_ enabled: Bool) {
        privacyMode = enabled
        defaults.set(enabled, forKey: "privacyMode")
        session?.send(.privacyChanged(enabled))
    }

    /// Explicit, informed consent from a user action in the menu; revocation is immediate.
    func setServerConsent(_ enabled: Bool) {
        if enabled {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "允许使用 Apple 服务器识别？"
            alert.informativeText = "当前识别语言无法在本机端侧识别。开启后，你说话的音频会经 Apple 语音识别服务发送到 Apple 服务器处理，需要联网，数据处理遵循 Apple 的政策；VoiceType 不承诺零保留。你可随时在菜单中关闭；开启隐私模式时始终只用端侧识别。"
            alert.addButton(withTitle: "允许")
            alert.addButton(withTitle: "暂不允许")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        serverConsent = enabled
        defaults.set(enabled, forKey: "appleServerConsent")
        defaults.set(enabled ? ISO8601DateFormatter().string(from: Date()) : nil, forKey: "appleServerConsentAt")
        session?.send(.serverConsentChanged(enabled))
    }

    func openMetrics() {
        let url = MetricsLog.defaultDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    static func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
