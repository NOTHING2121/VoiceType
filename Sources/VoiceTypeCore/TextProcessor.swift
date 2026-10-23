import Foundation

public struct TextProcessor {
    public init() {}
    /// No LLM calls. Optional destructive rules require an explicit .remove choice.
    public func clean(_ input: String, preferences: CleanupPreferences = .init()) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Formatting inside quotes/code is not safely inferable: keep it intact.
        if text.contains("`") || text.contains("\"") || text.contains("“") || text.contains("「") { return text }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = replacing("[ \\t]{2,}", in: text, with: " ")
        text = replacing("([。！？!?，,])\\1+", in: text, with: "$1")
        text = replacing(" +([，。！？、；：])", in: text, with: "$1")
        if preferences.isolatedFillers == .remove {
            // Only an explicit hesitation followed by a separator, never the standalone answer 嗯。
            text = replacing("(^|[。！？!?\\n])(?:呃|额)[，,、] *", in: text, with: "$1")
        }
        if preferences.sentencePrefixes == .remove {
            // 那个方案 and 就是这样 are not fillers: require a following comma.
            text = replacing("(^|[。！？!?\\n])(?:那个|就是)[，,] *", in: text, with: "$1")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    public static func isValidModelOutput(_ output: String, original: String, preferences: CleanupPreferences, complete: Bool) -> Bool {
        let candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard complete, !candidate.isEmpty, !candidate.contains("```"),
              candidate.unicodeScalars.count <= max(40, original.unicodeScalars.count * 2),
              candidate.unicodeScalars.count >= max(1, original.unicodeScalars.count / 2) else { return false }
        for prefix in ["以下是", "润色后的", "Here is", "Here’s", "Summary:"] where candidate.hasPrefix(prefix) { return false }
        for pattern in ["[0-9]+(?:[.,:/-][0-9]+)*", "https?://[^\\s，。！？]+"] {
            if matches(pattern, in: candidate) != matches(pattern, in: original) { return false }
        }
        var protected = ["不", "没", "未", "not", "never"]
        if preferences.isolatedFillers != .remove { protected += ["嗯", "呃", "额"] }
        if preferences.sentencePrefixes != .remove { protected += ["那个", "就是", "然后"] }
        for word in protected {
            let before = original.components(separatedBy: word).count - 1
            let after = candidate.components(separatedBy: word).count - 1
            if after < before { return false }
        }
        return true // Structural checks cannot prove complete semantic equivalence.
    }
}

/// Minimal persistence model, independent of any onboarding UI or UserDefaults.
public struct CleanupSelection: Codable, Equatable {
    public private(set) var preferences = CleanupPreferences()
    public init() {}
    public mutating func chooseIsolatedFillers(_ choice: CleanupChoice) { preferences.isolatedFillers = choice }
    public mutating func chooseSentencePrefixes(_ choice: CleanupChoice) { preferences.sentencePrefixes = choice }
    public mutating func skipOrContinue() { /* never infer opt-in from navigation */ }
}
