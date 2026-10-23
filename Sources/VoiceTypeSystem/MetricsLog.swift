import Foundation
import VoiceTypeCore

/// One JSON line per session (and per clipboard restore). Metadata only: no transcript, clipboard, or keys.
public final class MetricsLog: MetricsRecording {
    public let url: URL
    public var locale: () -> String = { "" }
    public var onRecord: (([String: Any]) -> Void)?
    private let queue = DispatchQueue(label: "VoiceType.metrics")

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType", isDirectory: true)
    }

    public init(directory: URL = MetricsLog.defaultDirectory) {
        url = directory.appendingPathComponent("metrics.jsonl")
    }

    public func record(_ metrics: SessionMetrics) {
        var line = Self.summary(metrics)
        line["event"] = "session"
        line["locale"] = locale()
        append(line)
    }

    public func recordClipboard(_ result: PasteboardRestoreOutcome) {
        append(["event": "clipboardRestore", "result": result.rawValue])
    }

    public static func summary(_ m: SessionMetrics) -> [String: Any] {
        var line: [String: Any] = ["sessionID": m.sessionID, "modelPath": m.modelPath.rawValue,
                                   "appChanged": m.appChanged, "cancelTooLate": m.cancelTooLate, "preferZDR": m.preferZDR,
                                   "timestampsMs": m.timestamps]
        line["terminalState"] = m.terminalState?.rawValue
        line["recognitionPolicy"] = m.recognitionPolicy?.rawValue
        line["recognitionSource"] = m.recognitionSource
        line["deliveryPath"] = m.deliveryPath?.rawValue
        line["stopReason"] = m.stopReason?.rawValue
        line["cancellation"] = m.cancellation?.rawValue
        line["failure"] = m.failure?.rawValue
        let derived: [(String, Milliseconds?)] = [
            ("keyDownToAudioMs", m.elapsed("keyDown", "audioStarted")),
            ("firstCaptionLatencyMs", m.firstCaptionLatency),
            ("keyDownToFirstCaptionMs", m.elapsed("keyDown", "firstCaption")),
            ("stopToAudioClosedMs", m.elapsed("stopIntent", "audioClosed")),
            ("stopToRecognitionFrozenMs", m.elapsed("stopIntent", "recognitionFrozen")),
            ("localCleanupMs", m.elapsed("recognitionFrozen", "localFinished")),
            ("insertionMs", m.elapsed("insertionStarted", "delivered")),
            ("stopToInsertionMs", m.stopToInsertion),
            ("stopToCopyMs", m.stopToCopy),
            ("stopToTerminalMs", m.elapsed("stopIntent", "terminal")),
        ]
        for (key, value) in derived { if let value = value { line[key] = value } }
        return line
    }

    private func append(_ input: [String: Any]) {
        var line = input
        line["wallTime"] = ISO8601DateFormatter().string(from: Date())
        onRecord?(line)
        let url = self.url
        queue.async {
            guard JSONSerialization.isValidJSONObject(line),
                  var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
