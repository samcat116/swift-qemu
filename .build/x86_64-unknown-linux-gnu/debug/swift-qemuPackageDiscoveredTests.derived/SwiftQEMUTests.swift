import XCTest
@testable import SwiftQEMUTests

fileprivate extension QMPProtocolTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__QMPProtocolTests = [
        ("testAnyCodableEncoding", testAnyCodableEncoding),
        ("testQMPErrorResponseDecoding", testQMPErrorResponseDecoding),
        ("testQMPGreetingDecoding", testQMPGreetingDecoding),
        ("testQMPRequestEncoding", testQMPRequestEncoding),
        ("testQMPResponseDecoding", testQMPResponseDecoding)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __SwiftQEMUTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(QMPProtocolTests.__allTests__QMPProtocolTests)
    ]
}