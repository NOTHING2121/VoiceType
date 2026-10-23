import Foundation
@testable import VoiceTypeCore

enum ProcessingCases {
    static func modelHarness(text: String = "测试文本。", localAt: Milliseconds = 435) throws -> ReducerHarness {
        var prefs = SessionPreferences(); prefs.polishEnabled = true
        var env = SessionEnvironment(); env.hasModelKey = true
        let h = ReducerHarness(preferences: prefs, environment: env); try h.processing(text: text)
        h.send(.response(try require(h.machine.context?.activeOperation), .localProcessed(text)), at: localAt)
        return h
    }
    static var all: [RegressionCase] {
        var cases: [RegressionCase] = [
            .init("及时合格润色取胜") {
                let h = try modelHarness(); let model = try require(h.machine.context?.activeOperation)
                h.send(.response(model, .modelResult(text: "测试文本！", complete: true)), at: 500)
                try check(h.machine.state == .inserting && h.machine.context?.deliveryText == "测试文本！" && h.machine.context?.metrics.modelPath == .polished)
            },
            .init("650ms 模型超时立即回退本地，迟到结果无权写入") {
                let h = try modelHarness(); let model = try require(h.machine.context?.activeOperation)
                h.tick(1_085)
                try check(h.machine.state == .inserting && h.machine.context?.metrics.modelPath == .timeout)
                h.send(.response(model, .modelResult(text: "迟到替换", complete: true)), at: 1_086)
                try check(h.machine.context?.deliveryText == "测试文本。" && h.modelCount == 1)
            },
            .init("模型恰在截止点返回，超时稳定获胜") {
                let h = try modelHarness(); let model = try require(h.machine.context?.activeOperation)
                h.send(.response(model, .modelResult(text: "测试文本！", complete: true)), at: 1_085)
                try check(h.machine.context?.metrics.modelPath == .timeout && h.machine.context?.deliveryText == "测试文本。")
            },
            .init("stop+1180ms 收紧模型窗口") {
                let h = try modelHarness(localAt: 1_300)
                try check(h.machine.context?.deadlines[.model]?.deadline == 1_580)
                h.tick(1_580); try check(h.machine.context?.metrics.modelPath == .timeout)
            },
            .init("没有剩余绝对预算不发模型请求") {
                let h = try modelHarness(localAt: 1_580)
                try check(h.machine.state == .inserting && h.modelCount == 0 && h.machine.context?.metrics.modelPath == .skippedDeadline)
            },
            .init("模型请求失败不是会话错误") {
                let h = try modelHarness(); h.send(.response(try require(h.machine.context?.activeOperation), .modelFailed), at: 500)
                try check(h.machine.state == .inserting && h.machine.context?.metrics.modelPath == .requestFailed && h.modelCount == 1)
            },
            .init("取消模型后清空正文并拒绝旧回复") {
                let h = try modelHarness(); let model = try require(h.machine.context?.activeOperation)
                h.send(.escape, at: 500); h.send(.response(model, .modelResult(text: "测试文本！", complete: true)), at: 510)
                try check(h.machine.state == .cancelled && h.machine.context?.localText == "" && h.machine.context?.recoveryText == "")
            },
            .init("端侧处理中开启隐私，取消模型但完成本地交付") {
                let h = try modelHarness(); h.send(.privacyChanged(true), at: 500)
                try check(h.machine.state == .inserting && h.machine.context?.metrics.modelPath == .skippedPrivacyMode && h.machine.context?.deliveryText == "测试文本。")
            },
            .init("本地规则异常和空清洗结果均回原文") {
                for response in [ModuleResponse.localFailed, .localProcessed("")] {
                    let h = ReducerHarness(); try h.processing(text: "原文")
                    h.send(.response(try require(h.machine.context?.activeOperation), response), at: 435)
                    try check(h.machine.state == .inserting && h.machine.context?.deliveryText == "原文")
                }
            },
            .init("本地操作已过期不能重启处理") {
                let h = ReducerHarness(); try h.processing(); let local = try require(h.machine.context?.activeOperation)
                h.send(.response(local, .localProcessed("文本")), at: 435); let prepared = h.machine.context?.activeOperation
                h.send(.response(local, .localProcessed("旧处理")), at: 436)
                try check(h.machine.context?.activeOperation == prepared && h.machine.context?.deliveryText == "文本")
            },
            .init("AX 不可用直接走 paste，无提交副作用") {
                let h = ReducerHarness(); try h.inserting()
                h.send(.response(try require(h.machine.context?.activeOperation), .insertionPrepared(available: false)), at: 440)
                try check(h.machine.context?.strategy == .paste && h.machine.context?.writeCommitted == false)
            },
            .init("AX 确定失败才允许 paste，paste 确定失败才 copy") {
                let h = ReducerHarness(); try h.inserting(); let ax = try h.commit()
                h.send(.response(ax, .insertionResult(.definiteFailure)), at: 450)
                try check(h.machine.context?.strategy == .paste)
                let paste = try h.commit(at: 455); h.send(.response(paste, .insertionResult(.definiteFailure)), at: 460)
                try check(h.machine.context?.strategy == .copy)
                let copy = try h.commit(at: 465); h.send(.response(copy, .insertionResult(.verifiedSuccess)), at: 470)
                try check(h.machine.state == .done && h.machine.context?.metrics.deliveryPath == .copiedOnly)
            },
            .init("AX 未知结果终止链，无自动 paste 或 copy") {
                let h = ReducerHarness(); try h.inserting(); let ax = try h.commit()
                h.send(.response(ax, .insertionResult(.unknown)), at: 450)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .insertionUnknown && h.prepareCount == 1)
            },
            .init("paste 未知结果也不能复制重发") {
                let h = ReducerHarness(); try h.inserting()
                h.send(.response(try require(h.machine.context?.activeOperation), .insertionPrepared(available: false)), at: 437)
                let paste = try h.commit(); h.send(.response(paste, .insertionResult(.unknown)), at: 450)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .insertionUnknown && h.prepareCount == 2)
            },
            .init("用户关闭 paste 时 AX 不可用改 copy") {
                var prefs = SessionPreferences(); prefs.allowPaste = false
                let h = ReducerHarness(preferences: prefs); try h.inserting()
                h.send(.response(try require(h.machine.context?.activeOperation), .insertionPrepared(available: false)), at: 440)
                try check(h.machine.context?.strategy == .copy)
            },
            .init("全部交付不可用为 error") {
                let h = ReducerHarness(); try h.inserting()
                for time: Milliseconds in [440, 445, 450] { h.send(.response(try require(h.machine.context?.activeOperation), .insertionPrepared(available: false)), at: time) }
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .deliveryFailed)
            },
            .init("写入前取消连已准备的效果也必须无效") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.prepareWrite()
                h.send(.escape, at: 441); h.send(.commitWrite(op), at: 442)
                try check(h.machine.state == .cancelled && h.machine.context?.writeCommitted == false)
            },
            .init("提交后 Esc 不伪装 cancelled，等待唯一验证结果") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit()
                h.send(.escape, at: 442); try check(h.machine.state == .inserting)
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                try check(h.machine.state == .done && h.machine.context?.metrics.cancelTooLate == true && h.prepareCount == 1)
            },
            .init("提交后取消但无确认，到期 insertionUnknown") {
                let h = ReducerHarness(); try h.inserting(); _ = try h.commit(); h.send(.escape, at: 442); h.tick(615)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .insertionUnknown)
            },
            .init("插入准备超时尚未提交，记录 deliveryFailed") {
                let h = ReducerHarness(); try h.inserting(); h.tick(615)
                try check(h.machine.state == .error && h.machine.context?.metrics.failure == .deliveryFailed)
            },
            .init("整条交付链180ms 截止不随降级重置") {
                let h = ReducerHarness(); try h.inserting(); let deadline = h.machine.context?.deadlines[.insertion]?.deadline
                h.send(.response(try require(h.machine.context?.activeOperation), .insertionPrepared(available: false)), at: 500)
                try check(h.machine.context?.deadlines[.insertion]?.deadline == deadline)
            },
            .init("准备AX后切应用废弃旧op并复制") {
                let h = ReducerHarness(); try h.inserting(); let ax = try h.prepareWrite()
                h.send(.applicationChanged(200), at: 441); let copy = h.machine.context?.activeOperation
                h.send(.commitWrite(ax), at: 442)
                try check(h.machine.context?.strategy == .copy && h.machine.context?.activeOperation == copy && h.machine.context?.writeCommitted == false)
            },
            .init("提交前最后环境PID检查仍能改copy") {
                let h = ReducerHarness(); try h.inserting(); let ax = try h.prepareWrite()
                var env = h.machine.environment; env.foregroundPID = 200
                h.send(.environmentChanged(env), at: 441); h.send(.commitWrite(ax), at: 442)
                try check(h.machine.context?.strategy == .copy && h.machine.context?.writeCommitted == false)
            },
            .init("重复交付结果不能二次指标或二次交付") {
                let h = ReducerHarness(); try h.inserting(); let op = try h.commit()
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 450)
                h.send(.response(op, .insertionResult(.verifiedSuccess)), at: 451)
                try check(h.machine.state == .done && h.allEffects.filter { if case .recordMetrics = $0 { return true }; return false }.count == 1)
            }
        ]
        let invalidOutputs: [(String, String, Bool)] = [
            ("空回复", "", true), ("截断", "测试文本。", false), ("代码围栏", "```测试文本```", true),
            ("说明文", "以下是润色后的测试文本。", true), ("数字改写", "明天2027年开会。", true),
            ("删除未授权句首", "开会。", true), ("删除否定", "可以开会。", true)
        ]
        for (name, output, complete) in invalidOutputs {
            cases.append(.init("模型输出拒绝：\(name)") {
                let source = name == "数字改写" ? "明天2026年开会。" : name == "删除未授权句首" ? "那个，开会。" : name == "删除否定" ? "不可以开会。" : "测试文本。"
                let h = try modelHarness(text: source)
                h.send(.response(try require(h.machine.context?.activeOperation), .modelResult(text: output, complete: complete)), at: 500)
                try check(h.machine.state == .inserting && h.machine.context?.metrics.modelPath == .invalidOutput && h.machine.context?.deliveryText == source)
            })
        }
        for path in [ModelPath.off, .skippedPrivacyMode, .skippedNoKey, .skippedOffline, .skippedLongText] {
            cases.append(.init("模型跳过矩阵：\(path.rawValue)") {
                var prefs = SessionPreferences(); prefs.polishEnabled = path != .off; prefs.privacyMode = path == .skippedPrivacyMode
                var env = SessionEnvironment(); env.hasModelKey = path != .skippedNoKey; env.online = path != .skippedOffline
                let text = path == .skippedLongText ? String(repeating: "长", count: 601) : "测试文本。"
                let h = ReducerHarness(preferences: prefs, environment: env); try h.processing(text: text)
                h.send(.response(try require(h.machine.context?.activeOperation), .localProcessed(text)), at: 435)
                try check(h.machine.state == .inserting && h.modelCount == 0 && h.machine.context?.metrics.modelPath == path && h.machine.context?.deliveryText == text)
            })
        }
        return cases
    }
}
