import AppKit
import SwiftUI
import VoiceTypeCore

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, shortcut, trial, preferences, finish
    var title: String { ["欢迎", "授权与语言", "验证快捷键", "试着说一句", "文字偏好", "准备好了"][rawValue] }
}

final class OnboardingModel: ObservableObject {
    unowned let app: AppModel
    @Published var step: OnboardingStep = .welcome
    @Published var progress = OnboardingProgress()
    @Published var trialText = ""
    @Published var message = "点击练习框，按住右 Option 说一句话，松开后等待文字出现。"
    @Published var caption = ""
    @Published var shortcutHeld = false
    private(set) var visible = false
    weak var editor: NSTextView?
    private var trialID: UInt64?
    private var baseline = ""
    private var selection = NSRange(location: 0, length: 0)

    init(app: AppModel) { self.app = app }
    var focused: Bool {
        guard let editor = editor, editor.window?.isKeyWindow == true else { return false }
        return editor.window?.firstResponder === editor && NSApp.isActive
    }
    func open() { visible = true; app.refresh() }
    func close() {
        visible = false
        if app.session?.coordinator.machine.isActive == true { app.session?.send(.escape) }
        // Practice text lives only in this window's memory.
        trialText = ""; caption = ""; trialID = nil
        progress = OnboardingProgress(); shortcutHeld = false; step = .welcome
    }
    func go(_ next: OnboardingStep) {
        guard !app.isBusy else { return }
        if next.rawValue >= OnboardingStep.shortcut.rawValue && !app.permissionsGranted { step = .permissions; return }
        if next.rawValue >= OnboardingStep.trial.rawValue && !progress.shortcutVerified { step = .shortcut; return }
        if next.rawValue >= OnboardingStep.preferences.rawValue && !progress.trialSucceeded { return }
        step = next
        if next == .trial { DispatchQueue.main.async { [weak self] in self?.focusEditor() } }
    }
    func focusEditor() {
        guard !app.isBusy, let editor = editor else { return }
        editor.window?.makeFirstResponder(editor)
    }
    func retry() {
        guard !app.isBusy else { return }
        progress.beginTrial(session: 0, focused: false)
        trialID = nil; trialText = ""; caption = ""
        message = "按住右 Option 说话，松开后等待文字出现。也可以单击开始免提，再单击结束。"
        focusEditor()
    }
    func intercept(_ event: SessionEvent) -> Bool {
        guard visible else { return false }
        // Let an already-started session receive release/cancellation, even after focus changes.
        if app.session?.state != .idle { return false }
        switch event {
        case .rightOptionDown(let eligible):
            if step == .shortcut {
                let accepted = eligible && NSApp.isActive && app.readinessIssue == nil
                progress.shortcutDown(eligible: accepted); shortcutHeld = accepted
                return true // This exercise never starts the recorder.
            }
            if step == .trial && eligible && focused && app.readinessIssue == nil { return false }
            if step == .trial { message = app.readinessIssue ?? "请先点击练习框，再独立按右 Option。" }
            return true
        case .rightOptionUp:
            if step == .shortcut {
                if NSApp.isActive { progress.shortcutUp() } else { progress.cancelShortcut() }
                shortcutHeld = false
                return true
            }
            return step != .trial
        case .combinationKey:
            if step == .shortcut { progress.cancelShortcut(); shortcutHeld = false }
            return step != .trial
        default: return false
        }
    }
    func observe(_ machine: SessionStateMachine) {
        guard visible, step == .trial, let context = machine.context else { return }
        if machine.state == .recording, trialID != context.id {
            trialID = context.id
            baseline = editor?.string ?? trialText
            selection = editor?.selectedRange() ?? NSRange(location: 0, length: 0)
            progress.beginTrial(session: context.id, focused: focused)
        }
        caption = machine.liveCaption
        if machine.state != .idle { message = machine.hudMessage ?? "已取消；可以重新试一次。" }
        if [.done, .error, .cancelled].contains(machine.state) {
            // The reducer clears deliveryText when entering a terminal state. Its bounded
            // recoveryText is the authoritative delivered result until the next reset.
            let actual = editor?.string ?? trialText
            let matches = OnboardingProgress.matchesInsertion(before: baseline, location: selection.location,
                length: selection.length, after: actual, deliveredText: context.recoveryText)
            progress.finishTrial(session: context.id, state: machine.state, delivery: context.metrics.deliveryPath,
                                 contentChanged: matches,
                                 appChanged: context.appChanged)
            if progress.trialSucceeded { message = "文字已经成功输入！请核对内容，再点击下方按钮继续。" }
            else if machine.state == .done { message = "本次未确认文字进入练习框。请保持这个窗口和输入框的焦点，再试一次。" }
        }
    }
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    let model: OnboardingModel
    init(model: OnboardingModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceType · 使用引导"
        window.minSize = NSSize(width: 800, height: 660)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, app: model.app))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func windowWillClose(_ notification: Notification) { model.close() }
}

/// A real, accessible text input. Dictation uses the same inserter as normal use; no fake result.
struct PracticeEditor: NSViewRepresentable {
    @ObservedObject var model: OnboardingModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: .zero)
        text.isRichText = false
        text.font = .systemFont(ofSize: 18)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("听写练习输入框")
        text.setAccessibilityIdentifier("voicetype.onboarding.practice")
        text.delegate = context.coordinator
        scroll.documentView = text
        model.editor = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != model.trialText { text.string = model.trialText }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: OnboardingModel
        init(_ model: OnboardingModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if let text = notification.object as? NSTextView { model.trialText = text.string }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var app: AppModel
    private let accent = Color(red: 0.05, green: 0.48, blue: 0.43)

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                Label("VoiceType", systemImage: "waveform").font(.title2.bold()).foregroundColor(accent)
                Text("把想说的，变成文字。").font(.caption).foregroundColor(.secondary)
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    HStack(spacing: 10) {
                        Text(step.rawValue < model.step.rawValue ? "✓" : "\(step.rawValue + 1)")
                            .font(.caption.bold()).frame(width: 25, height: 25)
                            .background(Circle().fill(step == model.step ? accent : Color.secondary.opacity(0.12)))
                            .foregroundColor(step == model.step ? .white : .secondary)
                        Text(step.title).font(.system(size: 13, weight: step == model.step ? .semibold : .regular))
                    }
                }
                Spacer()
                Text("平时驻留右上角菜单栏\n点击波形图标，可随时回来。")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24).frame(width: 210, alignment: .leading)
            .frame(maxHeight: .infinity).background(accent.opacity(0.06))
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("第 \(model.step.rawValue + 1) 步 / 6").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("稍后设置") { app.closeOnboarding(completed: false) }.buttonStyle(.plain).foregroundColor(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                Divider()
                footer
            }.padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            heading("先说一句，再开始使用", "用几步完成授权、确认快捷键，并亲自试一次听写。")
            Image(systemName: "waveform.circle.fill").font(.system(size: 72)).foregroundColor(accent).padding(.vertical, 12)
            card("按住说，松开输入", "按住键盘右侧的 Option，说完后松开，文字会进入当前输入框。", icon: "keyboard")
            card("你决定何时开麦", "欢迎页、授权和快捷键练习都不开麦。只有进入听写并按下快捷键后才录音。", icon: "mic")
            card("优先在本机识别", "不保存录音或听写正文。若语言需要 Apple 服务器处理，会先单独征求你的同意。", icon: "lock.shield")
        case .permissions:
            heading("先把必要权限准备好", "每项权限分别授权。完成系统设置后回到这里，状态会自动更新。")
            permission("麦克风", detail: "只在听写时采集你的声音。", state: app.microphone, key: "microphone", icon: "mic")
            permission("语音识别", detail: "使用 Apple Speech 将声音转成文字。", state: app.speech, key: "speech", icon: "text.bubble")
            permission("辅助功能", detail: "监听右 Option、取消听写，并把文字插入输入框。", state: app.accessibility, key: "accessibility", icon: "hand.point.up.left")
            Text("辅助功能：在系统设置中打开 VoiceType 开关。若列表没有它，点「+」选择当前应用。")
                .font(.caption).foregroundColor(.secondary)
            languageControls
            HStack { Text(app.hotkeyStatus).font(.caption); Spacer(); Button("重新检查") { app.refresh() }; Button("重新连接") { app.restartHotkeys() } }
            if let issue = app.readinessIssue { notice(issue) }
        case .shortcut:
            heading("让键盘认识你的快捷键", "默认使用右 Option；左 Option 保持原来的用途。本版不支持更换按键。")
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Text("⌥").font(.system(size: 58, weight: .medium))
                    Text("右 Option").font(.headline)
                }.frame(width: 150, height: 130)
                    .background(RoundedRectangle(cornerRadius: 18).fill(accent.opacity(model.shortcutHeld ? 0.25 : 0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.3)))
                Spacer()
            }.padding(.vertical, 12)
            Text(model.progress.shortcutVerified ? "✓ 已检测到右 Option 的按下与松开" : (model.shortcutHeld ? "检测到了，请松开按键…" : "现在单独按下并松开右 Option。这一步不会录音。"))
                .font(.headline).foregroundColor(accent)
            card("按住说", "按住右 Option 说话，松开结束。适合短句。", icon: "hand.tap")
            card("单击免提", "快速单击开始，说完再单击结束。长句不用一直按着。Esc 可取消。", icon: "mic.badge.plus")
            Text("没反应？请确认是右侧按键、没有同时按其他键，并检查改键工具或外接键盘。")
                .font(.caption).foregroundColor(.secondary)
            if let issue = app.readinessIssue { notice(issue); Button("返回检查权限") { model.go(.permissions) } }
        case .trial:
            heading("现在，真的说一句", "先点击练习框，按住右 Option 说话，松开后等待结果。也可单击开始免提，再单击结束。")
            Text(app.localeIdentifier.hasPrefix("zh") ? "试着说：“今天的工作安排已经准备好了。”" : "Try saying: “My plan for today is ready.”")
                .font(.headline).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(accent.opacity(0.07)).cornerRadius(10)
            PracticeEditor(model: model).frame(height: 140)
            Text(model.message).font(.callout).foregroundColor(model.progress.trialSucceeded ? accent : .primary)
            if !model.caption.isEmpty { Text("实时字幕：\(model.caption)").font(.caption).foregroundColor(.secondary).lineLimit(3) }
            HStack {
                if app.isBusy { Button("取消本次听写") { app.session?.send(.escape) } }
                else { Button("清空并重试") { model.retry() }; Button("聚焦练习框") { model.focusEditor() } }
                Spacer()
                Text("Esc 取消").font(.caption).foregroundColor(.secondary)
            }
            if let issue = app.readinessIssue { notice(issue); Button("检查权限与语言") { model.go(.permissions) }.disabled(app.isBusy) }
            else if app.lastFailure != nil && !model.progress.trialSucceeded {
                notice("没有识别到语音时，请检查系统声音输入设备并更靠近麦克风；识别不可用时可返回更换语言。")
                Button("返回检查语言与权限") { model.go(.permissions) }.disabled(app.isBusy)
            }
            Text("练习结果只保留在本窗口，不写入历史。手动打字或仅复制到剪贴板不会算作试用成功。")
                .font(.caption).foregroundColor(.secondary)
        case .preferences:
            heading("按你的习惯整理文字", "基础格式清理始终可用。下面两项默认关闭；可能改变语气，请自行选择。")
            cleanupOption("删除孤立语气词", detail: "仅清理规则能确定的句首停顿词，例如：", before: "呃，明天开会。", after: "明天开会。", fillers: true)
            cleanupOption("清理句首口头语", detail: "仅清理后接逗号的特定句首口头语，例如：", before: "那个，明天开会。", after: "明天开会。", fillers: false)
            Text("“嗯。”这样的回答和“那个方案”等指代仍保留。可以在菜单「文字清理」中分别关闭；点击继续不会自动开启任何一项。")
                .font(.caption).foregroundColor(.secondary)
        case .finish:
            heading("你已经完成第一次听写", "权限已准备、快捷键已验证，文字已成功进入练习框。")
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundColor(accent).padding(.vertical, 12)
            card("下一次，在任何普通输入框试试", "打开备忘录或聊天输入框，点击放好光标，按住右 Option 说话，松开输入。不同应用的兼容性可能不同。", icon: "text.cursor")
            card("记住右上角的波形图标", "这里可以修改语言、查看权限、重新连接快捷键，或重新打开本引导。关闭引导后，VoiceType 继续在菜单栏运行。", icon: "waveform")
            Text("如果提示“已复制”，请手动 Command+V。跨应用插入的成功与否会单独显示，不会把复制当成插入。")
                .font(.caption).foregroundColor(.secondary)
            if let issue = app.readinessIssue { notice(issue); Button("返回检查") { model.go(.permissions) } }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("上一步") { model.go(OnboardingStep(rawValue: model.step.rawValue - 1)!) }.disabled(app.isBusy)
            }
            Spacer()
            switch model.step {
            case .welcome: primary("开始设置") { model.go(.permissions) }
            case .permissions: primary("权限已就绪，继续", enabled: app.readinessIssue == nil) { model.go(.shortcut) }
            case .shortcut: primary("开始听写练习", enabled: model.progress.shortcutVerified && !model.shortcutHeld && app.readinessIssue == nil) { model.go(.trial) }
            case .trial: primary("这就是我说的，继续", enabled: model.progress.trialSucceeded && !app.isBusy) { model.go(.preferences) }
            case .preferences: primary("保存选择，继续") { model.go(.finish) }
            case .finish: primary("完成，开始使用", enabled: model.progress.canComplete && app.readinessIssue == nil) { app.closeOnboarding(completed: true) }
            }
        }
    }
    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled || app.isBusy)
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 27, weight: .bold))
            Text(subtitle).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func card(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundColor(accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035)).cornerRadius(12)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
    }
    private func permission(_ title: String, detail: String, state: PermissionState, key: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : icon).foregroundColor(state == .granted ? accent : .secondary)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(detail).font(.caption).foregroundColor(.secondary) }
            Spacer()
            if state == .granted { Text("已授权").foregroundColor(accent).font(.caption) }
            else { Button(app.requestingPermission == key ? "等待授权…" : (state == .pending ? "授权" : "打开设置")) { app.requestPermission(key) }.disabled(app.requestingPermission != nil || app.isBusy) }
        }.padding(12).background(Color.primary.opacity(0.035)).cornerRadius(10)
    }
    private var languageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("识别语言", selection: Binding(get: { app.localeIdentifier }, set: { app.setLocale($0) })) {
                ForEach(app.localeOptions, id: \.self) { Text(AppModel.displayName($0)).tag($0) }
            }
            Text(app.onDeviceSupported ? "此语言支持端侧识别，音频在本机处理。" : "此语言不支持端侧识别。可更换语言，或阅读说明后允许 Apple 服务器识别。")
                .font(.caption).foregroundColor(.secondary)
            Toggle("隐私模式：只在本机识别", isOn: Binding(get: { app.privacyMode }, set: { app.setPrivacyMode($0) }))
            if !app.onDeviceSupported || app.serverConsent {
                Toggle("允许 Apple 服务器识别…", isOn: Binding(get: { app.serverConsent }, set: { app.setServerConsent($0) }))
            }
        }.disabled(app.isBusy)
    }
    private func cleanupOption(_ title: String, detail: String, before: String, after: String, fillers: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: Binding(get: { (fillers ? app.cleanup.preferences.isolatedFillers : app.cleanup.preferences.sentencePrefixes) == .remove }, set: { app.setCleanup(fillers: fillers, enabled: $0) })).font(.headline)
            Text(detail).font(.callout).foregroundColor(.secondary)
            Text("清理前：\(before)\n清理后：\(after)").font(.callout).lineSpacing(5)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035)).cornerRadius(12)
    }
}
