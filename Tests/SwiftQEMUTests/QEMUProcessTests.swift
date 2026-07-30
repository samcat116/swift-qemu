import XCTest
import Logging
@testable import SwiftQEMU

// `setenv`/`unsetenv` and the signal constants come from the POSIX layer, which
// Foundation does not promise to re-export on every platform.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

    /// Build a process that places its own socket, the way a caller who does not
    /// name a path gets one, and register its cleanup.
    private func makeManagedProcess(qemuPath: String, runtimeDirectory: String? = nil) -> QEMUProcess {
        let process = QEMUProcess(
            qemuPath: qemuPath,
            runtimeDirectory: runtimeDirectory,
            logger: Logger(label: "test")
        )
        let directory = Self.directory(containing: process.getQMPSocketPath())
        addTeardownBlock {
            await process.stop()
            try? FileManager.default.removeItem(atPath: directory)
        }
        return process
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
            let stderr = await process.capturedStderr
            XCTAssertTrue(
                stderr.contains("something odd"),
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

        try await process.start(with: Self.defaultConfig)
        let startedRunning = await process.isRunning
        XCTAssertTrue(startedRunning)

        let started = Date()
        await process.stop(timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        let isRunning = await process.isRunning
        let pid = await process.processIdentifier
        XCTAssertGreaterThan(
            elapsed, 0.5,
            "stop() returned in \(elapsed)s without waiting out the child's shutdown"
        )
        XCTAssertFalse(isRunning, "isRunning must be false once stop() returns")
        XCTAssertNil(pid, "The exited process should have been released")
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

        try await process.start(with: Self.defaultConfig)
        let startedRunning = await process.isRunning
        XCTAssertTrue(startedRunning)

        let started = Date()
        await process.stop(timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        let isRunning = await process.isRunning
        XCTAssertFalse(isRunning, "SIGKILL should have taken down a process that ignored SIGTERM")
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

        try await process.start(with: Self.defaultConfig)
        try await process.waitUntilExit()

        await process.stop()

        let isRunning = await process.isRunning
        let stderr = await process.capturedStderr
        XCTAssertFalse(isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(
            stderr.contains("goodbye"),
            "Cleanup must not throw away the stderr a caller may still want to report"
        )
    }

    /// Stopping a process that was never started must not trip over its own
    /// bookkeeping.
    func testStopOnANeverStartedProcessIsHarmless() async throws {
        let (process, _) = makeProcess(qemuPath: "/nonexistent/qemu")

        await process.stop()

        let isRunning = await process.isRunning
        let pid = await process.processIdentifier
        XCTAssertFalse(isRunning)
        XCTAssertNil(pid)
    }

    /// A restart after a completed `stop()` must be allowed — and must get a socket
    /// of its own rather than colliding with a leftover from the previous run.
    func testProcessCanBeRestartedAfterStop() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, _) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let firstPID = await process.processIdentifier
        await process.stop(timeout: 5)

        try await process.start(with: Self.defaultConfig)
        let isRunning = await process.isRunning
        let secondPID = await process.processIdentifier
        XCTAssertTrue(isRunning)
        XCTAssertNotEqual(secondPID, firstPID, "The restart should be a new process")

        await process.stop(timeout: 5)
    }

    /// A second `start()` while the first process is alive is still refused. This is
    /// the guard that the old `stop()` used to defeat by nilling out `process` under
    /// a live QEMU, letting a restart reuse the same socket path as the survivor.
    func testStartIsRefusedWhileAProcessIsAlreadyRunning() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, _) = makeProcess(qemuPath: fake)

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

    private static func directory(containing path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The permission bits of a filesystem entry, or `nil` if it is not there.
    private static func mode(of path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - Socket placement
    //
    // The socket used to be `/tmp/qemu-<uuid>.sock` — a full control channel for
    // the VM, sitting in a world-writable directory shared with every user on the
    // host. A socket file's own mode is not portably honoured, so the directory
    // around it is what actually restricts access.

    /// The default socket goes in a private per-instance directory, not loose in
    /// the temporary directory.
    func testDefaultSocketLivesInAPrivateDirectory() async throws {
        let process = makeManagedProcess(qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive))
        let socketPath = process.getQMPSocketPath()
        let directory = Self.directory(containing: socketPath)

        XCTAssertEqual(
            (socketPath as NSString).lastPathComponent, "qmp.sock",
            "A short fixed name inside a private directory, not a UUID in a shared one"
        )
        XCTAssertNotEqual(
            directory, (NSTemporaryDirectory() as NSString).standardizingPath,
            "The socket must not sit directly in the shared temporary directory"
        )

        try await process.start(with: Self.defaultConfig)

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(
            Self.mode(of: directory), 0o700,
            "Directory permissions are the access control for a unix socket"
        )
    }

    /// Teardown removes the whole private directory, not just the socket inside it.
    func testPrivateSocketDirectoryIsRemovedOnStop() async throws {
        let process = makeManagedProcess(qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive))
        let directory = Self.directory(containing: process.getQMPSocketPath())

        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory))

        await process.stop(timeout: 5)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory),
            "The directory this instance created is its own to remove"
        )
    }

    /// Two instances must not share a directory, or one VM's teardown would delete
    /// the other's socket.
    func testEachInstanceGetsItsOwnDirectory() {
        let first = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))
        let second = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))

        XCTAssertNotEqual(first.getQMPSocketPath(), second.getQMPSocketPath())
    }

    /// The base directory is injectable, for callers who want the socket somewhere
    /// other than the temporary directory — `XDG_RUNTIME_DIR`, say.
    func testRuntimeDirectoryIsInjectable() async throws {
        // Short on purpose: a UUID here and the socket beneath it no longer fits in
        // `sun_path` on macOS, which is the budget this whole scheme is working to.
        let base = NSTemporaryDirectory() + "qemu-rt-\(UInt32.random(in: .min ... .max))"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }

        let process = makeManagedProcess(
            qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive),
            runtimeDirectory: base
        )
        let socketPath = process.getQMPSocketPath()
        XCTAssertTrue(socketPath.hasPrefix(base + "/"), "Got \(socketPath)")

        // The base does not have to exist beforehand.
        try await process.start(with: Self.defaultConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    /// The whole point of dropping the UUID from the filename: a unix socket path
    /// has about 100 bytes to work with, and macOS spends half of them on the
    /// temporary directory before this library adds anything.
    func testDefaultSocketPathFitsInSunPath() {
        let process = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))
        let length = process.getQMPSocketPath().utf8.count

        XCTAssertLessThan(
            length, QEMUProcess.maxSocketPathLength,
            "Path is \(length) bytes: \(process.getQMPSocketPath())"
        )
    }

    /// An over-long path is named as such, rather than presenting as a socket that
    /// never appears — which is how a bind failure otherwise reaches a caller.
    func testOverLongSocketPathIsRejectedWithItsOwnError() async throws {
        let process = QEMUProcess(
            qemuPath: "/nonexistent/qemu",
            runtimeDirectory: NSTemporaryDirectory() + String(repeating: "d", count: 200),
            logger: Logger(label: "test")
        )

        do {
            try await process.start(with: Self.defaultConfig)
            XCTFail("Expected start to be refused")
        } catch let error as QMPError {
            guard case .socketPathTooLong(_, let limit) = error else {
                return XCTFail("Expected .socketPathTooLong, got \(error)")
            }
            XCTAssertEqual(limit, QEMUProcess.maxSocketPathLength)
        }
    }

    /// A caller-supplied path is bound and cleaned up, but never treated as
    /// something to delete recursively. `removeItem` on a directory takes
    /// everything under it, and this path comes from outside.
    func testCallerSuppliedPathThatIsADirectoryIsNotDeleted() async throws {
        let directory = NSTemporaryDirectory() + "qemu-not-a-socket-\(UUID().uuidString)"
        let bystander = directory + "/precious.txt"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "do not delete".write(toFile: bystander, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }

        let process = QEMUProcess(
            qemuPath: try makeFakeQEMU(body: "exit 1"),
            qmpSocketPath: directory,
            logger: Logger(label: "test")
        )

        try? await process.start(with: Self.defaultConfig)
        await process.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander), "The directory was deleted")
    }

    /// Dropping the process cleans up its directory too, not just the socket.
    func testDroppingTheProcessRemovesItsPrivateDirectory() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)

        var process: QEMUProcess? = QEMUProcess(qemuPath: fake, logger: Logger(label: "test"))
        let directory = Self.directory(containing: process!.getQMPSocketPath())
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }

        try await process?.start(with: Self.defaultConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory))

        process = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }

    // MARK: - Debug log files

    /// The debug log is guest output — with `-nographic` it is the guest console —
    /// so it belongs in the private directory too, and not in a world-readable
    /// `/tmp/qemu-*.log`.
    ///
    /// It also has to outlive the VM: a log you cannot read after the thing you
    /// were debugging exits is no use, so this is the one case where teardown
    /// leaves the directory behind.
    func testLogFileIsPrivateAndOutlivesTheVM() async throws {
        setenv("ENABLE_QEMU_PROCESS_LOG_FILES", "true", 1)
        defer { unsetenv("ENABLE_QEMU_PROCESS_LOG_FILES") }

        let fake = try makeSocketCreatingQEMU(body: """
        echo "guest console output"
        \(Self.stayAlive)
        """)
        let process = makeManagedProcess(qemuPath: fake)
        let directory = Self.directory(containing: process.getQMPSocketPath())

        try await process.start(with: Self.defaultConfig)
        await process.stop(timeout: 5)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory),
            "A directory holding a log the caller asked for must survive teardown"
        )
        XCTAssertEqual(Self.mode(of: directory), 0o700)

        let logs = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".log") }
        XCTAssertEqual(logs.count, 1, "Expected exactly one log, got \(logs)")

        let logPath = directory + "/" + (logs.first ?? "")
        XCTAssertEqual(Self.mode(of: logPath), 0o600, "The log is guest output; keep it to the owner")
        XCTAssertTrue(
            (try String(contentsOfFile: logPath, encoding: .utf8)).contains("guest console output"),
            "stdout should still be reaching the log"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: process.getQMPSocketPath()),
            "The socket still goes, even when the directory stays"
        )
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
