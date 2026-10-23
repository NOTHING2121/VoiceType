import Foundation

public typealias ClipboardItems = [[String: Data]]
public final class FakeClipboard {
    public private(set) var items: ClipboardItems = []
    public private(set) var changeCount = 0
    public var writable = true
    public var canSnapshot = true
    public init() {}
    @discardableResult public func replace(_ items: ClipboardItems) -> Bool {
        guard writable else { return false }
        self.items = items; changeCount += 1; return true
    }
    @discardableResult public func writeText(_ text: String) -> Bool { replace([["public.utf8-plain-text": Data(text.utf8)]]) }
    public var text: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
}
public enum ClipboardRestoreResult: String { case restored, skippedChanged, restoreFailed }
public struct ClipboardRestoreRecord {
    public let operation: OperationToken
    public let time: Milliseconds
    public let result: ClipboardRestoreResult
}
public final class FakeTextInserter: TextInserting {
    private struct RestoreTicket { let token: OperationToken; let ownedVersion: Int; let original: ClipboardItems }
    public let clock: VirtualScheduler
    public let clipboard: FakeClipboard
    public var axAvailable = true
    public var pasteAvailable = true
    public var copyAvailable = true
    public var prepareDelay: Milliseconds = 2
    public var resultDelay: Milliseconds = 10
    public var pasteConsumptionDelay: Milliseconds = 30
    public var axResult: InsertionOutcome = .verifiedSuccess
    public var pasteResult: InsertionOutcome = .verifiedSuccess
    public var neverRespond = false
    public private(set) var preparations: [InsertionStrategy] = []
    public private(set) var writes: [(OperationToken, InsertionStrategy, String)] = []
    public private(set) var targetTexts: [String] = []
    public private(set) var restorations: [ClipboardRestoreRecord] = []
    public private(set) var pendingRestores = 0
    private var tickets: [OperationToken: RestoreTicket] = [:]
    public init(clock: VirtualScheduler, clipboard: FakeClipboard) { self.clock = clock; self.clipboard = clipboard }
    public func prepare(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback) {
        preparations.append(strategy)
        let available: Bool
        switch strategy {
        case .ax: available = axAvailable
        case .paste: available = pasteAvailable && clipboard.writable && clipboard.canSnapshot
        case .copy: available = copyAvailable && clipboard.writable
        }
        clock.after(prepareDelay) { callback(token, .insertionPrepared(available: available)) }
    }
    public func write(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback) {
        writes.append((token, strategy, text))
        switch strategy {
        case .ax:
            let result = axResult
            if result == .verifiedSuccess { targetTexts.append(text) }
            if !neverRespond { clock.after(resultDelay) { callback(token, .insertionResult(result)) } }
        case .copy:
            let result: InsertionOutcome = clipboard.writeText(text) ? .verifiedSuccess : .definiteFailure
            if !neverRespond { clock.after(resultDelay) { callback(token, .insertionResult(result)) } }
        case .paste:
            // Consecutive overlapping pastes inherit the original user's content rather than our old payload.
            let prior = tickets.values.first { $0.ownedVersion == clipboard.changeCount }
            let original = prior?.original ?? clipboard.items
            guard clipboard.writeText(text) else { callback(token, .insertionResult(.definiteFailure)); return }
            let ticket = RestoreTicket(token: token, ownedVersion: clipboard.changeCount, original: original)
            tickets[token] = ticket; pendingRestores += 1
            clock.after(500, scope: .clipboard) { [weak self] in
                guard let self = self, let ticket = self.tickets.removeValue(forKey: token) else { return }
                let result: ClipboardRestoreResult
                if self.clipboard.changeCount != ticket.ownedVersion { result = .skippedChanged }
                else { result = self.clipboard.replace(ticket.original) ? .restored : .restoreFailed }
                self.pendingRestores -= 1
                self.restorations.append(.init(operation: token, time: self.clock.now, result: result))
            }
            let result = pasteResult
            clock.after(pasteConsumptionDelay) { [weak self] in
                guard let self = self else { return }
                if result == .verifiedSuccess {
                    let consumed = self.clipboard.text ?? ""
                    self.targetTexts.append(consumed)
                    if !self.neverRespond { callback(token, .insertionResult(consumed == text ? .verifiedSuccess : .unknown)) }
                } else if !self.neverRespond { callback(token, .insertionResult(result)) }
            }
        }
    }
}
