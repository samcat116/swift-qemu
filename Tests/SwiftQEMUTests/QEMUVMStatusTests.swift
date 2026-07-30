import XCTest
import Logging
@testable import SwiftQEMU

/// Tests for the QEMU run state → `QEMUVMStatus` mapping.
///
/// The failure these cover: `startPaused` defaults to `true`, so the stock
/// `createVM` launches QEMU with `-S`, and QEMU reports that as `prelaunch`.
/// `prelaunch` mapped to `.creating`, so a VM that was fully created and waiting
/// to be started read as still being created — and `.creating` meant two
/// different things at once ("`createVM` is in flight" and "ready for you"),
/// which left a caller unable to tell them apart.
final class QEMUVMStatusTests: XCTestCase {

    private func status(_ runState: String, running: Bool? = nil) -> QEMUVMStatus? {
        QEMUVMStatus(
            QMPStatusResponse(status: runState, running: running ?? (runState == "running"))
        )
    }

    // MARK: - The bug

    /// A VM started with `-S` is live and waiting for `cont`, which is exactly
    /// what `.paused` means everywhere else in this API.
    func testPrelaunchIsPausedNotCreating() {
        XCTAssertEqual(status("prelaunch"), .paused)
    }

    /// `.creating` is now unambiguous: nothing QEMU can report maps to it except
    /// an incoming migration, so it otherwise only describes the window before
    /// `createVM` returns.
    func testOnlyAnIncomingMigrationReportsCreating() {
        let reportingCreating = [
            "running", "paused", "suspended", "prelaunch", "shutdown", "poweroff", "inmigrate"
        ].filter { status($0) == .creating }

        XCTAssertEqual(reportingCreating, ["inmigrate"])
    }

    // MARK: - The rest of the mapping

    func testRunningStates() {
        XCTAssertEqual(status("running", running: true), .running)

        // QEMU can report the run state as `running` with execution stopped; the
        // flag is what settles it.
        XCTAssertEqual(status("running", running: false), .paused)
    }

    func testPausedStates() {
        XCTAssertEqual(status("paused"), .paused)
        XCTAssertEqual(status("suspended"), .paused)
    }

    func testStoppedStates() {
        XCTAssertEqual(status("shutdown"), .stopped)
        XCTAssertEqual(status("poweroff"), .stopped)
    }

    /// QEMU's run states are not case-normalised anywhere in the protocol, so the
    /// mapping does it rather than falling through to "unrecognised".
    func testRunStateMatchingIsCaseInsensitive() {
        XCTAssertEqual(status("PRELAUNCH"), .paused)
        XCTAssertEqual(status("Paused"), .paused)
    }

    /// `nil`, not `.unknown`: the caller has the raw string and a logger, and
    /// swallowing an unrecognised state here would lose the warning.
    func testUnrecognisedRunStateIsRejectedRatherThanGuessed() {
        XCTAssertNil(status("guest-panicked"))
        XCTAssertNil(status("watchdog"))
        XCTAssertNil(status(""))
    }

    // MARK: - From events

    private func status(event: String, data: JSONValue? = nil) -> QEMUVMStatus? {
        QEMUVMStatus(event: QMPEvent(event: event, data: data))
    }

    /// The transitions QEMU announces, which is what lets `status` stay current
    /// without polling `query-status` — including when the guest is the one that
    /// initiated them.
    func testEventsThatImplyARunState() {
        XCTAssertEqual(status(event: "STOP"), .paused)
        XCTAssertEqual(status(event: "SUSPEND"), .paused)
        XCTAssertEqual(status(event: "RESUME"), .running)
        XCTAssertEqual(status(event: "WAKEUP"), .running)
        XCTAssertEqual(status(event: "POWERDOWN"), .shuttingDown)
        XCTAssertEqual(status(event: "SHUTDOWN"), .stopped)
    }

    /// `nil` rather than a guess. `RESET` leaves the run state exactly as it was —
    /// verified on 11.0.2, which also emits it *twice* per `system_reset`, so
    /// treating it as a transition would be wrong twice over — and what
    /// `GUEST_PANICKED` implies depends on `-action panic`.
    func testEventsThatImplyNothingAboutTheRunState() {
        XCTAssertNil(status(event: "RESET"))
        XCTAssertNil(status(event: "GUEST_PANICKED"))
        XCTAssertNil(status(event: "DEVICE_DELETED", data: ["device": "vdb"]))
        XCTAssertNil(status(event: "BLOCK_IO_ERROR"))
        XCTAssertNil(status(event: "NIC_RX_FILTER_CHANGED"))
    }

    /// QMP event names are upper-case and matched exactly; nothing here should be
    /// guessing at case the way the run-state mapping deliberately does.
    func testEventNamesAreMatchedExactly() {
        XCTAssertNil(status(event: "stop"))
        XCTAssertNil(status(event: ""))
    }

    /// The names the mapping switches on are the ones QEMU actually emits.
    func testEventNameConstantsMatchTheProtocol() {
        XCTAssertEqual(QMPEventName.stop, "STOP")
        XCTAssertEqual(QMPEventName.resume, "RESUME")
        XCTAssertEqual(QMPEventName.powerdown, "POWERDOWN")
        XCTAssertEqual(QMPEventName.shutdown, "SHUTDOWN")
        XCTAssertEqual(QMPEventName.deviceDeleted, "DEVICE_DELETED")
    }

    // MARK: - Against a real QEMU

    /// The end-to-end version of the bug, and the only place the run state comes
    /// from QEMU rather than from this test: create a VM with the stock
    /// configuration, and it should report itself as waiting to be started, not
    /// as still being created. Skipped where QEMU is not installed.
    func testCreatedVMReportsPausedAndBecomesRunningOnStart() async throws {
        let manager = QEMUManager(qemuPath: try Self.installedQEMU(), logger: Logger(label: "test"))

        // This test starts a real VM to leak, and `destroy()` is `await`-ed, so
        // cleanup goes in a teardown block rather than a `defer` — which cannot
        // await — and thereby also covers the failure paths below.
        addTeardownBlock { try? await manager.destroy() }

        var config = QEMUConfiguration()
        config.memoryMB = 128
        XCTAssertTrue(config.startPaused, "the default this test is about")

        try await manager.createVM(config: config)

        let afterCreate = try await manager.getStatus()
        XCTAssertEqual(
            afterCreate, .paused,
            "a created-but-not-started VM is waiting for start(), not still being created"
        )

        try await manager.start()
        let afterStart = try await manager.getStatus()
        XCTAssertEqual(afterStart, .running)

        try await manager.destroy()
        let afterDestroy = await manager.status
        XCTAssertEqual(afterDestroy, .stopped)
    }

    /// The event stream, end to end against a real QEMU: the events have to arrive
    /// with the names and ordering QEMU actually uses, which no fake can establish.
    /// Skipped where QEMU is not installed.
    func testEventsFromARealQEMUReachTheManagersSubscribers() async throws {
        let manager = QEMUManager(qemuPath: try Self.installedQEMU(), logger: Logger(label: "test"))
        addTeardownBlock { try? await manager.destroy() }

        var config = QEMUConfiguration()
        config.memoryMB = 128
        try await manager.createVM(config: config)

        // QEMU 11 offers `oob` and nothing else; a VM that negotiated it can reach a
        // blocked monitor.
        let capabilities = await manager.negotiatedCapabilities
        XCTAssertEqual(capabilities, [.oob], "QEMU 11 offers oob, and it is requested by default")

        let events = try await manager.events()

        try await manager.start()
        try await manager.pause()

        // RESUME then STOP, from the real QEMU. `collect` bounds the wait so a
        // regression fails rather than hangs.
        let received = await Self.collect(2, from: events)
        XCTAssertEqual(received.map(\.event), ["RESUME", "STOP"])

        let afterPause = await manager.status
        XCTAssertEqual(afterPause, .paused)
    }

    private static func installedQEMU() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/qemu-system-x86_64",
            "/usr/local/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-x86_64"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("qemu-system-x86_64 not installed")
        }
        return path
    }

    /// Take up to `count` events, giving up after `timeout` so a delivery regression
    /// fails the test instead of parking the suite.
    private static func collect(
        _ count: Int,
        from stream: AsyncStream<QMPEvent>,
        timeout: TimeInterval = 10
    ) async -> [QMPEvent] {
        await withTaskGroup(of: [QMPEvent]?.self) { group in
            group.addTask {
                var collected: [QMPEvent] = []
                for await event in stream {
                    collected.append(event)
                    if collected.count == count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }
}
