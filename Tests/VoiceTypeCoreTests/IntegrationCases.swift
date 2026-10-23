import Foundation
@testable import VoiceTypeCore

enum IntegrationCases {
    static func pasteSystem() -> FakeSessionSystem {
        let system = FakeSessionSystem(); system.inserter.axAvailable = false; return system
    }
    static var all: [RegressionCase] {
        var cases: [RegressionCase] = [
            .init("假端到端：按键到AX，八状态与资源关闭") {
                let s = FakeSessionSystem(); s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .done)
                try check(s.coordinator.visitedStates == [.idle, .recording, .finalizing, .processing, .inserting, .done])
                try check(s.audio.active.isEmpty && s.inserter.targetTexts == ["测试文本。"] && s.inserter.writes.count == 1)
                try check(s.metrics.sessions.count == 1 && s.metrics.sessions[0].deliveryPath == .insertedAX)
                s.coordinator.send(.reset); try check(s.coordinator.machine.state == .idle)
            },
            .init("假端到端：免提静默后说话再单击结束") {
                let s = FakeSessionSystem(); s.transcriber.emissions = []; s.start()
                s.clock.advance(to: 100); s.hotkeys.emit(.rightOptionUp); s.clock.advance(to: 2_000)
                try check(s.coordinator.machine.state == .recording)
                let speech = try require(s.coordinator.machine.context?.recognizerToken)
                s.coordinator.send(.response(speech, .partial("免提文本。"))); s.transcriber.finalText = "免提文本。"
                s.hotkeys.emit(.rightOptionDown(eligible: true)); s.clock.advance(by: 100); s.hotkeys.emit(.rightOptionUp); s.finish()
                try check(s.coordinator.machine.state == .done && s.audio.starts.count == 1 && s.inserter.targetTexts == ["免提文本。"])
            },
            .init("假端到端：partial降级也只交付一次") {
                let s = FakeSessionSystem(); s.transcriber.finalText = nil; s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .done && s.metrics.sessions.first?.recognitionSource == "partial" && s.inserter.writes.count == 1)
            },
            .init("假端到端：模型成功且软ZDR不要求端点") {
                var prefs = SessionPreferences(); prefs.polishEnabled = true; prefs.preferZDR = true
                var env = SessionEnvironment(); env.hasModelKey = true
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .done && s.processor.modelRequests.count == 1 && s.processor.modelRequests[0].2)
                try check(s.metrics.sessions.first?.modelPath == .polished)
            },
            .init("假端到端：模型超时后迟到回调不重复插入") {
                var prefs = SessionPreferences(); prefs.polishEnabled = true
                var env = SessionEnvironment(); env.hasModelKey = true
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.processor.modelDelay = 900
                s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .done && s.inserter.writes.count == 1 && s.metrics.sessions.first?.modelPath == .timeout)
            },
            .init("假端到端：切应用后复制精确HUD文案且不恢复") {
                let s = FakeSessionSystem(); s.start(); s.clock.advance(by: 100)
                s.coordinator.send(.applicationChanged(200)); s.coordinator.send(.applicationChanged(100))
                s.clock.advance(to: 400); s.hotkeys.emit(.rightOptionUp); s.finish()
                try check(s.inserter.preparations == [.copy] && s.inserter.writes.map { $0.1 } == [.copy])
                try check(s.clipboard.text == "测试文本。" && s.inserter.restorations.isEmpty)
                try check(s.coordinator.machine.hudMessage == "已复制，按 command+v粘贴" && s.metrics.sessions.first?.stopToInsertion == nil && s.metrics.sessions.first?.stopToCopy != nil)
            },
            .init("假端到端：AX未知绝不再粘贴或复制") {
                let s = FakeSessionSystem(); s.inserter.axResult = .unknown; s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .error && s.inserter.writes.map { $0.1 } == [.ax] && s.clipboard.items.isEmpty)
            },
            .init("假端到端：AX确定失败→paste验证成功") {
                let s = FakeSessionSystem(); s.inserter.axResult = .definiteFailure; s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .done && s.inserter.writes.map { $0.1 } == [.ax, .paste] && s.metrics.sessions.first?.deliveryPath == .insertedPaste)
            },
            .init("假端到端：权限缺失从不开麦且记error指标") {
                var env = SessionEnvironment(); env.microphonePermission = false
                let s = FakeSessionSystem(environment: env); s.start(); s.finish()
                try check(s.audio.starts.isEmpty && s.coordinator.machine.state == .error && s.metrics.sessions.count == 1)
            },
            .init("假端到端：晚到录音句柄被真实假模块close") {
                let s = FakeSessionSystem(); s.audio.startDelay = 100; s.start()
                s.coordinator.send(.escape); s.clock.advance(to: 200)
                try check(s.audio.active.isEmpty && s.audio.lateCloses.count == 1 && s.coordinator.machine.state == .cancelled)
            },
            .init("假端到端：关闭失败清理前不准新会话") {
                let s = FakeSessionSystem(); s.audio.failStop = true; s.audio.cleanupDelay = 200
                s.holdAndRelease(); s.clock.advance(to: 450); s.coordinator.send(.reset)
                s.hotkeys.emit(.rightOptionDown(eligible: true)); try check(s.audio.starts.count == 1 && s.coordinator.machine.state == .error)
                s.hotkeys.emit(.rightOptionUp); s.clock.advance(to: 700); try check(s.coordinator.machine.state == .idle && s.audio.active.isEmpty)
            },
            .init("已排队的启动effect取消后不准启动系统模块") {
                let s = FakeSessionSystem(); s.coordinator.autoRunEffects = false
                s.hotkeys.emit(.rightOptionDown(eligible: true)); s.hotkeys.emit(.escape); s.coordinator.runEffects(); s.clock.advance(by: 0)
                try check(s.audio.starts.isEmpty && s.transcriber.starts.isEmpty && s.inserter.writes.isEmpty)
            },
            .init("已排队的写入effect在Esc后不准执行") {
                let s = FakeSessionSystem(); s.holdAndRelease(); s.clock.advance(to: 435)
                s.coordinator.autoRunEffects = false; s.clock.advance(to: 437)
                try check(s.coordinator.machine.context?.prepared == true)
                s.hotkeys.emit(.escape); s.coordinator.runEffects(); s.clock.advance(by: 0)
                try check(s.coordinator.machine.state == .cancelled && s.inserter.writes.isEmpty)
            },
            .init("实际fake提交后Esc，保留done与cancelTooLate") {
                let s = FakeSessionSystem(); s.holdAndRelease(); s.clock.advance(to: 437)
                try check(s.inserter.writes.count == 1); s.hotkeys.emit(.escape); s.finish()
                try check(s.coordinator.machine.state == .done && s.metrics.sessions.first?.cancelTooLate == true)
            },
            .init("多类型与多item剪贴板精确500ms恢复") {
                let s = pasteSystem()
                let original: ClipboardItems = [["public.utf8-plain-text": Data("原内容".utf8), "public.rtf": Data([0,1,2])], ["public.png": Data([137,80,78,71])]]
                s.clipboard.replace(original); s.holdAndRelease(); s.clock.advance(to: 440)
                let pasteTime = try require(s.coordinator.machine.context?.metrics.timestamps["writeCommitted"])
                s.clock.advance(to: pasteTime + 499); try check(s.clipboard.text == "测试文本。")
                s.clock.advance(to: pasteTime + 500)
                try check(s.clipboard.items == original && s.inserter.restorations.last?.result == .restored && s.inserter.pendingRestores == 0)
            },
            .init("原剪贴板为空时版本匹配才恢复为空") {
                let s = pasteSystem(); s.holdAndRelease(); s.finish()
                try check(s.clipboard.items.isEmpty && s.inserter.restorations.last?.result == .restored)
            },
            .init("500ms前用户改写，新版绝对不动") {
                let s = pasteSystem(); s.holdAndRelease(); s.clock.advance(to: 500); s.clipboard.writeText("用户新版")
                let version = s.clipboard.changeCount; s.finish()
                try check(s.clipboard.text == "用户新版" && s.clipboard.changeCount == version && s.inserter.restorations.last?.result == .skippedChanged)
            },
            .init("粘贴done与HUD重置后恢复任务仍继续") {
                let s = pasteSystem(); s.clipboard.writeText("old"); s.holdAndRelease(); s.clock.advance(to: 500)
                try check(s.coordinator.machine.state == .done); s.coordinator.send(.reset); try check(s.coordinator.machine.state == .idle)
                s.clock.advance(to: 1_000); try check(s.clipboard.text == "old" && s.inserter.restorations.last?.result == .restored)
            },
            .init("剪贴板恢复失败不谎报已恢复") {
                let s = pasteSystem(); s.clipboard.writeText("old"); s.holdAndRelease(); s.clock.advance(to: 500)
                s.clipboard.writable = false; s.clock.advance(to: 1_000)
                try check(s.inserter.restorations.last?.result == .restoreFailed && s.inserter.pendingRestores == 0)
            },
            .init("不能完整备份时跳过paste转copy") {
                let s = pasteSystem(); s.clipboard.canSnapshot = false; s.holdAndRelease(); s.finish()
                try check(s.inserter.writes.map { $0.1 } == [.copy] && s.inserter.restorations.isEmpty)
            },
            .init("后续copy新版本使旧paste恢复timer跳过") {
                let clock = VirtualScheduler(), clipboard = FakeClipboard(); let inserter = FakeTextInserter(clock: clock, clipboard: clipboard)
                clipboard.writeText("original")
                inserter.write(.init(session: 1, operation: 1), strategy: .paste, text: "paste", callback: { _, _ in })
                clock.advance(to: 100)
                inserter.write(.init(session: 2, operation: 2), strategy: .copy, text: "copy", callback: { _, _ in })
                clock.advance(to: 600)
                try check(clipboard.text == "copy" && inserter.restorations.count == 1 && inserter.restorations[0].result == .skippedChanged)
            },
            .init("连续paste继承用户原快照且旧timer不覆盖新payload") {
                let clock = VirtualScheduler(), clipboard = FakeClipboard(); let inserter = FakeTextInserter(clock: clock, clipboard: clipboard)
                clipboard.writeText("original")
                inserter.write(.init(session: 1, operation: 1), strategy: .paste, text: "one", callback: { _, _ in })
                clock.advance(to: 100)
                inserter.write(.init(session: 2, operation: 2), strategy: .paste, text: "two", callback: { _, _ in })
                clock.advance(to: 500); try check(clipboard.text == "two" && inserter.restorations[0].result == .skippedChanged)
                clock.advance(to: 600); try check(clipboard.text == "original" && inserter.restorations[1].result == .restored)
            },
            .init("超过500ms慢消费的风险明确可复现") {
                let s = pasteSystem(); s.clipboard.writeText("old"); s.inserter.pasteConsumptionDelay = 700
                s.holdAndRelease(); s.finish()
                try check(s.coordinator.machine.state == .error && s.coordinator.machine.context?.metrics.failure == .insertionUnknown)
                try check(s.inserter.targetTexts == ["old"] && s.inserter.restorations.last?.result == .restored && s.inserter.writes.count == 1)
            },
            .init("每会话指标首字与停止到插入按虚拟时钟派生") {
                let s = FakeSessionSystem(); s.holdAndRelease(); s.finish(); let m = try require(s.metrics.sessions.first)
                try check(m.firstCaptionLatency == 70 && m.stopToInsertion == 47 && m.stopToCopy == nil)
                try check(m.elapsed("stopIntent", "audioClosed") == 20 && m.elapsed("recognitionFrozen", "localFinished") == 5)
            },
            .init("成功取消失败指标都不含正文或剪贴板快照") {
                for outcome in 0..<3 {
                    let s = FakeSessionSystem(); s.transcriber.finalText = "敏感正文-987654"; s.clipboard.writeText("敏感剪贴板")
                    if outcome == 1 { s.start(); s.hotkeys.emit(.escape) }
                    else { if outcome == 2 { s.inserter.axResult = .unknown }; s.holdAndRelease() }
                    s.finish(); let encoded = try JSONEncoder().encode(s.metrics.sessions)
                    let json = String(decoding: encoded, as: UTF8.self)
                    try check(!json.contains("敏感正文") && !json.contains("987654") && !json.contains("敏感剪贴板") && !json.contains("Authorization"))
                    try check(s.metrics.sessions.count == 1)
                }
            },
            .init("模型只收到本次本地文本与软偏好，无音频或目标上下文") {
                var prefs = SessionPreferences(); prefs.polishEnabled = true
                var env = SessionEnvironment(); env.hasModelKey = true
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.holdAndRelease(); s.finish()
                try check(s.processor.modelRequests.count == 1 && s.processor.modelRequests[0].1 == "测试文本。" && s.processor.modelRequests[0].2 == false)
            },
            .init("五分钟服务器fake续接，最终仍关麦只交付一次") {
                var prefs = SessionPreferences(); prefs.appleServerConsent = true
                var env = SessionEnvironment(); env.supportsOnDevice = false
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.start(); s.clock.advance(to: 300_100)
                try check(s.coordinator.machine.state == .done && s.audio.active.isEmpty && s.transcriber.rotations.count == 6 && s.inserter.writes.count == 1)
                try check(s.metrics.sessions.first?.recognitionPolicy == .appleServerAllowed && s.metrics.sessions.first?.stopReason == .recordingLimit)
            }
        ]
        for result in [InsertionOutcome.unknown, .definiteFailure] {
            cases.append(.init(result == .unknown ? "paste未知也在500ms版本匹配恢复" : "paste确定失败后copy新版本不被旧timer覆盖") {
                let s = pasteSystem(); s.clipboard.writeText("old"); s.inserter.pasteResult = result
                s.holdAndRelease(); s.finish()
                if result == .unknown {
                    try check(s.coordinator.machine.state == .error && s.clipboard.text == "old" && s.inserter.restorations.last?.result == .restored)
                } else {
                    try check(s.coordinator.machine.state == .done && s.clipboard.text == "测试文本。" && s.inserter.restorations.last?.result == .skippedChanged)
                }
            })
        }
        return cases
    }
}
