/// Decides whether one Escape press belongs to VoiceType, without accessing the event system.
/// Latch ownership until key-up: cancellation may synchronously leave the active state.
public struct EscapeKeyFilter {
    public enum Decision: Equatable {
        case passThrough
        case consume(requestCancellation: Bool)
    }

    private var ownsPress = false
    public init() {}

    public mutating func handle(keyCode: UInt16, isKeyDown: Bool, isRepeat: Bool = false, sessionActive: Bool) -> Decision {
        guard keyCode == HotkeyInterpreter.escapeKeyCode else { return .passThrough }
        if !isKeyDown {
            let owned = ownsPress
            ownsPress = false
            return owned ? .consume(requestCancellation: false) : .passThrough
        }
        if ownsPress { return .consume(requestCancellation: false) }
        // A key held before a session began still belongs to the target app.
        guard !isRepeat, sessionActive else { return .passThrough }
        ownsPress = true
        return .consume(requestCancellation: true)
    }
}
