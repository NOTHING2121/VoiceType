import Foundation
@testable import VoiceTypeCore

enum AuditCases {
    static func serverHarness() throws -> ReducerHarness {
        var prefs = SessionPreferences(); prefs.appleServerConsent = true
        var env = SessionEnvironment(); env.supportsOnDevice = false
        let h = ReducerHarness(preferences: prefs, environment: env); try h.start(); return h
    }
    static var all: [RegressionCase] {
        [
            .init("已润色但提交前开隐私，作废旧write并恢复本地文本") {
                let h = try ProcessingCases.modelHarness(); let model = try require(h.machine.context?.activeOperation)
                h.send(.response(model, .modelResult(text: "测试文本！", complete: true)), at: 500)
                let old = try h.prepareWrite(at: 510); h.send(.privacyChanged(true), at: 511); h.send(.commitWrite(old), at: 512)
                try check(h.machine.context?.deliveryText == "测试文本。" && h.machine.context?.writeCommitted == false && h.machine.context?.activeOperation != old)
                try check(h.machine.context?.metrics.modelPath == .skippedPrivacyMode)
            },
            .init("已排队的润色write在隐私切换后实际fake也不能写") {
                var prefs = SessionPreferences(); prefs.polishEnabled = true
                var env = SessionEnvironment(); env.hasModelKey = true
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.processor.modelResult = .success("测试文本！", complete: true)
                s.inserter.prepareDelay = 20; s.holdAndRelease(); s.clock.advance(to: 535)
                s.coordinator.autoRunEffects = false; s.clock.advance(to: 555)
                try check(s.coordinator.machine.context?.prepared == true)
                s.coordinator.send(.privacyChanged(true)); s.coordinator.autoRunEffects = true; s.coordinator.runEffects(); s.finish()
                try check(s.inserter.writes.count == 1 && s.inserter.targetTexts == ["测试文本。"] && s.metrics.sessions.first?.modelPath == .skippedPrivacyMode)
            },
            .init("隐私在已提交后不能回滚或再次交付") {
                let h = try ProcessingCases.modelHarness(); h.send(.response(try require(h.machine.context?.activeOperation), .modelResult(text: "测试文本！", complete: true)), at: 500)
                let op = try h.commit(at: 510); h.send(.privacyChanged(true), at: 511)
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 520)
                try check(h.machine.state == .done && h.prepareCount == 1 && h.machine.context?.metrics.modelPath == .polished)
            },
            .init("新段终局先到，旧段后到不得丢音频前半段") {
                let h = try serverHarness(); let first = try require(h.machine.context?.recognizerToken); h.tick(45_000)
                let second = try require(h.machine.context?.recognizerToken)
                h.send(.response(second, .segmentFinal(text: "后段", audioEnd: 45_900)), at: 45_900)
                h.send(.response(first, .segmentFinal(text: "前段", audioEnd: 45_000)), at: 45_910)
                h.send(.response(first, .segmentFinal(text: "重复", audioEnd: 45_000)), at: 45_920)
                h.send(.rightOptionUp, at: 46_000); h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 46_020); h.tick(46_500)
                try check(h.machine.context?.frozenText == "前段 后段")
            },
            .init("同任务片段乱序按音频端点排序而非回调顺序") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.response(speech, .segmentFinal(text: "后", audioEnd: 40)), at: 50)
                h.send(.response(speech, .segmentFinal(text: "前", audioEnd: 20)), at: 60)
                h.send(.rightOptionUp, at: 400); h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                h.send(.response(speech, .final("")), at: 430)
                try check(h.machine.context?.frozenText == "前 后")
            },
            .init("final等待关麦期间旧段纠正必须反映到冻结结果") {
                let h = try serverHarness(); let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .partial("前假")), at: 100); h.tick(45_000); let second = try require(h.machine.context?.recognizerToken)
                h.send(.response(second, .partial("后假")), at: 45_100); h.send(.rightOptionUp, at: 45_400)
                h.send(.response(second, .final("后真")), at: 45_410); h.send(.response(first, .final("前真")), at: 45_415)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 45_420)
                try check(h.machine.state == .processing && h.machine.context?.frozenText == "前真 后真" && h.machine.context?.metrics.recognitionSource == "final")
            },
            .init("关麦后仍等待未结束旧段但绝不超过500ms") {
                let h = try serverHarness(); let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .partial("旧假设")), at: 100); h.tick(45_000); let second = try require(h.machine.context?.recognizerToken)
                h.send(.rightOptionUp, at: 45_100); h.send(.response(second, .final("后真")), at: 45_110)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 45_120)
                try check(h.machine.state == .finalizing)
                h.send(.response(first, .final("前真")), at: 45_500)
                try check(h.machine.state == .processing && h.machine.context?.frozenText == "前真 后真")
            },
            .init("完整final替换当前任务已提交子片段，不重复拼接") {
                let h = ReducerHarness(); try h.start(); let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .segmentFinal(text: "第一", audioEnd: 20)), at: 20)
                h.send(.response(first, .partial("第一 第二")), at: 50); h.send(.response(first, .final("第一 第二")), at: 100)
                let next = try require(h.machine.context?.recognizerToken); h.send(.rightOptionUp, at: 400)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420); h.send(.response(next, .final("")), at: 430)
                try check(h.machine.context?.frozenText == "第一 第二")
            },
            .init("默认fake轮换不重放前45秒内容") {
                var prefs = SessionPreferences(); prefs.appleServerConsent = true
                var env = SessionEnvironment(); env.supportsOnDevice = false
                let s = FakeSessionSystem(preferences: prefs, environment: env); s.holdAndRelease(after: 46_000); s.finish()
                try check(s.inserter.targetTexts == ["测试文本。"] && s.transcriber.rotations.count == 1)
            },
            .init("fake分段独立脚本与乱序final完整走端到端") {
                var prefs = SessionPreferences(); prefs.appleServerConsent = true
                var env = SessionEnvironment(); env.supportsOnDevice = false
                let s = FakeSessionSystem(preferences: prefs, environment: env)
                s.transcriber.emissions = [.init(delay: 10, response: .partial("前假"))]; s.transcriber.finalText = "前真"; s.transcriber.finalDelay = 400
                s.transcriber.continuationSegments = [.init(emissions: [.init(delay: 10, response: .partial("后假"))], finalText: "后真", finalDelay: 1)]
                s.holdAndRelease(after: 45_050); s.clock.advance(to: 45_100); try check(s.coordinator.machine.state == .finalizing)
                s.finish(); try check(s.inserter.targetTexts == ["前真 后真"] && s.metrics.sessions.first?.recognitionSource == "final")
            },
            .init("重叠重放相同全局端点只提交一次") {
                let h = try serverHarness(); let first = try require(h.machine.context?.recognizerToken)
                h.send(.response(first, .segmentFinal(text: "仅一次", audioEnd: 100)), at: 100); h.tick(45_000)
                h.send(.response(try require(h.machine.context?.recognizerToken), .segmentFinal(text: "重复重放", audioEnd: 100)), at: 45_010)
                try check(h.machine.context?.committedSegments == ["仅一次"])
            },
            .init("fake复制确定失败必然没有修改剪贴板") {
                let clock = VirtualScheduler(), clipboard = FakeClipboard(); let inserter = FakeTextInserter(clock: clock, clipboard: clipboard)
                clipboard.writeText("original"); clipboard.writable = false; let version = clipboard.changeCount
                var result: InsertionOutcome?
                inserter.write(.init(session: 1, operation: 1), strategy: .copy, text: "new", callback: { _, response in if case .insertionResult(let outcome) = response { result = outcome } })
                clock.advance(by: 20)
                try check(result == .definiteFailure && clipboard.text == "original" && clipboard.changeCount == version)
            },
            .init("fake复制成功必然版本增加且回报verified") {
                let clock = VirtualScheduler(), clipboard = FakeClipboard(); let inserter = FakeTextInserter(clock: clock, clipboard: clipboard)
                var result: InsertionOutcome?
                inserter.write(.init(session: 1, operation: 1), strategy: .copy, text: "new", callback: { _, response in if case .insertionResult(let outcome) = response { result = outcome } })
                clock.advance(by: 20); try check(result == .verifiedSuccess && clipboard.text == "new" && clipboard.changeCount == 1)
            },
            .init("已收到完整final的旧partial不能再改当前假设") {
                let h = ReducerHarness(); try h.start(); let speech = try require(h.machine.context?.recognizerToken)
                h.send(.rightOptionUp, at: 400); h.send(.response(speech, .final("完整")), at: 410)
                h.send(.response(speech, .partial("旧partial")), at: 415)
                h.send(.response(try require(h.machine.context?.stopToken), .audioStopped), at: 420)
                try check(h.machine.context?.frozenText == "完整")
            }
        ]
    }
}
