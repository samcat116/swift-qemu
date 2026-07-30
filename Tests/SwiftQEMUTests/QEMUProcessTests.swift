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

    /// Build a process and register its cleanup.
    ///
    /// Cleanup goes through `addTeardownBlock` rather than a per-test `defer`
    /// because `QEMUProcess` is an actor: `stop()` is `await`-ed now, and `defer`
    /// bodies cannot await. Teardown blocks can, and they still run on the failure
    /// paths a `defer` was there to cover.
    private func makeProcess(qemuPath: String) -> (QEMUProcess, String) {
        let socketPath = NSTemporaryDirectory() + "qemu-test-\(UUID().uuidString).sock"
        let process = QEMUProcess(
            qemuPath: qemuPath,
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )
        addTeardownBlock {
            await process.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        return (process, socketPath)
    }

    /// The stock configuration — which now starts on every supported host, so
    /// there is nothing left to override.
    private static let defaultConfig = QEMUConfiguration()

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

        let stderr = await process.capturedStderr
        XCTAssertTrue(
            stderr.contains("could not open disk image"),
            "Expected stderr to survive stop(), got: \(stderr)"
        )
    }

    /// A process that comes up normally still starts, and stderr capture does
    /// not interfere with the socket wait.
    func testStartSucceedsWhenTheSocketAppears() async throws {
        let fake = try makeSocketCreatingQEMU(body: "sleep 30")
        let (process, _) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let isRunning = await process.isRunning
        let stderr = await process.capturedStderr
        XCTAssertTrue(isRunning)
        XCTAssertEqual(stderr, "", "A healthy start writes nothing to stderr")
    }

    // MARK: - Waiting for exit

    /// `waitUntilExit()` returns when the process actually exits.
    func testWaitUntilExitReturnsWhenTheProcessExits() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 0.5"))

        try await process.start(with: Self.defaultConfig)
        try await process.waitUntilExit()

        let isRunning = await process.isRunning
        XCTAssertFalse(isRunning)
    }

    /// A process that has already gone is a completed wait, not a wait forever.
    func testWaitUntilExitReturnsImmediatelyForAnExitedProcess() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "exit 0"))

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
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))

        try await process.start(with: Self.defaultConfig)

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(nanoseconds: 500_000_000) }
            group.addTask { try? await process.waitUntilExit() }
            await group.next()
            group.cancelAll()
        }
        let elapsed = Date().timeIntervalSince(started)

        let isRunning = await process.isRunning
        XCTAssertLessThan(elapsed, 10, "Leaving the group took \(elapsed)s; the cancelled wait never returned")
        XCTAssertTrue(isRunning, "The process outlives a cancelled wait")
    }

    /// Cancelling one wait must not satisfy a later one — otherwise a subsequent
    /// `waitUntilExit()` reports a live process as finished.
    func testCancellingOneWaitDoesNotSatisfyTheNext() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))

        try await process.start(with: Self.defaultConfig)

        let first = Task { try await process.waitUntilExit() }
        try await Task.sleep(nanoseconds: 200_000_000)
        first.cancel()
        _ = try? await first.value

        // The second wait must still be waiting on a process that is still alive.
        let second = Task { try await process.waitUntilExit() }
        try await Task.sleep(nanoseconds: 500_000_000)
        let isRunning = await process.isRunning
        XCTAssertFalse(second.isCancelled)
        XCTAssertTrue(isRunning)

        second.cancel()
        _ = try? await second.value
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
            let stderr = await process.capturedStderr
            XCTAssertTrue(
                stderr.contains("something odd"),
                "Live-process stderr should still be available to the caller"
            )
        }
    }

    // MARK: - Concurrent access

    /// Reading status while a start is still in flight.
    ///
    /// This is the shape `QEMUManager.createVM` takes: a task-group child runs
    /// `start(with:)` — which writes `process`, `stderrPipe`, `stderrCapture` and
    /// `exitWaiter` — while another leg reads `isRunning`/`capturedStderr` off the
    /// failure path. As a `@unchecked Sendable` class that overlap was an
    /// unsynchronized read of mutable fields; as an actor the reads interleave at
    /// the start's suspension points instead.
    ///
    /// Against the class this test reports two races under
    /// `swift test --sanitize=thread` — the writes of `stderrCapture` and `process`
    /// in `start(with:)` against these reads — and none against the actor. Without
    /// a sanitizer it still asserts the observable half: the concurrent reads see
    /// the stderr QEMU has already written rather than an empty value.
    func testStatusCanBeReadConcurrentlyWithAStartInFlight() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "qemu-system-x86_64: warning: slow to come up" >&2
        sleep 30
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        // This fake never creates its socket, so `start` sits in the retry loop for
        // its full 10s budget — plenty of overlap to read across.
        // The config is hoisted into a local because referencing the static
        // directly inside the `Task` trips a region-isolation checker crash.
        let config = Self.defaultConfig
        let start = Task { try await process.start(with: config) }

        var sawStderrDuringStart = false
        for _ in 0..<100 where !sawStderrDuringStart {
            _ = await process.isRunning
            if await process.capturedStderr.contains("slow to come up") {
                sawStderrDuringStart = true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(
            sawStderrDuringStart,
            "Concurrent readers should see stderr while start(with:) is still running"
        )
        XCTAssertFalse(start.isCancelled)

        start.cancel()
        _ = try? await start.value
    }

    /// Many readers at once, which is only meaningful now that they serialize on
    /// the actor. Also pins `getQMPSocketPath()` as callable without `await`, since
    /// the path is fixed at init and `QEMUManager` reads it that way.
    func testConcurrentReadersAgreeOnState() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 30"))

        XCTAssertEqual(process.getQMPSocketPath(), socketPath)

        try await process.start(with: Self.defaultConfig)

        let running = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = await process.capturedStderr
                    return await process.isRunning
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(running.count, 32)
        XCTAssertTrue(running.allSatisfy { $0 }, "Every reader should see the same live process")
    }
}
