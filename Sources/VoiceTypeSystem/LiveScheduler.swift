import Foundation
import VoiceTypeCore

/// Monotonic main-queue scheduler. All callbacks land on the main queue, matching the coordinator's serial contract.
public final class LiveScheduler: SessionScheduling {
    private let origin = DispatchTime.now().uptimeNanoseconds
    private var sessionItems: [UInt64: [DispatchWorkItem]] = [:]
    public init() {}

    public var now: Milliseconds {
        Milliseconds((DispatchTime.now().uptimeNanoseconds - origin) / 1_000_000)
    }

    public func schedule(at deadline: Milliseconds, scope: ScheduleScope, _ action: @escaping () -> Void) {
        let item = DispatchWorkItem(block: action)
        if case .sessionTimer(let session) = scope { sessionItems[session, default: []].append(item) }
        let delay = max(0, deadline - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: item)
    }

    public func cancelSessionTimers(_ session: UInt64) {
        sessionItems.removeValue(forKey: session)?.forEach { $0.cancel() }
    }
}
