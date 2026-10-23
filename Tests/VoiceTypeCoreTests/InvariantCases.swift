import Foundation
@testable import VoiceTypeCore

enum InvariantCases {
    static var all: [RegressionCase] {
        var cases: [RegressionCase] = [
            .init("启动无回调1秒有界失败，晚到仍close") {
                let h = ReducerHarness(); try h.start(audioAt: nil); let op = try require(h.machine.context?.audioToken)
                h.tick(1_000); try check(h.machine.state == .error && h.machine.context?.metrics.failure == .audioStartFailed)
                let effects = h.send(.response(op, .audioStarted), at: 1_001)
                try check(effects.contains { if case .closeLateAudio = $0 { return true }; return false })
            },
            .init("取消已提交AX后即便确定失败也不得继续paste") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit(); h.send(.escape, at: 442)
                h.send(.response(op, .insertionResult(.definiteFailure)), at: 450)
                try check(h.machine.state == .error && h.machine.context?.metrics.cancelTooLate == true && h.prepareCount == 1)
            },
            .init("提交后锁屏即时清正文，验证成功也不重建恢复正文") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit()
                h.send(.interrupted(.locked), at: 442)
                try check(h.machine.context?.deliveryText == "" && h.machine.context?.frozenText == "")
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                try check(h.machine.state == .done && h.machine.context?.recoveryText == "")
            },
            .init("提交后切应用未知结果不得copy重发") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit()
                h.send(.applicationChanged(200), at: 442); h.send(.response(op, .insertionResult(.unknown)), at: 450)
                try check(h.machine.state == .error && h.prepareCount == 1)
            },
            .init("正在服务器finalizing时撤回同意或隐私仍取消") {
                for privacy in [false, true] {
                    var env = SessionEnvironment(); env.supportsOnDevice = false
                    var prefs = SessionPreferences(); prefs.appleServerConsent = true
                    let h = ReducerHarness(preferences: prefs, environment: env); try h.start(); h.send(.rightOptionUp, at: 400)
                    h.send(privacy ? .privacyChanged(true) : .serverConsentChanged(false), at: 410)
                    try check(h.machine.state == .cancelled)
                }
            },
            .init("端侧录音中开启隐私不取消，模型后续跳过") {
                var prefs = SessionPreferences(); prefs.polishEnabled = true
                var env = SessionEnvironment(); env.hasModelKey = true
                let h = ReducerHarness(preferences: prefs, environment: env); try h.start(); h.send(.privacyChanged(true), at: 10)
                try check(h.machine.state == .recording)
                let speech = try require(h.machine.context?.recognizerToken); h.send(.response(speech, .partial("正文")), at: 20)
                h.send(.rightOptionUp, at: 400); h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                h.send(.response(speech, .final("正文")), at: 430); h.send(.response(try require(h.machine.context?.activeOperation), .localProcessed("正文")), at: 435)
                try check(h.machine.state == .inserting && h.modelCount == 0 && h.machine.context?.metrics.modelPath == .skippedPrivacyMode)
            },
            .init("设备断开有文本降级，无文本报错") {
                for text in ["", "已有文本"] {
                    let h = ReducerHarness(); try h.start()
                    if !text.isEmpty { h.send(.response(try require(h.machine.context?.recognizerToken), .partial(text)), at: 20) }
                    h.send(.interrupted(.deviceDisconnected), at: 400)
                    try check(h.machine.state == (text.isEmpty ? .error : .finalizing))
                }
            },
            .init("权限撤销即error并停止系统，不等待5分钟") {
                let s = FakeSessionSystem(); s.start(); s.clock.advance(to: 100); s.coordinator.send(.interrupted(.permissionRevoked)); s.clock.advance(by: 0)
                try check(s.coordinator.machine.state == .error && s.audio.active.isEmpty && s.inserter.writes.isEmpty)
            },
            .init("音频已成功启动后旧失败响应必须无效") {
                let h = ReducerHarness(); try h.start(); h.send(.response(try require(h.machine.context?.audioToken), .audioStartFailed), at: 20)
                try check(h.machine.state == .recording)
            },
            .init("只有final没有partial也记录首次字幕时间") {
                let h = ReducerHarness(); try h.start(); let audio = try require(h.machine.context?.audioToken)
                h.send(.response(audio, .voiceDetected), at: 20); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("只有final")), at: 430)
                try check(h.machine.context?.metrics.firstCaptionLatency == 410)
            },
            .init("明显翻译输出不可取代原语言") {
                try check(!TextProcessor.isValidModelOutput("Meeting tomorrow.", original: "明天开会。", preferences: .init(), complete: true))
                try check(!TextProcessor.isValidModelOutput("明天开会。", original: "Meeting tomorrow.", preferences: .init(), complete: true))
            },
            .init("关键符号不能被模型悄悄删除") {
                try check(!TextProcessor.isValidModelOutput("增长20", original: "增长20%", preferences: .init(), complete: true))
                try check(!TextProcessor.isValidModelOutput("x y 3", original: "x+y=3", preferences: .init(), complete: true))
            },
            .init("多会话每条都记录路径且旧恢复任务跨会话独立") {
                let s = FakeSessionSystem(); s.holdAndRelease(); s.finish(); s.coordinator.send(.reset)
                s.coordinator.send(.applicationChanged(200)); s.holdAndRelease(); s.finish()
                try check(s.metrics.sessions.count == 2 && s.metrics.sessions[0].sessionID != s.metrics.sessions[1].sessionID && s.audio.starts.count == 2)
            }
        ]
        for target in SessionState.allCases {
            cases.append(.init("非法模块回调不能跳状态：\(target.rawValue)") {
                let h = ReducerHarness()
                switch target {
                case .idle: break
                case .recording: try h.start()
                case .finalizing: try h.start(); h.send(.rightOptionUp, at: 400)
                case .processing: try h.processing()
                case .inserting: try h.inserting()
                case .done: try h.inserting(); let op = try h.commit(); h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                case .error: h.send(.rightOptionDown(eligible: true), at: 0); h.send(.response(try require(h.machine.context?.audioToken), .audioStartFailed), at: 1)
                case .cancelled: try h.start(); h.send(.escape, at: 10)
                }
                let before = h.machine.state
                let foreign = OperationToken(session: 999, operation: 999)
                for response in [ModuleResponse.localProcessed("foreign"), .modelResult(text: "foreign", complete: true), .insertionResult(.verifiedSuccess), .final("foreign"), .audioStopped] {
                    h.send(.response(foreign, response), at: h.machine.lastTime)
                    try check(h.machine.state == before)
                }
            })
        }
        for seed: UInt64 in [17, 2026] {
            cases.append(.init("确定性1000事件状态转换不变量 seed=\(seed)") {
                let s = FakeSessionSystem(); var random = seed
                let allowed: Set<String> = ["idle>recording", "idle>error", "recording>finalizing", "recording>cancelled", "recording>error", "finalizing>processing", "finalizing>cancelled", "finalizing>error", "processing>inserting", "processing>cancelled", "processing>error", "inserting>done", "inserting>cancelled", "inserting>error", "done>idle", "error>idle", "cancelled>idle"]
                for _ in 0..<1_000 {
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    switch random % 8 {
                    case 0: s.hotkeys.emit(.rightOptionDown(eligible: true))
                    case 1: s.hotkeys.emit(.rightOptionUp)
                    case 2: s.hotkeys.emit(.escape)
                    case 3: s.coordinator.send(.combinationKey)
                    case 4: s.coordinator.send(.applicationChanged(random % 2 == 0 ? 100 : 200))
                    case 5: s.coordinator.send(.privacyChanged(random % 3 == 0))
                    case 6: s.coordinator.send(.response(.init(session: 999, operation: 1), .modelFailed))
                    default: s.coordinator.send(.reset)
                    }
                    s.clock.advance(by: Milliseconds((random >> 20) % 200))
                    if [.processing, .inserting].contains(s.coordinator.machine.state) { try check(s.coordinator.machine.context?.audioClosed == true && s.audio.active.isEmpty) }
                    if !s.coordinator.machine.isActive && s.coordinator.machine.state != .idle { s.hotkeys.emit(.rightOptionUp); s.coordinator.send(.reset) }
                }
                let trace = s.coordinator.visitedStates
                for index in 1..<trace.count { try check(allowed.contains(trace[index-1].rawValue + ">" + trace[index].rawValue), "illegal transition \(trace[index-1])→\(trace[index])") }
                try check(!s.audio.starts.isEmpty && s.metrics.sessions.count > 10)
            })
        }
        return cases
    }
}
