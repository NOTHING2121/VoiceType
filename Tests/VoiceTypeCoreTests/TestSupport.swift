import Foundation
@testable import VoiceTypeCore

struct RegressionFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String = "condition failed", file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw RegressionFailure(message: "\(file):\(line): \(message)") }
}
func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = value else { throw RegressionFailure(message: "\(file):\(line): required value missing") }
    return value
}
struct RegressionCase: CustomStringConvertible, @unchecked Sendable {
    let name: String
    let body: () throws -> Void
    init(_ name: String, _ body: @escaping () throws -> Void) { self.name = name; self.body = body }
    var description: String { name }
    func run() throws { try body() }
}

final class ReducerHarness {
    var machine: SessionStateMachine
    var allEffects: [SessionEffect] = []
    init(preferences: SessionPreferences = .init(), environment: SessionEnvironment = .init()) {
        machine = .init(preferences: preferences, environment: environment)
    }
    @discardableResult func send(_ event: SessionEvent, at time: Milliseconds) -> [SessionEffect] {
        let effects = machine.send(event, at: time); allEffects += effects; return effects
    }
    func tick(_ time: Milliseconds) {
        send(.timer(.init(token: .init(session: 0, operation: 0), kind: .hold, deadline: time)), at: time)
    }
    func start(at time: Milliseconds = 0, audioAt: Milliseconds? = 0) throws {
        send(.rightOptionDown(eligible: true), at: time)
        if let audioAt = audioAt { send(.response(try require(machine.context?.audioToken), .audioStarted), at: max(time, audioAt)) }
    }
    func processing(text: String = "测试文本。", stopAt: Milliseconds = 400, finalAt: Milliseconds = 430) throws {
        try start()
        let speech = try require(machine.context?.recognizerToken)
        send(.response(speech, .partial(text)), at: 100)
        send(.rightOptionUp, at: stopAt)
        send(.response(try require(machine.context?.stopToken), .audioStopped), at: stopAt + 20)
        send(.response(speech, .final(text)), at: finalAt)
        try check(machine.state == .processing, "expected processing, got \(machine.state)")
    }
    func inserting(text: String = "测试文本。") throws {
        try processing(text: text)
        send(.response(try require(machine.context?.activeOperation), .localProcessed(text)), at: 435)
        try check(machine.state == .inserting)
    }
    func prepareWrite(at time: Milliseconds = 440) throws -> OperationToken {
        let op = try require(machine.context?.activeOperation)
        send(.response(op, .insertionPrepared(available: true)), at: time)
        return op
    }
    func commit(at time: Milliseconds = 441) throws -> OperationToken {
        let op = try prepareWrite(at: time - 1)
        send(.commitWrite(op), at: time)
        try check(machine.context?.writeCommitted == true)
        return op
    }
    var audioStartCount: Int { allEffects.filter { if case .startAudio = $0 { return true }; return false }.count }
    var audioStopCount: Int { allEffects.filter { if case .stopAudio = $0 { return true }; return false }.count }
    var modelCount: Int { allEffects.filter { if case .polishText = $0 { return true }; return false }.count }
    var prepareCount: Int { allEffects.filter { if case .prepareInsertion = $0 { return true }; return false }.count }
}
