import Foundation
@testable import VoiceTypeCore

private func names(_ events: [SessionEvent]) -> [String] {
    events.map { event in
        switch event {
        case .rightOptionDown(let eligible): return eligible ? "down" : "down-ineligible"
        case .rightOptionUp: return "up"
        case .escape: return "escape"
        case .combinationKey: return "combination"
        default: return "other"
        }
    }
}

private let option = HotkeyInterpreter.optionMask
private let right = HotkeyInterpreter.rightOptionMask
private let nonCoalesced: UInt64 = 0x100

enum LiveSupportCases {
    static let all: [RegressionCase] = hotkeys + verifier + locales + hud + EscapeCases.all

    static let hotkeys: [RegressionCase] = [
        RegressionCase("右Option按下与松开只产生一对事件") {
            var h = HotkeyInterpreter()
            try check(names(h.flagsChanged(keyCode: 61, flags: option | right | nonCoalesced)) == ["down"])
            try check(names(h.flagsChanged(keyCode: 61, flags: option | right | nonCoalesced)).isEmpty, "重复按下不重复开始")
            try check(names(h.flagsChanged(keyCode: 61, flags: nonCoalesced)) == ["up"])
            try check(names(h.flagsChanged(keyCode: 61, flags: nonCoalesced)).isEmpty, "无配对松开被忽略")
        },
        RegressionCase("缺少设备位的右Option仍产生按下与松开") {
            var h = HotkeyInterpreter()
            try check(names(h.flagsChanged(keyCode: 61, flags: option | nonCoalesced)) == ["down"])
            try check(names(h.flagsChanged(keyCode: 61, flags: option | nonCoalesced)).isEmpty)
            try check(names(h.flagsChanged(keyCode: 61, flags: nonCoalesced)) == ["up"])
        },
        RegressionCase("缺少设备位时物理键状态区分左右Option同时按下") {
            var h = HotkeyInterpreter()
            try check(names(h.flagsChanged(keyCode: 61, flags: option, physicalRightOptionDown: true)) == ["down"])
            // Left Option remains held after right Option is released.
            try check(names(h.flagsChanged(keyCode: 61, flags: option, physicalRightOptionDown: false)) == ["up"])
            try check(names(h.flagsChanged(keyCode: 58, flags: option, physicalRightOptionDown: false)).isEmpty)
        },
        RegressionCase("缺少设备位时仍拒绝右Option组合键") {
            for other in [HotkeyInterpreter.commandMask, HotkeyInterpreter.shiftMask, HotkeyInterpreter.controlMask] {
                var h = HotkeyInterpreter()
                try check(names(h.flagsChanged(keyCode: 61, flags: option | other, physicalRightOptionDown: true)) == ["down-ineligible"])
            }
        },
        RegressionCase("已按Cmd/Shift/Ctrl/左Option时右Option不合格") {
            for other in [HotkeyInterpreter.commandMask, HotkeyInterpreter.shiftMask, HotkeyInterpreter.controlMask, HotkeyInterpreter.leftOptionMask] {
                var h = HotkeyInterpreter()
                try check(names(h.flagsChanged(keyCode: 61, flags: option | right | other)) == ["down-ineligible"])
            }
        },
        RegressionCase("左Option不触发听写") {
            var h = HotkeyInterpreter()
            try check(names(h.flagsChanged(keyCode: 58, flags: option | HotkeyInterpreter.leftOptionMask)).isEmpty && !h.rightOptionDown)
        },
        RegressionCase("按住右Option时再按修饰键或普通键视为组合键") {
            var h = HotkeyInterpreter()
            _ = h.flagsChanged(keyCode: 61, flags: option | right)
            try check(names(h.flagsChanged(keyCode: 55, flags: option | right | HotkeyInterpreter.commandMask)) == ["combination"])
            try check(names(h.keyDown(keyCode: 0, isRepeat: false)) == ["combination"])
            var idle = HotkeyInterpreter()
            try check(names(idle.keyDown(keyCode: 0, isRepeat: false)).isEmpty, "未按右Option时普通键不影响会话")
        },
        RegressionCase("Esc随时取消且忽略长按重复") {
            var h = HotkeyInterpreter()
            try check(names(h.keyDown(keyCode: 53, isRepeat: false)) == ["escape"])
            try check(names(h.keyDown(keyCode: 53, isRepeat: true)).isEmpty)
        },
        RegressionCase("漏掉松键时按物理Option状态补发一次松开") {
            var h = HotkeyInterpreter()
            _ = h.flagsChanged(keyCode: 61, flags: option | right)
            try check(names(h.reconcile(physicalFlags: option)).isEmpty, "仍有Option按下不补发")
            try check(names(h.reconcile(physicalFlags: 0)) == ["up"])
            try check(names(h.reconcile(physicalFlags: 0)).isEmpty, "只补发一次")
        },
        RegressionCase("物理状态缺少设备位时不误判松开") {
            var h = HotkeyInterpreter()
            _ = h.flagsChanged(keyCode: 61, flags: option | right)
            try check(names(h.reconcile(physicalFlags: option)).isEmpty && h.rightOptionDown)
        },
    ]

    static let verifier: [RegressionCase] = [
        RegressionCase("光标处插入且长度与光标一致判为已插入") {
            let before = TextFieldSnapshot(selectionLocation: 5, selectionLength: 0, characterCount: 10)
            let after = TextFieldSnapshot(selectionLocation: 7, selectionLength: 0, characterCount: 12)
            try check(InsertionVerifier.evaluate(before: before, after: after, slice: "你好", text: "你好") == .inserted)
        },
        RegressionCase("替换选区按选区长度计算期望字数") {
            let before = TextFieldSnapshot(selectionLocation: 2, selectionLength: 3, characterCount: 10)
            let after = TextFieldSnapshot(selectionLocation: 4, selectionLength: 0, characterCount: 9)
            try check(InsertionVerifier.evaluate(before: before, after: after, slice: "ab", text: "ab") == .inserted)
        },
        RegressionCase("完全无变化判为确定未写入") {
            let before = TextFieldSnapshot(selectionLocation: 5, selectionLength: 0, characterCount: 10)
            try check(InsertionVerifier.evaluate(before: before, after: before, slice: "xy", text: "你好") == .unchanged)
        },
        RegressionCase("读不到写后状态判为不确定") {
            let before = TextFieldSnapshot(selectionLocation: 5, selectionLength: 0, characterCount: 10)
            try check(InsertionVerifier.evaluate(before: before, after: nil, slice: nil, text: "你好") == .inconclusive)
        },
        RegressionCase("目标自动改写文本判为不确定而非失败") {
            let before = TextFieldSnapshot(selectionLocation: 0, selectionLength: 0, characterCount: 0)
            let after = TextFieldSnapshot(selectionLocation: 5, selectionLength: 0, characterCount: 5)
            try check(InsertionVerifier.evaluate(before: before, after: after, slice: "Hello", text: "hello") == .inconclusive)
        },
        RegressionCase("字数不可读时依赖切片与光标，且不推断无变化") {
            let before = TextFieldSnapshot(selectionLocation: 3, selectionLength: 0, characterCount: nil)
            let moved = TextFieldSnapshot(selectionLocation: 5, selectionLength: 0, characterCount: nil)
            try check(InsertionVerifier.evaluate(before: before, after: moved, slice: "好的", text: "好的") == .inserted)
            try check(InsertionVerifier.evaluate(before: before, after: before, slice: "好的", text: "好的") == .inconclusive)
            try check(InsertionVerifier.evaluate(before: before, after: before, slice: "xx", text: "好的") == .inconclusive)
        },
        RegressionCase("UTF-16长度处理emoji") {
            let text = "👍好"
            let before = TextFieldSnapshot(selectionLocation: 1, selectionLength: 0, characterCount: 1)
            let after = TextFieldSnapshot(selectionLocation: 4, selectionLength: 0, characterCount: 4)
            try check(text.utf16.count == 3 && InsertionVerifier.evaluate(before: before, after: after, slice: text, text: text) == .inserted)
        },
        RegressionCase("切片不可读时仅字数和光标同时吻合才算插入") {
            let before = TextFieldSnapshot(selectionLocation: 0, selectionLength: 0, characterCount: 4)
            let ok = TextFieldSnapshot(selectionLocation: 2, selectionLength: 0, characterCount: 6)
            let caretOnly = TextFieldSnapshot(selectionLocation: 2, selectionLength: 0, characterCount: 4)
            try check(InsertionVerifier.evaluate(before: before, after: ok, slice: nil, text: "你好") == .inserted)
            try check(InsertionVerifier.evaluate(before: before, after: caretOnly, slice: nil, text: "你好") == .inconclusive)
        },
    ]

    static let locales: [RegressionCase] = [
        RegressionCase("简体中文偏好映射到zh-CN") {
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["zh-Hans-US", "en-US"], supported: ["en-US", "zh-CN", "zh-TW"]) == "zh-CN")
        },
        RegressionCase("繁体中文偏好映射到zh-TW") {
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["zh-Hant-TW"], supported: ["en-US", "zh-CN", "zh-TW"]) == "zh-TW")
        },
        RegressionCase("英文地区优先，不支持时回落en-US") {
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["en-GB"], supported: ["en-GB", "en-US"]) == "en-GB")
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["en-NZ"], supported: ["en-GB", "en-US"]) == "en-US")
        },
        RegressionCase("有效覆盖优先，无效覆盖忽略，下划线规范化") {
            try check(RecognitionLocaleResolver.resolve(override: "en_US", preferred: ["zh-Hans-CN"], supported: ["zh_CN", "en_US"]) == "en-US")
            try check(RecognitionLocaleResolver.resolve(override: "xx-YY", preferred: ["zh-Hans-CN"], supported: ["zh_CN", "en_US"]) == "zh-CN")
        },
        RegressionCase("无匹配时回落en-US或排序首项") {
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["fr-FR"], supported: ["de-DE", "en-US"]) == "en-US")
            try check(RecognitionLocaleResolver.resolve(override: nil, preferred: ["fr-FR"], supported: ["ja-JP", "de-DE"]) == "de-DE")
        },
    ]

    static let hud: [RegressionCase] = [
        RegressionCase("HUD显示识别方式与实时字幕") {
            let h = ReducerHarness(); try h.start()
            try check(h.machine.hudMessage == "正在聆听 · 端侧识别")
            h.send(.response(try require(h.machine.context?.recognizerToken), .partial("你好")), at: 100)
            try check(h.machine.liveCaption == "你好")
        },
        RegressionCase("服务器识别会话在HUD明示") {
            var env = SessionEnvironment(); env.supportsOnDevice = false
            var prefs = SessionPreferences(); prefs.appleServerConsent = true
            let h = ReducerHarness(preferences: prefs, environment: env); try h.start()
            try check(h.machine.hudMessage == "正在聆听 · Apple 服务器识别")
        },
        RegressionCase("取消与危险信号的HUD文案") {
            let h = ReducerHarness(); try h.start(); h.send(.escape, at: 50)
            try check(h.machine.state == .cancelled && h.machine.hudMessage == "已取消" && h.machine.liveCaption.isEmpty)
            var env = SessionEnvironment(); env.safety = SafetySignals(secureTextField: true)
            let blocked = ReducerHarness(environment: env); blocked.send(.rightOptionDown(eligible: true), at: 0)
            try check(blocked.machine.state == .error && blocked.machine.hudMessage == "密码框或安全输入已开启，未插入")
        },
        RegressionCase("每个失败原因都有中文HUD文案") {
            let reasons: [FailureReason] = [.permissionMissing, .deviceUnavailable, .recognitionUnavailable, .onDeviceRequired, .serverConsentRequired, .noSpeech, .recognitionFailed, .audioStartFailed, .audioStopFailed, .unsafeTarget, .processingFailed, .deliveryFailed, .insertionUnknown]
            try check(Set(reasons.map(SessionStateMachine.failureMessage)).count == reasons.count)
            try check(SessionStateMachine.failureMessage(.insertionUnknown) == "可能已经插入，请检查")
        },
        RegressionCase("假系统全链路：字幕送达HUD且插入后显示已插入") {
            let s = FakeSessionSystem(); s.holdAndRelease(); s.finish()
            try check(s.coordinator.machine.state == .done && s.coordinator.machine.hudMessage == "已插入")
            try check(s.hud.captions.contains("测试文本。") && s.hud.captions.last == "")
        },
        RegressionCase("发送后回调可观察每个状态") {
            let s = FakeSessionSystem(); var seen: [SessionState] = []
            s.coordinator.onAfterSend = { seen.append($0.state) }
            s.holdAndRelease(); s.finish()
            try check(seen.contains(.recording) && seen.contains(.inserting) && seen.last == .done)
        },
        RegressionCase("插入看门狗默认180ms且可为真实验证放宽") {
            for watchdog: Milliseconds in [180, 500] {
                var m = SessionStateMachine(timing: SessionTiming(insertionWatchdog: watchdog))
                m.send(.rightOptionDown(eligible: true), at: 0)
                m.send(.response(try require(m.context?.audioToken), .audioStarted), at: 0)
                m.send(.response(try require(m.context?.recognizerToken), .partial("测试。")), at: 100)
                m.send(.rightOptionUp, at: 400)
                m.send(.response(try require(m.context?.stopToken), .audioStopped), at: 420)
                m.send(.response(try require(m.context?.recognizerToken), .final("测试。")), at: 430)
                m.send(.response(try require(m.context?.activeOperation), .localProcessed("测试。")), at: 435)
                try check(m.state == .inserting && m.context?.deadlines[.insertion]?.deadline == 435 + watchdog)
            }
        },
    ]
}
