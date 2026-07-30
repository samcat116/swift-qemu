import Foundation
import Testing
@testable import SwiftQEMU

/// Tests for the error vocabulary itself.
///
/// The public API is `throws(QMPError)` throughout, which only means anything if
/// every error that can reach a caller has been brought into this type. These
/// cover the conversion that does it.
@Suite("QMPError")
struct QMPErrorTests {

    struct SomeoneElsesError: Error, LocalizedError {
        var errorDescription: String? { "the disk fell off the bus" }
    }

    /// An error already in this domain passes through unchanged rather than
    /// being wrapped a second time.
    @Test func wrappingLeavesAQMPErrorAlone() {
        let wrapped = QMPError.wrapping(QMPError.processNotRunning)

        guard case .processNotRunning = wrapped else {
            Issue.record("Expected .processNotRunning, got \(wrapped)")
            return
        }
    }

    /// Cancellation is part of the vocabulary, not something beside it: a typed
    /// throws signature has no way to let `CancellationError` past.
    @Test func wrappingMapsCancellationOntoItsOwnCase() {
        let wrapped = QMPError.wrapping(CancellationError())

        guard case .cancelled = wrapped else {
            Issue.record("Expected .cancelled, got \(wrapped)")
            return
        }
    }

    /// Anything unrecognised keeps its identity instead of being rewritten as a
    /// case it is not. `underlying` exists so the mapping can be total without
    /// lying.
    @Test func wrappingKeepsAnUnknownErrorRetrievable() {
        let wrapped = QMPError.wrapping(SomeoneElsesError())

        guard case .underlying(let original) = wrapped else {
            Issue.record("Expected .underlying, got \(wrapped)")
            return
        }
        #expect(original is SomeoneElsesError)
        #expect(wrapped.localizedDescription == "the disk fell off the bus")
    }

    /// The wrapping cases exist to say where a foreign error came from, so their
    /// descriptions have to carry both halves: the context and the original.
    @Test("A wrapping case names its context and its cause", arguments: [
        (
            QMPError.processLaunchFailed(path: "/usr/bin/qemu-system-x86_64", underlying: SomeoneElsesError()),
            "/usr/bin/qemu-system-x86_64"
        ),
        (
            QMPError.connectionFailed(endpoint: "unix:/tmp/qmp.sock", underlying: SomeoneElsesError()),
            "unix:/tmp/qmp.sock"
        ),
        (
            QMPError.runtimeDirectoryCreationFailed(path: "/tmp/qemu-abc", underlying: SomeoneElsesError()),
            "/tmp/qemu-abc"
        ),
        (
            QMPError.requestEncodingFailed(command: "device_add", underlying: SomeoneElsesError()),
            "device_add"
        )
    ])
    func wrappingCasesNameBothTheContextAndTheCause(error: QMPError, context: String) {
        let description = error.localizedDescription

        #expect(description.contains(context), "\(description)")
        #expect(description.contains("the disk fell off the bus"), "\(description)")
    }

    /// Every case describes itself. A `LocalizedError` returning `nil` falls back
    /// to a mangled type name, which is what a caller would end up printing.
    @Test("Every case describes itself", arguments: QMPErrorTests.everyCase)
    func everyCaseHasADescription(error: QMPError) {
        #expect(error.errorDescription != nil, "\(error) has no description")
        #expect(error.errorDescription?.isEmpty == false, "\(error) describes itself as nothing")
    }

    /// One of each, so a case added without a description fails here rather than
    /// reaching a caller as `SwiftQEMU.QMPError.someNewCase`.
    static let everyCase: [QMPError] = [
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
        .capabilityNotNegotiated(.oob),
        .processLaunchFailed(path: "/bin/qemu", underlying: SomeoneElsesError()),
        .runtimeDirectoryCreationFailed(path: "/tmp/x", underlying: SomeoneElsesError()),
        .connectionFailed(endpoint: "127.0.0.1:1", underlying: SomeoneElsesError()),
        .requestEncodingFailed(command: "cont", underlying: SomeoneElsesError()),
        .underlying(SomeoneElsesError()),
    ]
}
