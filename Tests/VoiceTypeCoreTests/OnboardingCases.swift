import Foundation
@testable import VoiceTypeCore

enum OnboardingCases {
    static let all: [RegressionCase] = [
        .init("真实reducer终态清空deliveryText后仍可确认练习插入") {
            let s = FakeSessionSystem()
            var p = OnboardingProgress(); p.shortcutDown(eligible: true); p.shortcutUp()
            s.holdAndRelease()
            let id = try require(s.coordinator.machine.context?.id)
            p.beginTrial(session: id, focused: true)
            s.finish()
            let machine = s.coordinator.machine
            let context = try require(machine.context)
            try check(machine.state == .done && context.deliveryText.isEmpty && !context.recoveryText.isEmpty)
            let matches = OnboardingProgress.matchesInsertion(before: "", location: 0, length: 0,
                after: "测试文本。", deliveredText: context.recoveryText)
            p.finishTrial(session: id, state: machine.state, delivery: context.metrics.deliveryPath,
                          contentChanged: matches, appChanged: context.appChanged)
            try check(p.canComplete)
        },
        .init("练习结果验证处理UTF16选区且拒绝不一致或越界") {
            try check(OnboardingProgress.matchesInsertion(before: "👍旧文", location: 2, length: 2, after: "👍新文", deliveredText: "新文"))
            try check(!OnboardingProgress.matchesInsertion(before: "", location: 1, length: 0, after: "新文", deliveredText: "新文"))
            try check(!OnboardingProgress.matchesInsertion(before: "", location: 0, length: 0, after: "手动输入", deliveredText: "新文"))
            try check(!OnboardingProgress.matchesInsertion(before: "原文", location: 0, length: 2, after: "原文", deliveredText: "原文"))
        },
        .init("引导不能因打开或导航直接完成") {
            let p = OnboardingProgress()
            try check(!p.shortcutVerified && !p.trialSucceeded && !p.canComplete)
        },
        .init("快捷键必须合法按下并松开") {
            var p = OnboardingProgress()
            p.shortcutUp(); try check(!p.shortcutVerified)
            p.shortcutDown(eligible: false); p.shortcutUp(); try check(!p.shortcutVerified)
            p.shortcutDown(eligible: true); try check(!p.shortcutVerified)
            p.shortcutUp(); try check(p.shortcutVerified && !p.canComplete)
        },
        .init("组合键或失焦取消快捷键练习") {
            var p = OnboardingProgress()
            p.shortcutDown(eligible: true); p.cancelShortcut(); p.shortcutUp()
            try check(!p.shortcutVerified)
        },
        .init("试用必须来自已验证快捷键且聚焦练习框") {
            for shortcut in [false, true] {
                for focused in [false, true] {
                    var p = OnboardingProgress()
                    if shortcut { p.shortcutDown(eligible: true); p.shortcutUp() }
                    p.beginTrial(session: 1, focused: focused)
                    p.finishTrial(session: 1, state: .done, delivery: .insertedAX, contentChanged: true, appChanged: false)
                    try check(p.canComplete == (shortcut && focused))
                }
            }
        },
        .init("输入变化不能代替真实听写成功") {
            for state in [SessionState.idle, .recording, .error, .cancelled] {
                var p = OnboardingProgress(); p.shortcutDown(eligible: true); p.shortcutUp()
                p.beginTrial(session: 1, focused: true)
                p.finishTrial(session: 1, state: state, delivery: .insertedAX, contentChanged: true, appChanged: false)
                try check(!p.canComplete)
            }
        },
        .init("复制未写入换应用和过期结果都不能通过试用") {
            for variant in 0..<4 {
                var p = OnboardingProgress(); p.shortcutDown(eligible: true); p.shortcutUp()
                p.beginTrial(session: 2, focused: true)
                p.finishTrial(session: variant == 0 ? 1 : 2, state: .done,
                              delivery: variant == 1 ? .copiedOnly : .insertedAX,
                              contentChanged: variant != 2, appChanged: variant == 3)
                try check(!p.canComplete)
            }
        },
        .init("AX和粘贴真实成功均可通过，重试清除旧成功") {
            for delivery in [DeliveryPath.insertedAX, .insertedPaste] {
                var p = OnboardingProgress(); p.shortcutDown(eligible: true); p.shortcutUp()
                p.beginTrial(session: 1, focused: true)
                p.finishTrial(session: 1, state: .done, delivery: delivery, contentChanged: true, appChanged: false)
                try check(p.canComplete)
                p.beginTrial(session: 2, focused: true); try check(!p.canComplete)
                p.finishTrial(session: 1, state: .done, delivery: delivery, contentChanged: true, appChanged: false)
                try check(!p.canComplete)
            }
        },
        .init("重复终态通知不撤销已验证的试用结果") {
            var p = OnboardingProgress(); p.shortcutDown(eligible: true); p.shortcutUp()
            p.beginTrial(session: 1, focused: true)
            p.finishTrial(session: 1, state: .done, delivery: .insertedAX, contentChanged: true, appChanged: false)
            p.finishTrial(session: 1, state: .done, delivery: nil, contentChanged: false, appChanged: true)
            try check(p.canComplete)
        },
    ]
}
