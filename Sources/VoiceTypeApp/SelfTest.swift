import AppKit
import VoiceTypeCore

/// `VoiceType --hud-selftest <output.json>`: no permissions, microphone, AX, or clipboard access.
enum HUDFocusSelfTest {
    static func outputPath(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--hud-selftest"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func snapshot(_ hud: HUDController) -> [String: Any] {
        let front = NSWorkspace.shared.frontmostApplication
        return ["frontmostPID": front?.processIdentifier ?? -1,
                "frontmostBundleID": front?.bundleIdentifier ?? "",
                "voiceTypeActive": NSApp.isActive,
                "voiceTypeKeyWindow": NSApp.keyWindow != nil,
                "hudVisible": hud.panel.isVisible,
                "hudIsKey": hud.panel.isKeyWindow,
                "hudIsMain": hud.panel.isMainWindow,
                "hudCanBecomeKey": hud.panel.canBecomeKey]
    }

    static func run(output: String) {
        let hud = HUDController()
        var samples: [[String: Any]] = [snapshot(hud)]
        let steps: [(TimeInterval, () -> Void)] = [
            (0.1, { hud.update(state: .recording, message: "正在聆听 · 端侧识别", caption: "") }),
            (0.4, { hud.update(state: .recording, message: "正在聆听 · 端侧识别", caption: "自检：这是实时字幕") }),
            (0.7, { hud.update(state: .finalizing, message: "正在识别…", caption: "自检：这是实时字幕。") }),
            (1.0, { hud.update(state: .done, message: "已插入", caption: "") }),
        ]
        for (delay, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action(); samples.append(snapshot(hud)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            samples.append(snapshot(hud))
            let first = samples[0]
            let shown = samples.dropFirst().filter { ($0["hudVisible"] as? Bool) == true }
            let focusKept = samples.allSatisfy {
                ($0["frontmostPID"] as? Int32) == (first["frontmostPID"] as? Int32)
                    && ($0["voiceTypeActive"] as? Bool) == false && ($0["hudIsKey"] as? Bool) == false
                    && ($0["voiceTypeKeyWindow"] as? Bool) == false && ($0["hudIsMain"] as? Bool) == false
            }
            let result: [String: Any] = ["passed": focusKept && !shown.isEmpty, "samplesWithHUDVisible": shown.count, "samples": samples]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output))
            }
            NSApp.terminate(nil)
        }
    }
}
