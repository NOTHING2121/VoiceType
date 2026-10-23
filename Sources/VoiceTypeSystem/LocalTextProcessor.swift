import Foundation
import VoiceTypeCore

/// First layer: the same deterministic rules covered by unit tests. Optional OpenRouter polish is not wired yet;
/// the reducer only requests it when polishEnabled is true (default false), and a request fails safely to local text.
public final class LocalTextProcessor: TextProcessing {
    private let processor = TextProcessor()
    public init() {}

    public func clean(_ token: OperationToken, text: String, preferences: CleanupPreferences, callback: @escaping ModuleCallback) {
        let output = processor.clean(text, preferences: preferences)
        DispatchQueue.main.async { callback(token, .localProcessed(output)) }
    }

    public func polish(_ token: OperationToken, text: String, preferences: CleanupPreferences, preferZDR: Bool, callback: @escaping ModuleCallback) {
        DispatchQueue.main.async { callback(token, .modelFailed) }
    }

    public func cancel(session: UInt64) {}
}
