#if compiler(>=6.0) && canImport(Testing)
import Testing

@Suite("VoiceType deterministic regression", .serialized)
struct VoiceTypeRegressionTests {
    @Test("状态机", arguments: StateMachineCases.all)
    func stateMachine(_ scenario: RegressionCase) throws { try scenario.run() }
    @Test("处理与插入竞态", arguments: ProcessingCases.all)
    func processing(_ scenario: RegressionCase) throws { try scenario.run() }
    @Test("清洗偏好与文本校验", arguments: TextCases.all)
    func text(_ scenario: RegressionCase) throws { try scenario.run() }
}
#elseif canImport(XCTest)
import XCTest

final class VoiceTypeRegressionTests: XCTestCase {
    func testStateMachine() throws { for scenario in StateMachineCases.all { try scenario.run() } }
    func testProcessing() throws { for scenario in ProcessingCases.all { try scenario.run() } }
    func testText() throws { for scenario in TextCases.all { try scenario.run() } }
}
#else
#error("Tests require XCTest or the Swift 6 Testing framework")
#endif
