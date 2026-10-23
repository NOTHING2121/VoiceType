import Foundation

public typealias ModuleCallback = (OperationToken, ModuleResponse) -> Void
public protocol HotkeyMonitoring: AnyObject { var onEvent: ((SessionEvent) -> Void)? { get set } }
public protocol AudioRecording: AnyObject {
    func start(_ token: OperationToken, callback: @escaping ModuleCallback)
    func stop(_ token: OperationToken, callback: @escaping ModuleCallback)
    func closeLate(_ token: OperationToken)
    func cleanup(session: UInt64, completion: @escaping () -> Void)
}
public protocol Transcribing: AnyObject {
    func start(_ token: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback)
    func rotate(previous: OperationToken, next: OperationToken, policy: RecognitionPolicy, callback: @escaping ModuleCallback)
    func end(session: UInt64)
    func cancel(session: UInt64)
}
public protocol TextProcessing: AnyObject {
    func clean(_ token: OperationToken, text: String, preferences: CleanupPreferences, callback: @escaping ModuleCallback)
    func polish(_ token: OperationToken, text: String, preferences: CleanupPreferences, preferZDR: Bool, callback: @escaping ModuleCallback)
    func cancel(session: UInt64)
}
public protocol TextInserting: AnyObject {
    func prepare(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback)
    func write(_ token: OperationToken, strategy: InsertionStrategy, text: String, callback: @escaping ModuleCallback)
}
public protocol HUDPresenting: AnyObject { func update(state: SessionState, message: String?) }
public protocol MetricsRecording: AnyObject { func record(_ metrics: SessionMetrics) }

public enum ScheduleScope: Equatable { case sessionTimer(UInt64), module, clipboard }
public protocol SessionScheduling: AnyObject {
    var now: Milliseconds { get }
    func schedule(at deadline: Milliseconds, scope: ScheduleScope, _ action: @escaping () -> Void)
    func cancelSessionTimers(_ session: UInt64)
}

/// Tests advance logical time without sleep or wall-clock assertions.
public final class VirtualScheduler: SessionScheduling {
    private struct Entry { let order: UInt64; let deadline: Milliseconds; let scope: ScheduleScope; let action: () -> Void }
    public private(set) var now: Milliseconds = 0
    private var sequence: UInt64 = 0
    private var entries: [Entry] = []
    public init() {}
    public var pendingCount: Int { entries.count }
    public func schedule(at deadline: Milliseconds, scope: ScheduleScope = .module, _ action: @escaping () -> Void) {
        sequence += 1; entries.append(Entry(order: sequence, deadline: max(now, deadline), scope: scope, action: action))
    }
    public func after(_ duration: Milliseconds, scope: ScheduleScope = .module, _ action: @escaping () -> Void) {
        schedule(at: now + duration, scope: scope, action)
    }
    public func cancelSessionTimers(_ session: UInt64) { entries.removeAll { $0.scope == .sessionTimer(session) } }
    public func advance(to time: Milliseconds) {
        precondition(time >= now, "Virtual time must be monotonic")
        var executed = 0
        while let index = entries.indices.filter({ entries[$0].deadline <= time }).min(by: {
            let a = entries[$0], b = entries[$1]
            return a.deadline == b.deadline ? a.order < b.order : a.deadline < b.deadline
        }) {
            let entry = entries.remove(at: index); now = entry.deadline; entry.action()
            executed += 1; precondition(executed < 100_000, "Runaway fake callback loop")
        }
        now = time
    }
    public func advance(by duration: Milliseconds) { advance(to: now + duration) }
}

public final class FakeHotkeyMonitor: HotkeyMonitoring {
    public var onEvent: ((SessionEvent) -> Void)?
    public init() {}
    public func emit(_ event: SessionEvent) { onEvent?(event) }
}
public final class FakeHUD: HUDPresenting {
    public private(set) var updates: [(SessionState, String?)] = []
    public init() {}
    public func update(state: SessionState, message: String?) { updates.append((state, message)) }
}
public final class InMemoryMetrics: MetricsRecording {
    public private(set) var sessions: [SessionMetrics] = []
    public init() {}
    public func record(_ metrics: SessionMetrics) { sessions.append(metrics) }
}
