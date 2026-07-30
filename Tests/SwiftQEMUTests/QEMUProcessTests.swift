import XCTest
import Logging
@testable import SwiftQEMU

/// Tests for `QEMUProcess` stderr capture, driven by a stand-in binary rather
/// than a real QEMU so they run anywhere.
///
/// The failure these cover: QEMU rejects a bad argument by printing one line to
/// stderr and exiting. With stderr going to /dev/null that presented only as a
/// QMP connect timeout ten seconds later, with nothing anywhere naming the cause.
final class QEMUProcessTests: XCTestCase {

    // MARK: - Fake QEMU binary

    private var scriptPaths: [String] = []

    /// Write an executable shell script and return its path. Stands in for the
    /// QEMU binary; `QEMUProcess` appends its usual arguments, which the script
    /// is free to ignore.
    private func makeFakeQEMU(body: String) throws -> String {
        let path = NSTemporaryDirectory() + "fake-qemu-\(UUID().uuidString).sh"
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        scriptPaths.append(path)
        return path
    }

    /// A stand-in QEMU that creates its QMP socket file the way QEMU does — from
    /// the `-qmp unix:<path>,server,wait=off` argument — and then runs `body`.
    /// Anything testing behaviour *after* startup has to get past the socket wait.
    private func makeSocketCreatingQEMU(body: String) throws -> String {
        try makeFakeQEMU(body: """
        for arg in "$@"; do
            case "$arg" in
                unix:*) touch "$(echo "$arg" | sed 's/^unix://; s/,.*$//')" ;;
            esac
        done
        \(body)
        """)
    }

    override func tearDown() {
        for path in scriptPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        scriptPaths = []
        super.tearDown()
    }

    private func makeProcess(qemuPath: String) -> (QEMUProcess, String) {
        let socketPath = NSTemporaryDirectory() + "qemu-test-\(UUID().uuidString).sock"
        let process = QEMUProcess(
            qemuPath: qemuPath,
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )
        return (process, socketPath)
    }

    private static let defaultConfig: QEMUConfiguration = {
        var config = QEMUConfiguration()
        config.enableKVM = false
        return config
    }()

    // MARK: - Tests

    /// A binary that dies on startup must fail with its own stderr attached,
    /// not with a bare socket-creation failure.
    func testStartSurfacesStderrWhenProcessExitsImmediately() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "qemu-system-x86_64: -machine q35: unsupported machine type" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to fail when the process exits immediately")
        } catch let error as QMPError {
            guard case .processExited(let exitCode, let killedBySignal, let stderr) = error else {
                return XCTFail("Expected .processExited, got \(error)")
            }
            XCTAssertEqual(exitCode, 1)
            XCTAssertFalse(killedBySignal)
            XCTAssertTrue(
                stderr.contains("unsupported machine type"),
                "stderr should carry the reason QEMU gave up, got: \(stderr)"
            )
            // The whole point: the message reads as a diagnosis on its own.
            XCTAssertTrue(
                error.localizedDescription.contains("unsupported machine type"),
                "error description should include stderr, got: \(error.localizedDescription)"
            )
        }
    }

    /// The early-exit check must short-circuit the socket wait. Waiting out the
    /// full 10-second retry budget is what made the original failure look like a
    /// connection problem.
    func testEarlyExitIsReportedWithoutWaitingOutTheSocketTimeout() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "fatal: no such file or directory" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let started = Date()
        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to fail")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 5, "Early exit should be detected well before the 10s socket timeout")
        }
    }

    /// A process killed by a signal is reported as such rather than as an exit code.
    func testTerminationBySignalIsDistinguishedFromExitCode() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "about to be killed" >&2
        kill -TERM $$
        sleep 5
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to fail")
        } catch let error as QMPError {
            guard case .processExited(let exitCode, let killedBySignal, _) = error else {
                return XCTFail("Expected .processExited, got \(error)")
            }
            XCTAssertTrue(killedBySignal, "SIGTERM should be reported as a signal")
            XCTAssertEqual(exitCode, SIGTERM)
        }
    }

    /// Stderr is drained continuously and only the tail is retained. Writing far
    /// more than the 64KB pipe buffer is the case that used to take QEMU down
    /// when a `Pipe()` was attached without a reader.
    func testStderrIsDrainedBeyondThePipeBufferAndKeepsTheTail() async throws {
        let fake = try makeFakeQEMU(body: """
        awk 'BEGIN { for (i = 0; i < 4000; i++) print "qemu noise line " i }' >&2
        echo "FINAL_MARKER_9f3c" >&2
        exit 3
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to fail")
        } catch let error as QMPError {
            guard case .processExited(let exitCode, _, let stderr) = error else {
                return XCTFail("Expected .processExited, got \(error)")
            }
            XCTAssertEqual(exitCode, 3)
            XCTAssertTrue(stderr.contains("FINAL_MARKER_9f3c"), "The last thing written must survive")
            XCTAssertFalse(stderr.contains("qemu noise line 0\n"), "Old output should have been dropped")
            XCTAssertLessThanOrEqual(
                stderr.utf8.count, 16 * 1024,
                "Capture must stay bounded, got \(stderr.utf8.count) bytes"
            )
        }
    }

    /// The capture outlives `stop()` so a caller cleaning up after a failure can
    /// still report what went wrong — the path `QEMUManager.createVM` takes.
    func testCapturedStderrRemainsReadableAfterStop() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "could not open disk image /nope.qcow2" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        try? await process.start(with: Self.defaultConfig)
        await process.stop()

        XCTAssertTrue(
            process.capturedStderr.contains("could not open disk image"),
            "Expected stderr to survive stop(), got: \(process.capturedStderr)"
        )
    }

    /// A process that comes up normally still starts, and stderr capture does
    /// not interfere with the socket wait.
    func testStartSucceedsWhenTheSocketAppears() async throws {
        let fake = try makeSocketCreatingQEMU(body: "sleep 30")
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.capturedStderr, "", "A healthy start writes nothing to stderr")

        await process.stop()
    }

    // MARK: - Waiting for exit

    /// `waitUntilExit()` returns when the process actually exits.
    func testWaitUntilExitReturnsWhenTheProcessExits() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 0.5"))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        try await process.waitUntilExit()

        XCTAssertFalse(process.isRunning)
    }

    /// A process that has already gone is a completed wait, not a wait forever.
    func testWaitUntilExitReturnsImmediatelyForAnExitedProcess() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "exit 0"))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        try await Task.sleep(nanoseconds: 300_000_000) // certainly gone

        let started = Date()
        try await process.waitUntilExit()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// The wait must be cancellable, and this is the shape that matters:
    /// `QEMUManager.shutdown()` races it against a timeout in a task group.
    ///
    /// Parked on a bare `withCheckedContinuation`, the wait ignored cancellation,
    /// so when the timeout leg won, the group's implicit drain waited on a task
    /// that would never finish — a shutdown that hung *past its own timeout*,
    /// never reaching the forced termination meant to follow. Left unbounded this
    /// test hangs rather than fails, so it asserts against a wall-clock budget.
    func testWaitUntilExitIsCancellableSoATimedWaitCanFinish() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            group.addTask { try? await process.waitUntilExit() }
            await group.next()
            group.cancelAll()
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 10, "Leaving the group took \(elapsed)s; the cancelled wait never returned")
        XCTAssertTrue(process.isRunning, "The process outlives a cancelled wait")

        await process.stop()
    }

    /// Cancelling one wait must not satisfy a later one — otherwise a subsequent
    /// `waitUntilExit()` reports a live process as finished.
    func testCancellingOneWaitDoesNotSatisfyTheNext() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)

        let first = Task { try await process.waitUntilExit() }
        try await Task.sleep(nanoseconds: 200_000_000)
        first.cancel()
        _ = try? await first.value

        // The second wait must still be waiting on a process that is still alive.
        let second = Task { try await process.waitUntilExit() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(second.isCancelled)
        XCTAssertTrue(process.isRunning)

        second.cancel()
        _ = try? await second.value

        await process.stop()
    }

    /// A process that lives but never creates the socket still reports the
    /// original socket failure rather than being misattributed to an exit.
    func testSocketCreationFailureIsStillReportedWhenProcessStaysAlive() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "warning: something odd" >&2
        sleep 30
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to fail without a socket")
        } catch let error as QMPError {
            guard case .socketCreationFailed = error else {
                return XCTFail("Expected .socketCreationFailed, got \(error)")
            }
            XCTAssertTrue(
                process.capturedStderr.contains("something odd"),
                "Live-process stderr should still be available to the caller"
            )
        }

        await process.stop()
    }

    // MARK: - Stopping

    /// `stop()` must not return until the child has actually exited.
    ///
    /// It used to send SIGTERM and clear `process` in the next statement, so
    /// `isRunning` — derived from `process` — reported `false` over a QEMU that was
    /// still shutting down, and the socket file was deleted from under it. A caller
    /// polling `isRunning` saw a stopped VM that was still running.
    func testStopWaitsForTheProcessToActuallyExit() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.slowToTerminate(afterSeconds: 1))
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(process.isRunning)

        let started = Date()
        await process.stop(timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(
            elapsed, 0.5,
            "stop() returned in \(elapsed)s without waiting out the child's shutdown"
        )
        XCTAssertFalse(process.isRunning, "isRunning must be false once stop() returns")
        XCTAssertNil(process.processIdentifier, "The exited process should have been released")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "The socket file should be removed once the process is gone"
        )
    }

    /// A QEMU that ignores SIGTERM — wedged, or stopped by job control — has to be
    /// killed outright. `destroy()` is documented as a force quit, and before this
    /// the forcing amounted to a single SIGTERM.
    func testStopEscalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        let fake = try makeSocketCreatingQEMU(body: """
        trap '' TERM
        \(Self.stayAlive)
        """)
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(process.isRunning)

        let started = Date()
        await process.stop(timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(process.isRunning, "SIGKILL should have taken down a process that ignored SIGTERM")
        XCTAssertLessThan(elapsed, 10, "Escalation took \(elapsed)s; the second wait should be bounded too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    /// Stopping something that has already exited is cleanup, not an error — and it
    /// still has work to do, because the socket file outlives the process.
    func testStopCleansUpAfterAProcessThatAlreadyExited() async throws {
        let fake = try makeSocketCreatingQEMU(body: """
        echo "goodbye" >&2
        exit 0
        """)
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        try await process.waitUntilExit()

        await process.stop()

        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(
            process.capturedStderr.contains("goodbye"),
            "Cleanup must not throw away the stderr a caller may still want to report"
        )
    }

    /// Stopping a process that was never started must not trip over its own
    /// bookkeeping.
    func testStopOnANeverStartedProcessIsHarmless() async throws {
        let (process, _) = makeProcess(qemuPath: "/nonexistent/qemu")

        await process.stop()

        XCTAssertFalse(process.isRunning)
        XCTAssertNil(process.processIdentifier)
    }

    /// A restart after a completed `stop()` must be allowed — and must get a socket
    /// of its own rather than colliding with a leftover from the previous run.
    func testProcessCanBeRestartedAfterStop() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)
        let firstPID = process.processIdentifier
        await process.stop(timeout: 5)

        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(process.isRunning)
        XCTAssertNotEqual(process.processIdentifier, firstPID, "The restart should be a new process")

        await process.stop(timeout: 5)
    }

    /// A second `start()` while the first process is alive is still refused. This is
    /// the guard that the old `stop()` used to defeat by nilling out `process` under
    /// a live QEMU, letting a restart reuse the same socket path as the survivor.
    func testStartIsRefusedWhileAProcessIsAlreadyRunning() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, socketPath) = makeProcess(qemuPath: fake)
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        try await process.start(with: Self.defaultConfig)

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected the second start to be refused")
        } catch let error as QMPError {
            guard case .processAlreadyRunning = error else {
                return XCTFail("Expected .processAlreadyRunning, got \(error)")
            }
        }

        await process.stop(timeout: 5)
    }

    /// Dropping a `QEMUProcess` without stopping it used to leave QEMU running for
    /// the lifetime of the host process. Verified by watching the child's own
    /// heartbeat rather than the pid, which stays visible while it is a zombie.
    func testDroppingTheProcessKillsAStillRunningChild() async throws {
        let heartbeat = NSTemporaryDirectory() + "qemu-heartbeat-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: heartbeat) }

        let fake = try makeSocketCreatingQEMU(body: """
        while :; do
            echo tick >> "\(heartbeat)"
            sleep 0.05
        done
        """)
        let socketPath = NSTemporaryDirectory() + "qemu-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        var process: QEMUProcess? = QEMUProcess(
            qemuPath: fake,
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )
        try await process?.start(with: Self.defaultConfig)

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(ticks(in: heartbeat), 0, "The fake QEMU should be ticking before it is dropped")

        process = nil // deinit: the only thing left that can stop the child

        try await Task.sleep(nanoseconds: 400_000_000)
        let afterRelease = ticks(in: heartbeat)
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(
            ticks(in: heartbeat), afterRelease,
            "The child kept running after its QEMUProcess was released"
        )
    }

    // MARK: - Helpers

    /// A shell body that stays alive but stays responsive to signals. A plain
    /// `sleep 120` would not do: `sh` only runs a trap once the current foreground
    /// command finishes, so short sleeps in a loop are what make a `trap` observable.
    private static let stayAlive = """
    i=0
    while [ $i -lt 2400 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    """

    /// A shell body that honours SIGTERM, but takes its time about it — the window
    /// in which `stop()` used to claim the process had already stopped.
    private static func slowToTerminate(afterSeconds seconds: Double) -> String {
        """
        trap 'sleep \(seconds); exit 0' TERM
        \(stayAlive)
        """
    }

    private func ticks(in path: String) -> Int {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n")
            .count ?? 0
    }
}
