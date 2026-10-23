import AppKit
import SwiftUI
import VoiceTypeCore

@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(VoiceTypeAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("VoiceType")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    private var stateText: String {
        switch model.sessionState {
        case .idle: return "就绪：按住右 Option 说话，松开插入"
        case .recording: return "正在聆听…"
        case .finalizing, .processing, .inserting: return "正在处理…"
        case .done: return "已完成"
        case .error: return "上次会话出错"
        case .cancelled: return "已取消"
        }
    }

    var body: some View {
        Text(stateText)
        if [.recording, .finalizing, .processing, .inserting].contains(model.sessionState) {
            Button("取消当前听写") { model.session?.send(.escape) }
        }
        Divider()
        permissionRow("麦克风", model.microphone, anchor: "Privacy_Microphone")
        permissionRow("语音识别", model.speech, anchor: "Privacy_SpeechRecognition")
        permissionRow("辅助功能（快捷键与插入）", model.accessibility, anchor: "Privacy_Accessibility")
        Button("重新检查权限") { model.refresh() }
        Text(model.hotkeyStatus)
        Text("已收到右 Option：\(model.rightOptionPressCount) 次")
        if let failure = model.lastFailure { Text("最近提示：\(failure)") }
        Button("重新连接快捷键") { model.restartHotkeys() }
            .disabled(model.sessionState != .idle)
        Divider()
        Menu("识别语言：\(AppModel.displayName(model.localeIdentifier))") {
            ForEach(model.localeOptions, id: \.self) { identifier in
                Button((identifier == model.localeIdentifier ? "✓ " : "") + AppModel.displayName(identifier)) { model.setLocale(identifier) }
            }
        }
        Text(model.onDeviceSupported ? "当前语言：端侧识别" : "当前语言不支持端侧识别")
        Toggle("隐私模式（仅端侧识别）", isOn: Binding(get: { model.privacyMode }, set: { model.setPrivacyMode($0) }))
        if !model.onDeviceSupported || model.serverConsent {
            Toggle("允许 Apple 服务器识别…", isOn: Binding(get: { model.serverConsent }, set: { model.setServerConsent($0) }))
        }
        Divider()
        Button("打开延迟记录") { model.openMetrics() }
        Divider()
        Button("退出 VoiceType") { NSApplication.shared.terminate(nil) }
    }

    @ViewBuilder private func permissionRow(_ title: String, _ state: PermissionState, anchor: String) -> some View {
        if state == .granted {
            Text("\(title)：已授权")
        } else {
            Button("\(title)：\(state.rawValue)，打开系统设置…") { model.openSettings(anchor) }
        }
    }
}

final class VoiceTypeAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let output = HUDFocusSelfTest.outputPath(CommandLine.arguments) {
            HUDFocusSelfTest.run(output: output)
            return
        }
        model.start()
    }
}
