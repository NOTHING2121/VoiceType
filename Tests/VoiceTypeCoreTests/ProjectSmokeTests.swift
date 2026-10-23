import VoiceTypeCore

#if compiler(>=6.0) && canImport(Testing)
import Testing

@Test("工程协议：只有明确安全信号才阻断")
func safetySignalsSmoke() {
    #expect(!SafetySignals().blocks)
    #expect(!SafetySignals(secureTextField: nil, secureEventInput: false).blocks)
    #expect(SafetySignals(secureTextField: true).blocks)
    #expect(SafetySignals(secureEventInput: true).blocks)
}
#elseif canImport(XCTest)
import XCTest

final class ProjectSmokeTests: XCTestCase {
    func testSafetySignalsBlockOnlyConfirmedSecureInput() {
        XCTAssertFalse(SafetySignals().blocks)
        XCTAssertFalse(SafetySignals(secureTextField: nil, secureEventInput: false).blocks)
        XCTAssertTrue(SafetySignals(secureTextField: true).blocks)
        XCTAssertTrue(SafetySignals(secureEventInput: true).blocks)
    }
}
#else
#error("Install Xcode for XCTest or a Swift 6 toolchain containing Swift Testing")
#endif
