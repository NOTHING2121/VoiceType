import Foundation

/// Evidence for onboarding completion. Navigation, typing, copy-only and stale callbacks never pass it.
public struct OnboardingProgress {
    public private(set) var shortcutVerified = false
    public private(set) var trialSucceeded = false
    private var shortcutHeld = false
    private var trialSession: UInt64?
    public init() {}

    public mutating func shortcutDown(eligible: Bool) { shortcutHeld = eligible }
    public mutating func shortcutUp() {
        if shortcutHeld { shortcutVerified = true }
        shortcutHeld = false
    }
    public mutating func cancelShortcut() { shortcutHeld = false }
    public mutating func beginTrial(session: UInt64, focused: Bool) {
        trialSession = focused && shortcutVerified ? session : nil
        trialSucceeded = false
    }
    public mutating func finishTrial(session: UInt64, state: SessionState, delivery: DeliveryPath?,
                                     contentChanged: Bool, appChanged: Bool) {
        guard trialSession == session else { return }
        trialSucceeded = state == .done && (delivery == .insertedAX || delivery == .insertedPaste)
            && contentChanged && !appChanged
        trialSession = nil
    }
    public static func matchesInsertion(before: String, location: Int, length: Int, after: String, deliveredText: String) -> Bool {
        let source = before as NSString
        guard !deliveredText.isEmpty, before != after, location >= 0, length >= 0,
              location <= source.length, length <= source.length - location else { return false }
        return source.replacingCharacters(in: NSRange(location: location, length: length), with: deliveredText) == after
    }
    public var canComplete: Bool { shortcutVerified && trialSucceeded }
}
