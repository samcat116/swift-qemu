import Foundation
import Logging
import Testing
@testable import SwiftQEMU

/// Tests for the QEMU run state → `QEMUVMStatus` mapping.
///
/// The failure these cover: `startPaused` defaults to `true`, so the stock
/// `createVM` launches QEMU with `-S`, and QEMU reports that as `prelaunch`.
/// `prelaunch` mapped to `.creating`, so a VM that was fully created and waiting
/// to be started read as still being created — and `.creating` meant two
/// different things at once ("`createVM` is in flight" and "ready for you"),
/// which left a caller unable to tell them apart.
@Suite("VM status mapping")
struct QEMUVMStatusTests {

    private func status(_ runState: String, running: Bool? = nil) -> QEMUVMStatus? {
        QEMUVMStatus(
            QMPStatusResponse(status: runState, running: running ?? (runState == "running"))
        )
    }

    // MARK: - The bug

    /// A VM started with `-S` is live and waiting for `cont`, which is exactly
    /// what `.paused` means everywhere else in this API.
    @Test func prelaunchIsPausedNotCreating() {
        #expect(status("prelaunch") == .paused)
    }

    /// `.creating` is now unambiguous: nothing QEMU can report maps to it except
    /// an incoming migration, so it otherwise only describes the window before
    /// `createVM` returns.
    @Test func onlyAnIncomingMigrationReportsCreating() {
        let reportingCreating = [
            "running", "paused", "suspended", "prelaunch", "shutdown", "poweroff", "inmigrate"
        ].filter { status($0) == .creating }

        #expect(reportingCreating == ["inmigrate"])
    }

    // MARK: - The rest of the mapping

    /// QEMU's run states are not case-normalised anywhere in the protocol, so the
    /// mapping does it rather than falling through to "unrecognised" — hence the
    /// mixed case in the table.
    @Test("Every run state QEMU reports maps to one status", arguments: [
        ("running", true, QEMUVMStatus.running),
        // QEMU can report the run state as `running` with execution stopped; the
        // flag is what settles it.
        ("running", false, .paused),
        ("paused", false, .paused),
        ("suspended", false, .paused),
        ("shutdown", false, .stopped),
        ("poweroff", false, .stopped),
        ("PRELAUNCH", false, .paused),
        ("Paused", false, .paused)
    ])
    func runStateMapping(runState: String, running: Bool, expected: QEMUVMStatus) {
        #expect(status(runState, running: running) == expected)
    }

    /// `nil`, not `.unknown`: the caller has the raw string and a logger, and
    /// swallowing an unrecognised state here would lose the warning.
    @Test("An unrecognised run state is rejected rather than guessed",
          arguments: ["guest-panicked", "watchdog", ""])
    func unrecognisedRunStateIsRejected(runState: String) {
        #expect(status(runState) == nil)
    }

    // MARK: - From events

    private func status(event: String, data: JSONValue? = nil) -> QEMUVMStatus? {
        QEMUVMStatus(event: QMPEvent(event: event, data: data))
    }

    /// The transitions QEMU announces, which is what lets `status` stay current
    /// without polling `query-status` — including when the guest is the one that
    /// initiated them.
    @Test("An event that implies a run state maps to it", arguments: [
        ("STOP", QEMUVMStatus.paused),
        ("SUSPEND", .paused),
        ("RESUME", .running),
        ("WAKEUP", .running),
        ("POWERDOWN", .shuttingDown),
        ("SHUTDOWN", .stopped)
    ])
    func eventsThatImplyARunState(event: String, expected: QEMUVMStatus) {
        #expect(status(event: event) == expected)
    }

    /// `nil` rather than a guess. `RESET` leaves the run state exactly as it was —
    /// verified on 11.0.2, which also emits it *twice* per `system_reset`, so
    /// treating it as a transition would be wrong twice over — and what
    /// `GUEST_PANICKED` implies depends on `-action panic`.
    ///
    /// The last two are the case rule: QMP event names are upper-case and matched
    /// exactly, unlike the run states above, which are deliberately case-folded.
    @Test("An event that implies nothing about the run state maps to nothing",
          arguments: ["RESET", "GUEST_PANICKED", "BLOCK_IO_ERROR", "NIC_RX_FILTER_CHANGED", "stop", ""])
    func eventsThatImplyNothingAboutTheRunState(event: String) {
        #expect(status(event: event) == nil)
    }

    @Test func deviceDeletedImpliesNothingAboutTheRunState() {
        #expect(status(event: "DEVICE_DELETED", data: ["device": "vdb"]) == nil)
    }

    /// The names the mapping switches on are the ones QEMU actually emits.
    @Test func eventNameConstantsMatchTheProtocol() {
        #expect(QMPEventName.stop == "STOP")
        #expect(QMPEventName.resume == "RESUME")
        #expect(QMPEventName.powerdown == "POWERDOWN")
        #expect(QMPEventName.shutdown == "SHUTDOWN")
        #expect(QMPEventName.deviceDeleted == "DEVICE_DELETED")
    }
}

// MARK: - Against a real QEMU

/// The manager driven end to end against a real QEMU, which is the only place the
/// run state and the event names come from QEMU rather than from a test.
///
/// A separate suite because the traits are: these are skipped where QEMU is not
/// installed, and bounded by a time limit because everything they wait on — a VM
/// coming up, an event arriving — is something that could stop happening.
@Suite("VM status against a real QEMU", .requiresQEMU, .slowHangBackstop)
struct RealQEMUVMStatusTests {

    /// The end-to-end version of the bug: create a VM with the stock
    /// configuration, and it should report itself as waiting to be started, not as
    /// still being created.
    @Test func createdVMReportsPausedAndBecomesRunningOnStart() async throws {
        var config = QEMUConfiguration()
        config.memoryMB = 128
        #expect(config.startPaused, "the default this test is about")

        try await withVM(config) { manager in
            let afterCreate = try await manager.getStatus()
            #expect(
                afterCreate == .paused,
                "a created-but-not-started VM is waiting for start(), not still being created"
            )

            try await manager.start()
            #expect(try await manager.getStatus() == .running)

            try await manager.destroy()
            #expect(await manager.status == .stopped)
        }
    }

    /// The event stream, end to end: the events have to arrive with the names and
    /// ordering QEMU actually uses, which no fake can establish.
    @Test func eventsFromARealQEMUReachTheManagersSubscribers() async throws {
        var config = QEMUConfiguration()
        config.memoryMB = 128

        try await withVM(config) { manager in
            // QEMU 11 offers `oob` and nothing else; a VM that negotiated it can
            // reach a blocked monitor.
            let capabilities = await manager.negotiatedCapabilities
            #expect(capabilities == [.oob], "QEMU 11 offers oob, and it is requested by default")

            let events = try await manager.events()

            try await manager.start()
            try await manager.pause()

            // RESUME then STOP, from the real QEMU. `collect` bounds the wait so a
            // regression fails rather than hangs.
            let received = await QMPEvents.collect(2, from: events, timeout: .seconds(10))
            #expect(received.map(\.event) == ["RESUME", "STOP"])

            #expect(await manager.status == .paused)
        }
    }
}
