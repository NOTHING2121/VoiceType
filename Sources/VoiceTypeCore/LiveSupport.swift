import Foundation

/// Pure interpretation of NSEvent/CGEvent modifier data. The system monitor only feeds raw values in.
public struct HotkeyInterpreter {
    public static let rightOptionKeyCode: UInt16 = 61
    public static let escapeKeyCode: UInt16 = 53
    /// Device-dependent bits from IOLLEvent.h (present in NSEvent / CGEventFlags raw values).
    public static let rightOptionMask: UInt64 = 0x40
    public static let leftOptionMask: UInt64 = 0x20
    public static let shiftMask: UInt64 = 1 << 17
    public static let controlMask: UInt64 = 1 << 18
    /// Device-independent "some Option key is down" bit (CGEventFlags.maskAlternate).
    public static let optionMask: UInt64 = 1 << 19
    public static let commandMask: UInt64 = 1 << 20
    static let otherModifiers = shiftMask | controlMask | commandMask | leftOptionMask

    public private(set) var rightOptionDown = false
    public init() {}

    public mutating func flagsChanged(keyCode: UInt16, flags: UInt64) -> [SessionEvent] {
        if keyCode == Self.rightOptionKeyCode {
            let down = flags & Self.rightOptionMask != 0
            if down && !rightOptionDown {
                rightOptionDown = true
                return [.rightOptionDown(eligible: flags & Self.otherModifiers == 0)]
            }
            if !down && rightOptionDown { rightOptionDown = false; return [.rightOptionUp] }
            return []
        }
        // Another modifier pressed while right Option is held turns the gesture into a shortcut.
        if rightOptionDown && flags & Self.otherModifiers != 0 { return [.combinationKey] }
        return []
    }

    public mutating func keyDown(keyCode: UInt16, isRepeat: Bool) -> [SessionEvent] {
        if keyCode == Self.escapeKeyCode { return isRepeat ? [] : [.escape] }
        return rightOptionDown ? [.combinationKey] : []
    }

    /// Recovers a release that the event stream missed (e.g. secure input briefly enabled).
    /// Uses the device-independent Option bit so a source without device bits never fakes a release.
    public mutating func reconcile(physicalFlags: UInt64) -> [SessionEvent] {
        guard rightOptionDown, physicalFlags & Self.optionMask == 0 else { return [] }
        rightOptionDown = false
        return [.rightOptionUp]
    }
}

/// Bounded AX observation used to classify one insertion attempt. Ranges are UTF-16, like AX.
public struct TextFieldSnapshot: Equatable {
    public var selectionLocation: Int
    public var selectionLength: Int
    public var characterCount: Int?
    public init(selectionLocation: Int, selectionLength: Int, characterCount: Int?) {
        self.selectionLocation = selectionLocation; self.selectionLength = selectionLength; self.characterCount = characterCount
    }
}

public enum InsertionObservation: Equatable { case inserted, unchanged, inconclusive }

public enum InsertionVerifier {
    /// `slice` is the target's text at [before.selectionLocation, +text.utf16.count) read after the write.
    public static func evaluate(before: TextFieldSnapshot, after: TextFieldSnapshot?, slice: String?, text: String) -> InsertionObservation {
        guard let after = after else { return .inconclusive }
        let length = text.utf16.count
        let expectedCount = before.characterCount.map { $0 - before.selectionLength + length }
        let countMatches = expectedCount != nil && after.characterCount == expectedCount
        let countUnknown = expectedCount == nil || after.characterCount == nil
        let caretMatches = after.selectionLocation == before.selectionLocation + length && after.selectionLength == 0
        if slice == text && (countMatches || (countUnknown && caretMatches)) { return .inserted }
        if slice == nil && countMatches && caretMatches { return .inserted }
        let sameSelection = after.selectionLocation == before.selectionLocation && after.selectionLength == before.selectionLength
        if sameSelection, before.characterCount != nil, after.characterCount == before.characterCount, slice != text { return .unchanged }
        return .inconclusive
    }
}

public enum RecognitionLocaleResolver {
    public static func normalize(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: "-") }

    /// Chooses a supported Speech locale from an explicit override, then the user's preferred languages.
    public static func resolve(override: String?, preferred: [String], supported: [String]) -> String {
        let available = supported.map(normalize)
        let set = Set(available)
        if let override = override.map(normalize), set.contains(override) { return override }
        for language in preferred.map(normalize) {
            let parts = language.split(separator: "-").map(String.init)
            guard let code = parts.first?.lowercased() else { continue }
            let region = parts.dropFirst().last(where: { $0.count == 2 && $0 == $0.uppercased() })
            var candidates: [String] = []
            if code == "zh" {
                candidates = parts.contains("Hant") ? ["zh-TW", "zh-HK"] : ["zh-CN"]
            } else {
                if let region = region { candidates.append("\(code)-\(region)") }
                if code == "en" { candidates.append("en-US") }
                candidates += available.filter { $0.lowercased().hasPrefix(code + "-") }.sorted()
            }
            if let match = candidates.first(where: set.contains) { return match }
        }
        if set.contains("en-US") { return "en-US" }
        return available.sorted().first ?? "en-US"
    }
}
