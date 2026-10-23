import Foundation
@testable import VoiceTypeCore

enum TextCases {
    static var all: [RegressionCase] {
        [
            .init("基础空白换行标点清洗且幂等") {
                let processor = TextProcessor(); let input = "  hello   world\r\n你好  ，，，世界！！  "
                let output = processor.clean(input)
                try check(output == "hello world\n你好，世界！")
                try check(processor.clean(output) == output)
            },
            .init("默认不删除孤立语气词或句首口头语") {
                let input = "呃，那个，就是，明天开会。"
                try check(TextProcessor().clean(input) == input)
            },
            .init("跳过或继续引导绝不推断opt-in") {
                var selection = CleanupSelection(); selection.skipOrContinue()
                try check(selection.preferences.isolatedFillers == .unset && selection.preferences.sentencePrefixes == .unset)
                var settings = SessionPreferences(); settings.polishEnabled = true
                try check(settings.cleanup == .init())
            },
            .init("两项清洗可独立开启并分别撤回") {
                var selection = CleanupSelection(); selection.chooseIsolatedFillers(.remove)
                try check(TextProcessor().clean("呃，明天开会。", preferences: selection.preferences) == "明天开会。")
                try check(TextProcessor().clean("那个，明天开会。", preferences: selection.preferences) == "那个，明天开会。")
                selection.chooseIsolatedFillers(.keep); selection.chooseSentencePrefixes(.remove)
                try check(TextProcessor().clean("呃，明天开会。", preferences: selection.preferences) == "呃，明天开会。")
                try check(TextProcessor().clean("那个，明天开会。", preferences: selection.preferences) == "明天开会。")
            },
            .init("独立选择可JSON持久化并恢复") {
                var original = CleanupSelection(); original.chooseIsolatedFillers(.keep); original.chooseSentencePrefixes(.remove)
                let restored = try JSONDecoder().decode(CleanupSelection.self, from: JSONEncoder().encode(original))
                try check(restored == original)
            },
            .init("启用后保留指代词、肯定回应与意义不明情况") {
                var preferences = CleanupPreferences(); preferences.isolatedFillers = .remove; preferences.sentencePrefixes = .remove
                for text in ["那个方案可行。", "就是这样。", "嗯。", "然后会怎么样？", "姓名：嗯嗯"] {
                    try check(TextProcessor().clean(text, preferences: preferences) == text)
                }
            },
            .init("引用与代码中的词空白不能被清洗规则破坏") {
                var preferences = CleanupPreferences(); preferences.isolatedFillers = .remove; preferences.sentencePrefixes = .remove
                for text in ["他说“那个，别删除”。", "`let  那个 = 12.50`", "\"呃，保留\""] {
                    try check(TextProcessor().clean(text, preferences: preferences) == text)
                }
            },
            .init("两项增强组合仍幂等") {
                var preferences = CleanupPreferences(); preferences.isolatedFillers = .remove; preferences.sentencePrefixes = .remove
                let processor = TextProcessor(); let once = processor.clean("呃，那个，就是，明天开会。", preferences: preferences)
                try check(once == "明天开会。" && processor.clean(once, preferences: preferences) == once)
            },
            .init("数字日期URL姓名Unicode与否定词保持") {
                let input = "张三不在2026-10-23支付12.50元；访问 https://example.com/a?q=1；你好𠮷。"
                try check(TextProcessor().clean(input) == input)
                try check(TextProcessor.isValidModelOutput(input, original: input, preferences: .init(), complete: true))
            },
            .init("模型不得改写数字与URL") {
                let input = "支付12.50元，访问 https://example.com/a"
                try check(!TextProcessor.isValidModelOutput("支付12.60元，访问 https://example.com/a", original: input, preferences: .init(), complete: true))
                try check(!TextProcessor.isValidModelOutput("支付12.50元，访问 https://other.com/a", original: input, preferences: .init(), complete: true))
            },
            .init("模型不能删除关闭规则保护的语气词与句首") {
                try check(!TextProcessor.isValidModelOutput("明天开会。", original: "那个，明天开会。", preferences: .init(), complete: true))
                try check(!TextProcessor.isValidModelOutput("明天开会。", original: "呃，明天开会。", preferences: .init(), complete: true))
            },
            .init("模型不能删除否定词或明显摘要说明") {
                try check(!TextProcessor.isValidModelOutput("可以开会。", original: "不可以开会。", preferences: .init(), complete: true))
                try check(!TextProcessor.isValidModelOutput("Summary: a meeting", original: "明天下午两点开会。", preferences: .init(), complete: true))
            },
            .init("模型空白、截断、围栏、异常长度均拒绝") {
                for output in ["", " ", "```正文```", String(repeating: "x", count: 100)] {
                    try check(!TextProcessor.isValidModelOutput(output, original: "正文", preferences: .init(), complete: true))
                }
                try check(!TextProcessor.isValidModelOutput("正文", original: "正文", preferences: .init(), complete: false))
            },
            .init("600字符精确边界仍允许模型，601字符跳过") {
                let h = try ProcessingCases.modelHarness(text: String(repeating: "字", count: 600))
                try check(h.modelCount == 1)
                let g = try ProcessingCases.modelHarness(text: String(repeating: "字", count: 601))
                try check(g.modelCount == 0 && g.machine.context?.metrics.modelPath == .skippedLongText)
            },
            .init("无声首字指标为nil，不伪造零延迟") {
                let h = ReducerHarness(); try h.start(); h.send(.escape, at: 100)
                try check(h.machine.context?.metrics.firstCaptionLatency == nil && h.machine.context?.metrics.stopToInsertion == nil)
            }
        ]
    }
}
