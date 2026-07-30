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

    // MARK: - Against a real QEMU

    /// The end-to-end version of the bug, and the only place the run state comes
    /// from QEMU rather than from this test: create a VM with the stock
    /// configuration, and it should report itself as waiting to be started, not
    /// as still being created. Skipped where QEMU is not installed.
    func testCreatedVMReportsPausedAndBecomesRunningOnStart() async throws {
        let candidates = [
            "/opt/homebrew/bin/qemu-system-x86_64",
            "/usr/local/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-x86_64"
        ]
        guard let qemuPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("qemu-system-x86_64 not installed")
        }

        let manager = QEMUManager(qemuPath: qemuPath, logger: Logger(label: "test"))

        var config = QEMUConfiguration()
        config.memoryMB = 128
        XCTAssertTrue(config.startPaused, "the default this test is about")

        do {
            try await manager.createVM(config: config)

            let afterCreate = try await manager.getStatus()
            XCTAssertEqual(
                afterCreate, .paused,
                "a created-but-not-started VM is waiting for start(), not still being created"
            )

            try await manager.start()
            let afterStart = try await manager.getStatus()
            XCTAssertEqual(afterStart, .running)
        } catch {
            // `destroy()` is async, so it cannot go in a `defer` — and this test
            // starts a real VM to leak.
            try? await manager.destroy()
            throw error
        }

        try await manager.destroy()
        let afterDestroy = await manager.status
        XCTAssertEqual(afterDestroy, .stopped)
    }
}
