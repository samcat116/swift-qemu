import XCTest
@testable import SwiftQEMU

/// Tests for the error vocabulary itself.
///
/// The public API is `throws(QMPError)` throughout, which only means anything if
/// every error that can reach a caller has been brought into this type. These
/// cover the conversion that does it.
final class QMPErrorTests: XCTestCase {

    private struct SomeoneElsesError: Error, LocalizedError {
        var errorDescription: String? { "the disk fell off the bus" }
    }

    /// An error already in this domain passes through unchanged rather than
    /// being wrapped a second time.
    func testWrappingLeavesAQMPErrorAlone() {
        let wrapped = QMPError.wrapping(QMPError.processNotRunning)

        guard case .processNotRunning = wrapped else {
            return XCTFail("Expected .processNotRunning, got \(wrapped)")
        }
    }

    /// Cancellation is part of the vocabulary, not something beside it: a typed
    /// throws signature has no way to let `CancellationError` past.
    func testWrappingMapsCancellationOntoItsOwnCase() {
        let wrapped = QMPError.wrapping(CancellationError())

        guard case .cancelled = wrapped else {
            return XCTFail("Expected .cancelled, got \(wrapped)")
        }
    }

    /// Anything unrecognised keeps its identity instead of being rewritten as a
    /// case it is not. `underlying` exists so the mapping can be total without
    /// lying.
    func testWrappingKeepsAnUnknownErrorRetrievable() {
        let wrapped = QMPError.wrapping(SomeoneElsesError())

        guard case .underlying(let original) = wrapped else {
            return XCTFail("Expected .underlying, got \(wrapped)")
        }
        XCTAssertTrue(original is SomeoneElsesError)
        XCTAssertEqual(wrapped.localizedDescription, "the disk fell off the bus")
    }

    /// The wrapping cases exist to say where a foreign error came from, so their
    /// descriptions have to carry both halves: the context and the original.
    func testWrappingCasesNameBothTheContextAndTheCause() {
        let launch = QMPError.processLaunchFailed(
            path: "/usr/bin/qemu-system-x86_64",
            underlying: SomeoneElsesError()
        )
        XCTAssertTrue(launch.localizedDescription.contains("/usr/bin/qemu-system-x86_64"))
        XCTAssertTrue(launch.localizedDescription.contains("the disk fell off the bus"))

        let connect = QMPError.connectionFailed(
            endpoint: "unix:/tmp/qmp.sock",
            underlying: SomeoneElsesError()
        )
        XCTAssertTrue(connect.localizedDescription.contains("unix:/tmp/qmp.sock"))
        XCTAssertTrue(connect.localizedDescription.contains("the disk fell off the bus"))

        let directory = QMPError.runtimeDirectoryCreationFailed(
            path: "/tmp/qemu-abc",
            underlying: SomeoneElsesError()
        )
        XCTAssertTrue(directory.localizedDescription.contains("/tmp/qemu-abc"))

        let encoding = QMPError.requestEncodingFailed(
            command: "device_add",
            underlying: SomeoneElsesError()
        )
        XCTAssertTrue(encoding.localizedDescription.contains("device_add"))
    }

    /// Every case describes itself. A `LocalizedError` returning `nil` falls back
    /// to a mangled type name, which is what a caller would end up printing.
    func testEveryCaseHasADescription() {
        let cases: [QMPError] = [
            .notConnected,
            .connectionLost,
            .invalidResponse,
            .qmpError("GenericError", "nope"),
            .processNotRunning,
            .processAlreadyRunning,
            .invalidConfiguration,
            .socketCreationFailed,
            .timeout,
            .cancelled,
            .processExited(exitCode: 1, killedBySignal: false, stderr: "boom"),
            .processTerminationFailed(pid: 42),
            .frameTooLarge(limit: 1024),
            .socketPathTooLong(path: "/tmp/x", limit: 104),
            .noHotplugPortAvailable(machineType: "q35", portCount: 4, inUse: 4),
            .hotplugNotSupported(bus: "pcie.0", machineType: "q35"),
            .processLaunchFailed(path: "/bin/qemu", underlying: SomeoneElsesError()),
            .runtimeDirectoryCreationFailed(path: "/tmp/x", underlying: SomeoneElsesError()),
            .connectionFailed(endpoint: "127.0.0.1:1", underlying: SomeoneElsesError()),
            .requestEncodingFailed(command: "cont", underlying: SomeoneElsesError()),
            .underlying(SomeoneElsesError()),
        ]

        for error in cases {
            XCTAssertNotNil(error.errorDescription, "\(error) has no description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) describes itself as nothing")
        }
    }
}
