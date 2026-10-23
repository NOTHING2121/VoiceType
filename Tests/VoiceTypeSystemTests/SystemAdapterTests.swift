import AppKit
import AVFoundation
import Foundation
@testable import VoiceTypeCore
@testable import VoiceTypeSystem

struct SystemCheckFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String = "condition failed", line: UInt = #line) throws {
    if !condition() { throw SystemCheckFailure(description: "line \(line): \(message)") }
}
struct SystemCase: CustomStringConvertible, @unchecked Sendable {
    let name: String
    let body: () throws -> Void
    init(_ name: String, _ body: @escaping () throws -> Void) { self.name = name; self.body = body }
    var description: String { name }
}

/// Isolated named pasteboard: the user's general clipboard is never touched by tests.
private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("VoiceTypeTests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    try body(pasteboard)
}

private final class ManualDelay {
    var pending: [() -> Void] = []
    var delays: [TimeInterval] = []
    func schedule(_ seconds: TimeInterval, _ work: @escaping () -> Void) { delays.append(seconds); pending.append(work) }
    func fireAll() { let work = pending; pending = []; work.forEach { $0() } }
}

private let rtf = NSPasteboard.PasteboardType.rtf
private let custom = NSPasteboard.PasteboardType("com.voicetype.tests.custom")

private func seed(_ pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let first = NSPasteboardItem()
    first.setString("原剪贴板", forType: .string)
    first.setData(Data("{\\rtf1 原}".utf8), forType: rtf)
    let second = NSPasteboardItem()
    second.setData(Data([0, 1, 2, 255]), forType: custom)
    _ = pasteboard.writeObjects([first, second])
}

private func sine(frames: AVAudioFrameCount, rate: Double, channels: AVAudioChannelCount, amplitude: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(rate)) }
    }
    return buffer
}

enum SystemAdapterCases {
    static let all: [SystemCase] = clipboard + audio + other + HotkeyTapCases.all

    static let clipboard: [SystemCase] = [
        SystemCase("多item多类型快照可完整恢复") {
            try withPasteboard { pb in
                seed(pb)
                let snapshot = try PasteboardSnapshot.capture(pb).map { $0 } ?? { throw SystemCheckFailure(description: "capture failed") }()
                pb.clearContents(); pb.setString("别的", forType: .string)
                try expect(snapshot.restore(to: pb))
                try expect(pb.pasteboardItems?.count == 2)
                try expect(pb.pasteboardItems?[0].string(forType: .string) == "原剪贴板")
                try expect(pb.pasteboardItems?[0].data(forType: rtf) == Data("{\\rtf1 原}".utf8))
                try expect(pb.pasteboardItems?[1].data(forType: custom) == Data([0, 1, 2, 255]))
            }
        },
        SystemCase("原剪贴板为空时恢复为空") {
            try withPasteboard { pb in
                pb.clearContents()
                let snapshot = PasteboardSnapshot.capture(pb)
                try expect(snapshot?.items.isEmpty == true)
                pb.setString("临时", forType: .string)
                try expect(snapshot?.restore(to: pb) == true && (pb.pasteboardItems ?? []).isEmpty)
            }
        },
        SystemCase("粘贴写入带临时标记，500ms后版本匹配恢复原内容") {
            try withPasteboard { pb in
                seed(pb)
                let delay = ManualDelay(); var results: [PasteboardRestoreOutcome] = []
                let manager = ClipboardManager(pasteboard: pb, delay: delay.schedule); manager.onRestore = { results.append($0) }
                let original = try PasteboardSnapshot.capture(pb).map { $0 } ?? { throw SystemCheckFailure(description: "capture") }()
                let owned = try manager.writeForPaste("听写文本").map { $0 } ?? { throw SystemCheckFailure(description: "write") }()
                try expect(pb.string(forType: .string) == "听写文本")
                try expect(ClipboardManager.transientMarkers.allSatisfy { pb.pasteboardItems?.first?.types.contains($0) == true })
                manager.scheduleRestore(original, owned: owned)
                try expect(delay.delays == [0.5] && pb.string(forType: .string) == "听写文本", "到期前不恢复")
                delay.fireAll()
                try expect(results == [.restored] && pb.string(forType: .string) == "原剪贴板" && pb.pasteboardItems?.count == 2)
            }
        },
        SystemCase("500ms内剪贴板被改写则完全不动") {
            try withPasteboard { pb in
                seed(pb)
                let delay = ManualDelay(); var results: [PasteboardRestoreOutcome] = []
                let manager = ClipboardManager(pasteboard: pb, delay: delay.schedule); manager.onRestore = { results.append($0) }
                let original = PasteboardSnapshot.capture(pb)!
                let owned = manager.writeForPaste("听写文本")!
                manager.scheduleRestore(original, owned: owned)
                pb.clearContents(); pb.setString("用户新复制", forType: .string)
                delay.fireAll()
                try expect(results == [.skippedChanged] && pb.string(forType: .string) == "用户新复制")
            }
        },
        SystemCase("连续粘贴时第二次备份沿用真正的原剪贴板") {
            try withPasteboard { pb in
                seed(pb)
                let delay = ManualDelay(); var results: [PasteboardRestoreOutcome] = []
                let manager = ClipboardManager(pasteboard: pb, delay: delay.schedule); manager.onRestore = { results.append($0) }
                let firstOriginal = manager.captureOriginal()!
                manager.scheduleRestore(firstOriginal, owned: manager.writeForPaste("第一句")!)
                let secondOriginal = manager.captureOriginal()!
                try expect(secondOriginal == firstOriginal, "第二次不能把第一句当成原内容")
                manager.scheduleRestore(secondOriginal, owned: manager.writeForPaste("第二句")!)
                delay.fireAll()
                try expect(results == [.superseded, .restored] && pb.string(forType: .string) == "原剪贴板")
            }
        },
        SystemCase("复制并提示写入后不安排恢复，且使旧恢复跳过") {
            try withPasteboard { pb in
                seed(pb)
                let delay = ManualDelay(); var results: [PasteboardRestoreOutcome] = []
                let manager = ClipboardManager(pasteboard: pb, delay: delay.schedule); manager.onRestore = { results.append($0) }
                manager.scheduleRestore(manager.captureOriginal()!, owned: manager.writeForPaste("粘贴文本")!)
                try expect(manager.writeForManualPaste("复制文本") && delay.delays.count == 1)
                delay.fireAll()
                try expect(results == [.skippedChanged] && pb.string(forType: .string) == "复制文本")
            }
        },
    ]

    static let audio: [SystemCase] = [
        SystemCase("48kHz双声道转换为16kHz单声道") {
            let input = sine(frames: 4800, rate: 48_000, channels: 2, amplitude: 0.5)
            let converter = AVAudioConverter(from: input.format, to: AudioFormatting.speechFormat)!
            var total: AVAudioFrameCount = 0
            for _ in 0..<5 { total += AudioFormatting.convert(input, using: converter)?.frameLength ?? 0 }
            let out = AudioFormatting.convert(input, using: converter)!
            try expect(out.format.sampleRate == 16_000 && out.format.channelCount == 1)
            // 6×4800@48k = 9600@16k; the resampler's filter keeps a short tail (<30ms = 480 frames) in flight.
            let produced = Int(total + out.frameLength)
            try expect(produced <= 9_600 && 9_600 - produced < 480, "got \(produced) frames")
        },
        SystemCase("44.1kHz单声道同样可转换") {
            let input = sine(frames: 4410, rate: 44_100, channels: 1, amplitude: 0.3)
            let converter = AVAudioConverter(from: input.format, to: AudioFormatting.speechFormat)!
            let out = AudioFormatting.convert(input, using: converter)
            try expect(out != nil && out!.format.sampleRate == 16_000)
        },
        SystemCase("RMS分贝计算") {
            let loud = AudioFormatting.rmsDecibels(sine(frames: 1600, rate: 16_000, channels: 1, amplitude: 0.5))
            try expect(abs(loud - (-9.03)) < 0.3, "0.5正弦≈-9dBFS, got \(loud)")
            try expect(AudioFormatting.rmsDecibels(sine(frames: 1600, rate: 16_000, channels: 1, amplitude: 0)) == -160)
        },
        SystemCase("声音检测需要连续两帧超过阈值且只报告一次") {
            let vad = VoiceActivityDetector()
            let silent = sine(frames: 320, rate: 16_000, channels: 1, amplitude: 0.001)
            let voice = sine(frames: 320, rate: 16_000, channels: 1, amplitude: 0.1)
            try expect(!vad.process(silent) && !vad.process(voice) && !vad.process(silent), "单帧尖峰不算")
            try expect(!vad.process(voice) && vad.process(voice) && !vad.process(voice))
        },
    ]

    static let other: [SystemCase] = [
        SystemCase("指标行只含元数据与派生延迟，不含正文") {
            var metrics = SessionMetrics(sessionID: 7)
            metrics.timestamps = ["keyDown": 0, "audioStarted": 40, "firstVoice": 300, "firstCaption": 520, "stopIntent": 2_000,
                                  "audioClosed": 2_020, "recognitionFrozen": 2_200, "localFinished": 2_201, "insertionStarted": 2_201, "delivered": 2_260, "terminal": 2_260]
            metrics.deliveryPath = .insertedAX; metrics.terminalState = .done; metrics.recognitionPolicy = .onDevice; metrics.recognitionSource = "final"
            let line = MetricsLog.summary(metrics)
            try expect(line["firstCaptionLatencyMs"] as? Milliseconds == 220 && line["stopToInsertionMs"] as? Milliseconds == 260)
            try expect(line["keyDownToAudioMs"] as? Milliseconds == 40 && line["insertionMs"] as? Milliseconds == 59)
            try expect(JSONSerialization.isValidJSONObject(line))
            let json = String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8) ?? ""
            for forbidden in ["text", "caption", "clipboard", "Authorization", "apiKey"] { try expect(!json.contains(forbidden), forbidden) }
        },
        SystemCase("无语音错误映射为空final，其他错误为识别失败") {
            try expect(SpeechTranscriber.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
            try expect(!SpeechTranscriber.isNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 216)))
        },
        SystemCase("实时调度器时间单调") {
            let scheduler = LiveScheduler(); let a = scheduler.now; let b = scheduler.now
            try expect(a >= 0 && b >= a)
        },
    ]
}

#if compiler(>=6.0) && canImport(Testing)
import Testing

@Suite("VoiceType system adapters", .serialized)
struct VoiceTypeSystemTests {
    @Test("真实系统适配器", arguments: SystemAdapterCases.all)
    @MainActor
    func adapters(_ scenario: SystemCase) throws { try scenario.body() }
}
#elseif canImport(XCTest)
import XCTest

final class VoiceTypeSystemTests: XCTestCase {
    func testAdapters() throws { for scenario in SystemAdapterCases.all { try scenario.body() } }
}
#endif
