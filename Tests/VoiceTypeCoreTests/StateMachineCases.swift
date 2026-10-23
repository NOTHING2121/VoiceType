import Foundation
@testable import VoiceTypeCore

enum StateMachineCases {
    static var all: [RegressionCase] {
        var cases: [RegressionCase] = [
            .init("八状态成功链与终态清理门") {
                let h = ReducerHarness(); try check(h.machine.state == .idle)
                try h.start(); try check(h.machine.state == .recording)
                let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .partial("hello")), at: 100)
                h.send(.rightOptionUp, at: 400); try check(h.machine.state == .finalizing)
                h.send(.response(speech, .final("hello")), at: 410); try check(h.machine.state == .finalizing)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                try check(h.machine.state == .processing)
                h.send(.response(try require(h.machine.context?.activeOperation), .localProcessed("hello")), at: 425)
                try check(h.machine.state == .inserting)
                let op = try h.commit(); h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                try check(h.machine.state == .done)
                h.send(.reset, at: 451); try check(h.machine.state == .done)
                h.send(.cleanupFinished(try require(h.machine.context?.id)), at: 452)
                try check(h.machine.state == .idle)
                try check(h.audioStartCount == 1 && h.audioStopCount == 1)
            },
            .init("未配对松键与不合格修饰键无副作用") {
                let h = ReducerHarness(); h.send(.rightOptionUp, at: 0); h.send(.rightOptionDown(eligible: false), at: 1)
                try check(h.machine.state == .idle && h.audioStartCount == 0)
            },
            .init("重复 keyDown 不重复开始") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionDown(eligible: true), at: 10)
                try check(h.audioStartCount == 1)
            },
            .init("249ms 进入免提，静默不误取消") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 249); h.tick(2_000)
                try check(h.machine.state == .recording && h.machine.context?.mode == .handsFree)
            },
            .init("250ms 按住边界与 timer 顺序无关") {
                for fireTimer in [false, true] {
                    let h = ReducerHarness(); try h.start(); if fireTimer { h.tick(250) }
                    h.send(.rightOptionUp, at: 250)
                    try check(h.machine.state == .finalizing && h.audioStopCount == 1)
                }
            },
            .init("299ms 无声短会话丢弃") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 299)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 310); h.tick(799)
                try check(h.machine.state == .cancelled && h.machine.context?.metrics.cancellation == .accidentalNoSpeech)
                try check(h.prepareCount == 0)
            },
            .init("300ms 无声不是误触，返回 noSpeech") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 300)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 320); h.tick(800)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .noSpeech)
            },
            .init("低声肯定信号不误丢弃短词") {
                let h = ReducerHarness(); try h.start()
                h.send(.response(try require(h.machine.context?.audioToken), .voiceDetected), at: 20)
                h.send(.rightOptionUp, at: 260)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 280)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("是")), at: 290)
                try check(h.machine.state == .processing)
            },
            .init("没有 VAD 但非空识别不误丢弃") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 260)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 280)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("好")), at: 290)
                try check(h.machine.state == .processing)
            },
            .init("免提二次短单击结束同一会话") {
                let h = ReducerHarness(); try h.start(); let id = h.machine.context?.id
                h.send(.rightOptionUp, at: 100); h.send(.rightOptionDown(eligible: true), at: 1_000); h.send(.rightOptionUp, at: 1_100)
                try check(h.machine.state == .finalizing && h.machine.context?.id == id && h.machine.context?.metrics.stopReason == .handsFreeTap)
            },
            .init("免提二次长按变按住说") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 100)
                h.send(.rightOptionDown(eligible: true), at: 1_000); h.tick(1_250)
                try check(h.machine.context?.mode == .pushToTalk)
                h.send(.rightOptionUp, at: 1_300); try check(h.machine.state == .finalizing && h.audioStartCount == 1)
            },
            .init("Option 组合键废弃 provisional 会话") {
                let h = ReducerHarness(); try h.start(); h.send(.combinationKey, at: 10)
                try check(h.machine.state == .cancelled && h.machine.context?.metrics.cancellation == .combination)
            },
            .init("五分钟从实际采集开始计且只停止一次") {
                let h = ReducerHarness(); try h.start(audioAt: 100)
                h.tick(300_099); try check(h.machine.state == .recording)
                h.tick(300_100); try check(h.machine.state == .finalizing)
                h.send(.rightOptionUp, at: 300_101); h.tick(300_102)
                try check(h.audioStopCount == 1 && h.machine.context?.metrics.stopReason == .recordingLimit)
            },
            .init("五分钟结束后必须清理并释放按键再重启") {
                let h = ReducerHarness(); try h.start(); h.tick(300_000)
                h.send(.escape, at: 300_001); let old = try require(h.machine.context?.id)
                h.send(.cleanupFinished(old), at: 300_002); h.send(.reset, at: 300_003)
                h.send(.rightOptionDown(eligible: true), at: 300_004); try check(h.machine.state == .cancelled)
                h.send(.rightOptionUp, at: 300_005); try check(h.machine.state == .idle)
                h.send(.rightOptionDown(eligible: true), at: 300_006); try check(h.machine.context?.id != old)
            },
            .init("partial 只替换，不累计修订字幕") {
                let h = ReducerHarness(); try h.start(); let op = try require(h.machine.context?.recognizerToken)
                h.send(.response(op, .partial("我想")), at: 20); h.send(.response(op, .partial("我想去")), at: 30)
                try check(h.machine.context?.partial == "我想去")
            },
            .init("final 先到仍等待音频关闭确认") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("final")), at: 410)
                try check(h.machine.state == .finalizing)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                try check(h.machine.state == .processing && h.machine.context?.audioClosed == true)
            },
            .init("500ms final 截止冻结 partial，迟到 final 不修改") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .partial("partial")), at: 50); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 410); h.tick(900)
                try check(h.machine.context?.frozenText == "partial" && h.machine.context?.metrics.recognitionSource == "partial")
                h.send(.response(speech, .final("late")), at: 901); try check(h.machine.context?.frozenText == "partial")
            },
            .init("恰在 final 截止的结果不能赢过超时") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .partial("保底")), at: 50); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 410)
                h.send(.response(speech, .final("不该替换")), at: 900)
                try check(h.machine.context?.frozenText == "保底")
            },
            .init("空 final 不抹掉非空 partial") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .partial("已有")), at: 50); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 410)
                h.send(.response(speech, .final("")), at: 420)
                try check(h.machine.state == .processing && h.machine.context?.frozenText == "已有" && h.machine.context?.metrics.recognitionSource == "partial")
            },
            .init("音频停止失败禁止处理") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("text")), at: 410)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopFailed), at: 420)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .audioStopFailed && h.prepareCount == 0)
            },
            .init("音频停止无确认也不会带麦进入 processing") {
                let h = ReducerHarness(); try h.start(); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.recognizerToken), .final("text")), at: 410); h.tick(900)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .audioStopFailed)
            },
            .init("录音自然结束有文本则收尾") {
                let h = ReducerHarness(); try h.start()
                h.send(.response(try require(h.machine.context?.recognizerToken), .partial("text")), at: 30)
                h.send(.response(try require(h.machine.context?.audioToken), .audioEnded), at: 100)
                try check(h.machine.state == .finalizing && h.machine.context?.metrics.stopReason == .deviceEnded)
            },
            .init("识别失败无文本为 error，不向服务器重传") {
                let h = ReducerHarness(); try h.start()
                h.send(.response(try require(h.machine.context?.recognizerToken), .recognitionFailed), at: 50)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .recognitionFailed && h.audioStartCount == 1)
            },
            .init("识别失败有 partial 可收尾降级") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .partial("保留")), at: 30); h.send(.response(speech, .recognitionFailed), at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420); h.tick(900)
                try check(h.machine.state == .processing && h.machine.context?.frozenText == "保留")
            },
            .init("资源晚到主动 close，不只是忽略 callback") {
                let h = ReducerHarness(); try h.start(audioAt: nil); let audio = try require(h.machine.context?.audioToken)
                h.send(.escape, at: 10); let effects = h.send(.response(audio, .audioStarted), at: 20)
                try check(h.machine.state == .cancelled)
                try check(effects.contains { if case .closeLateAudio(let op) = $0 { return op == audio }; return false })
            },
            .init("启动失败只终止一次并记录指标") {
                let h = ReducerHarness(); try h.start(audioAt: nil); let audio = try require(h.machine.context?.audioToken)
                h.send(.response(audio, .audioStartFailed), at: 20); h.send(.response(audio, .audioStartFailed), at: 21)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .audioStartFailed)
                try check(h.allEffects.filter { if case .recordMetrics = $0 { return true }; return false }.count == 1)
            },
            .init("新会话不接受旧 session 或旧 operation 回调") {
                let h = ReducerHarness(); try h.start(); let old = try require(h.machine.context?.recognizerToken); let id = old.session
                h.send(.escape, at: 100); h.send(.cleanupFinished(id), at: 101); h.send(.reset, at: 102); h.send(.rightOptionUp, at: 103)
                try h.start(at: 104, audioAt: 104)
                h.send(.response(old, .partial("old")), at: 110)
                h.send(.response(.init(session: h.machine.context!.id, operation: 99_999), .final("wrong operation")), at: 111)
                try check(h.machine.state == .recording && h.machine.context?.partial == "")
            },
            .init("busy 状态按键不启动第二会话") {
                let h = ReducerHarness(); try h.processing(); h.send(.rightOptionDown(eligible: true), at: 431)
                try check(h.audioStartCount == 1 && h.machine.state == .processing)
            },
            .init("AX 安全信息缺失不是危险信号") {
                var environment = SessionEnvironment(); environment.safety = .init(secureTextField: nil)
                let h = ReducerHarness(environment: environment); try h.start(); try check(h.machine.state == .recording)
            },
            .init("端侧优先，即使已有服务器同意") {
                var preferences = SessionPreferences(); preferences.appleServerConsent = true
                let h = ReducerHarness(preferences: preferences); try h.start()
                try check(h.machine.context?.policy == .onDevice)
            },
            .init("端侧不支持未同意，系统权限不代替产品同意") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false
                let h = ReducerHarness(environment: environment); h.send(.rightOptionDown(eligible: true), at: 0)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .serverConsentRequired && h.audioStartCount == 0)
            },
            .init("有同意但隐私模式强制端侧") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false
                var preferences = SessionPreferences(); preferences.appleServerConsent = true; preferences.privacyMode = true
                let h = ReducerHarness(preferences: preferences, environment: environment); h.send(.rightOptionDown(eligible: true), at: 0)
                try check(h.machine.context?.metrics.failure == .onDeviceRequired && h.audioStartCount == 0)
            },
            .init("明确同意且非隐私模式允许服务器") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false
                var preferences = SessionPreferences(); preferences.appleServerConsent = true
                let h = ReducerHarness(preferences: preferences, environment: environment); try h.start()
                try check(h.machine.context?.policy == .appleServerAllowed)
            },
            .init("服务器路径断网不能开麦") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false; environment.online = false
                var preferences = SessionPreferences(); preferences.appleServerConsent = true
                let h = ReducerHarness(preferences: preferences, environment: environment); h.send(.rightOptionDown(eligible: true), at: 0)
                try check(h.machine.state == .error && h.audioStartCount == 0)
            },
            .init("服务器路径45秒轮换不丢失 pending partial") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false
                var preferences = SessionPreferences(); preferences.appleServerConsent = true
                let h = ReducerHarness(preferences: preferences, environment: environment); try h.start()
                let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .partial("第一段")), at: 100); h.tick(45_000)
                let second = try require(h.machine.context?.recognizerToken); try check(second != first)
                h.send(.response(second, .partial("第二段")), at: 45_100)
                h.send(.rightOptionUp, at: 45_400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 45_420); h.tick(45_900)
                try check(h.machine.context?.frozenText == "第一段 第二段")
            },
            .init("segment 时间去重且旧段不清空新 partial") {
                var environment = SessionEnvironment(); environment.supportsOnDevice = false
                var preferences = SessionPreferences(); preferences.appleServerConsent = true
                let h = ReducerHarness(preferences: preferences, environment: environment); try h.start()
                let first = try require(h.machine.context?.recognizerToken); h.tick(45_000)
                let next = try require(h.machine.context?.recognizerToken)
                h.send(.response(next, .partial("新尾部")), at: 45_100)
                h.send(.response(first, .segmentFinal(text: "旧段", audioEnd: 44_000)), at: 45_110)
                h.send(.response(first, .segmentFinal(text: "重复", audioEnd: 44_000)), at: 45_120)
                try check(h.machine.context?.committedSegments == ["旧段"] && h.machine.context?.partial == "新尾部")
            },
            .init("空 final 触发端侧续接但保留 partial") {
                let h = ReducerHarness(); try h.start(); let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .partial("保底")), at: 20); h.send(.response(first, .final("")), at: 100)
                try check(h.machine.context?.recognizerToken != first && h.machine.context?.pendingPartials[first] == "保底")
            },
            .init("应用切换再切回仍正常 copy-only") {
                let h = ReducerHarness(); try h.processing()
                h.send(.applicationChanged(200), at: 431); h.send(.applicationChanged(100), at: 432)
                h.send(.response(try require(h.machine.context?.activeOperation), .localProcessed("text")), at: 435)
                try check(h.machine.state == .inserting && h.machine.context?.strategy == .copy)
                let op = try h.commit(); h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                try check(h.machine.state == .done && h.machine.hudMessage == "已复制，按 command+v粘贴")
            },
            .init("cleanup 偏好会话快照，不被中途修改") {
                let h = ReducerHarness(); try h.start()
                var prefs = CleanupPreferences(); prefs.isolatedFillers = .remove
                h.send(.cleanupPreferencesChanged(prefs), at: 100)
                try check(h.machine.preferences.cleanup.isolatedFillers == .remove && h.machine.context?.preferences.cleanup.isolatedFillers == .unset)
            },
            .init("终态恢复正文60秒清除，锁屏即时清除") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit()
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                try check(h.machine.context?.recoveryText == "测试文本。")
                h.tick(60_450); try check(h.machine.context?.recoveryText == "")
                let g = ReducerHarness(); try g.inserting(); let op2 = try g.commit()
                g.send(.response(op2, .insertionResult(.verifiedSuccess)), at: 450); g.send(.interrupted(.locked), at: 451)
                try check(g.machine.context?.recoveryText == "")
            }
        ]
        let permissionVariants: [(String, (inout SessionEnvironment) -> Void)] = [
            ("麦克风", { $0.microphonePermission = false }), ("Speech", { $0.speechPermission = false }),
            ("监听", { $0.hotkeyPermission = false }), ("设备", { $0.deviceAvailable = false }),
            ("识别可用性", { $0.recognitionAvailable = false })
        ]
        for (name, change) in permissionVariants {
            cases.append(.init("启动门禁：\(name)") { var env = SessionEnvironment(); change(&env); let h = ReducerHarness(environment: env); h.send(.rightOptionDown(eligible: true), at: 0); try check(h.machine.state == .error && h.audioStartCount == 0) })
        }
        for signals in [SafetySignals(secureTextField: true), SafetySignals(secureEventInput: true)] {
            let label = signals.secureTextField == true ? "密码 subrole" : "Secure Event Input"
            cases.append(.init("明确危险信号启动阻断：\(label)") { var env = SessionEnvironment(); env.safety = signals; let h = ReducerHarness(environment: env); h.send(.rightOptionDown(eligible: true), at: 0); try check(h.machine.state == .error && h.audioStartCount == 0) })
            cases.append(.init("明确危险信号交付阻断：\(label)") { let h = ReducerHarness(); try h.inserting(); h.send(.safetyChanged(signals), at: 436); try check(h.machine.state == .error && h.machine.context?.recoveryText == "") })
        }
        for phase in [SessionState.recording, .finalizing, .processing, .inserting] {
            cases.append(.init("Esc 提交前取消：\(phase.rawValue)") {
                let h = ReducerHarness()
                if phase == .processing { try h.processing() }
                else if phase == .inserting { try h.inserting() }
                else { try h.start(); if phase == .finalizing { h.send(.rightOptionUp, at: 400) } }
                h.send(.escape, at: h.machine.lastTime + 1)
                try check(h.machine.state == .cancelled && h.machine.context?.recoveryText == "" && h.machine.context?.metrics.cancellation == .escape)
            })
        }
        let interrupts: [(String, InterruptReason)] = [("锁屏", .locked), ("睡眠", .sleeping), ("退出", .quitting), ("监听失联", .listenerLost)]
        for (name, interrupt) in interrupts {
            cases.append(.init("录音中止：\(name)") { let h = ReducerHarness(); try h.start(); h.send(.interrupted(interrupt), at: 100); try check(h.machine.state == .cancelled) })
        }
        for revoke in [false, true] {
            cases.append(.init(revoke ? "服务器会话撤回同意即时取消" : "服务器会话开启隐私即时取消") {
                var env = SessionEnvironment(); env.supportsOnDevice = false
                var prefs = SessionPreferences(); prefs.appleServerConsent = true
                let h = ReducerHarness(preferences: prefs, environment: env); try h.start()
                h.send(revoke ? .serverConsentChanged(false) : .privacyChanged(true), at: 100)
                try check(h.machine.state == .cancelled)
            })
        }
        return cases
    }
}
