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
    @Published var hotkeyStatus = "快捷键监听：尚未启动"
    @Published var rightOptionPressCount = 0
    @Published var lastFailure: String?
    private var lastDiagnostics: Data?
    @Published var requestingPermission: String?
    @Published var readinessIssue: String?
    @Published var cleanup = CleanupSelection()
    lazy var onboarding = OnboardingModel(app: self)
    private var onboardingWindow: OnboardingWindowController?

    let localeOptions: [String]
    private(set) var session: LiveSession?
    private var pollTimer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        let supported = SpeechTranscriber.supportedLocaleIdentifiers
        let resolved = RecognitionLocaleResolver.resolve(override: defaults.string(forKey: "recognitionLocale"),
                                                         preferred: Locale.preferredLanguages, supported: supported)
        if let data = defaults.data(forKey: "cleanupSelection"),
           let saved = try? JSONDecoder().decode(CleanupSelection.self, from: data) { cleanup = saved }
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
        value.cleanup = cleanup.preferences
        return value
    }

    func start() {
        let live = LiveSession(preferences: preferences, localeIdentifier: localeIdentifier)
        live.onStateChange = { [weak self] state in
            guard let self = self else { return }
            if self.sessionState != state { self.sessionState = state }
            if state == .error { self.lastFailure = self.session?.coordinator.machine.hudMessage }
            self.updateHotkeyStatus()
            if state == .idle { self.applyPendingLocale() }
        }
        session = live
        live.interceptHotkey = { [weak self] in self?.onboarding.intercept($0) ?? false }
        live.onMachineChange = { [weak self] in self?.onboarding.observe($0) }
        refresh()
        if !defaults.bool(forKey: "onboardingCompleted.v1") {
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
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
        if let session = session {
            HotkeyConnectionPolicy.refresh(trusted: trusted, installed: session.hotkeys.installedWhileTrusted,
                                           automatically: session.hotkeys.reconnectAutomatically,
                                           install: session.hotkeys.install, uninstall: session.hotkeys.uninstall)
        }
        updateHotkeyStatus()
        onDeviceSupported = session?.transcriber.recognizer?.supportsOnDeviceRecognition ?? true
        updateReadiness()
    }

    func restartHotkeys() {
        guard sessionState == .idle else { return }
        if let session = session {
            HotkeyConnectionPolicy.restart(isIdle: session.state == .idle, install: session.hotkeys.install)
        }
        refresh()
    }

    private func updateHotkeyStatus() {
        rightOptionPressCount = session?.hotkeys.rightOptionPressCount ?? 0
        if !AXIsProcessTrusted() { hotkeyStatus = "快捷键监听：请授权辅助功能" }
        else if SafetyProbe.secureEventInputEnabled { hotkeyStatus = "快捷键暂停：请先离开密码框或安全输入" }
        else if session?.hotkeys.reconnectAutomatically == false { hotkeyStatus = "快捷键已停用，请重新连接" }
        else if session?.hotkeys.installedWhileTrusted == true { hotkeyStatus = "快捷键监听：已启动" }
        else { hotkeyStatus = "快捷键监听失败，请重新连接" }
        // Diagnostics contain only readiness/counters, never ordinary keys or dictated text.
        let values: [String: Any] = ["bundlePath": Bundle.main.bundlePath,
                                    "hotkeyStatus": hotkeyStatus, "rightOptionPressCount": rightOptionPressCount,
                                    "microphone": microphone.rawValue, "speech": speech.rawValue,
                                    "accessibility": accessibility.rawValue, "state": sessionState.rawValue,
                                    "lastFailure": lastFailure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), data != lastDiagnostics {
            let directory = MetricsLog.defaultDirectory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("diagnostics.json"), options: .atomic)
                lastDiagnostics = data
            } catch { /* Diagnostics must never interrupt dictation. */ }
        }
    }

    private static func state(_ granted: Bool, denied: Bool) -> PermissionState { granted ? .granted : (denied ? .denied : .pending) }

    var isBusy: Bool { sessionState != .idle }
    var permissionsGranted: Bool { microphone == .granted && speech == .granted && accessibility == .granted }

    func requestPermission(_ kind: String) {
        guard !isBusy, requestingPermission == nil else { return }
        switch kind {
        case "microphone":
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { openSettings("Privacy_Microphone"); return }
            requestingPermission = kind
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.requestingPermission = nil; self?.refresh() }
            }
        case "speech":
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { openSettings("Privacy_SpeechRecognition"); return }
            requestingPermission = kind
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async { self?.requestingPermission = nil; self?.refresh() }
            }
        default:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openSettings("Privacy_Accessibility")
        }
    }

    private func updateReadiness() {
        if !permissionsGranted { readinessIssue = "请先完成麦克风、语音识别和辅助功能授权" }
        else if SafetyProbe.secureEventInputEnabled { readinessIssue = "请先离开密码框，或关闭其他应用的安全键盘输入" }
        else if session?.hotkeys.installedWhileTrusted != true { readinessIssue = "快捷键尚未连接，请点击重新连接" }
        else if !onDeviceSupported && (privacyMode || !serverConsent) { readinessIssue = "此语言无法端侧识别，请更换语言或明确允许 Apple 服务器识别" }
        else if AVCaptureDevice.default(for: .audio) == nil { readinessIssue = "没有可用麦克风，请连接输入设备" }
        else if session?.transcriber.recognizer?.isAvailable != true { readinessIssue = "语音识别暂不可用，请检查语言与系统识别资源后重试" }
        else { readinessIssue = nil }
    }

    func showOnboarding() {
        guard !isBusy else { return }
        if onboardingWindow == nil { onboardingWindow = OnboardingWindowController(model: onboarding) }
        onboarding.open()
        onboardingWindow?.present()
    }

    func closeOnboarding(completed: Bool) {
        if completed {
            guard onboarding.progress.canComplete, readinessIssue == nil else { return }
            defaults.set(true, forKey: "onboardingCompleted.v1")
        }
        onboardingWindow?.close()
    }

    func setCleanup(fillers: Bool, enabled: Bool) {
        if fillers { cleanup.chooseIsolatedFillers(enabled ? .remove : .keep) }
        else { cleanup.chooseSentencePrefixes(enabled ? .remove : .keep) }
        if let data = try? JSONEncoder().encode(cleanup) { defaults.set(data, forKey: "cleanupSelection") }
        session?.send(.cleanupPreferencesChanged(cleanup.preferences))
    }

    func openSettings(_ anchor: String) {
        guard !isBusy else { return }
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
        updateReadiness()
    }

    /// Explicit, informed consent from a user action in the menu; revocation is immediate.
    func setServerConsent(_ enabled: Bool) {
        if enabled {
            guard !isBusy else { return }
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
        defaults.set(enabled ? 1 : nil, forKey: "appleServerConsentVersion")
        session?.send(.serverConsentChanged(enabled))
        updateReadiness()
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
