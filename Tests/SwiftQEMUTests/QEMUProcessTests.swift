import Foundation
import Logging
import Testing
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
///
/// `.serialized`, which is what XCTest gave these for free. One test sets
/// `ENABLE_QEMU_PROCESS_LOG_FILES`, and that is process-global: run concurrently
/// with `testPrivateSocketDirectoryIsRemovedOnStop`, which asserts a directory is
/// gone, it would keep the directory alive and fail it. Parallelism would roughly
/// third the wall clock here, and is not worth buying a race in the suite whose
/// subject is process lifecycle.
///
/// The residual window is cross-suite: the real-QEMU suites can start a process
/// while that variable is set, which costs them a leftover instance directory. No
/// assertion anywhere depends on it, and nothing in-process can narrow it further
/// — the variable is read from the environment because that is the API.
@Suite("QEMU process", .serialized, .hangBackstop)
struct QEMUProcessTests {

    // MARK: - Fake QEMU binary

    /// Scripts, sockets and heartbeat files, removed when this test's instance of
    /// the suite is released. There is no `tearDown` to hang them off any more, and
    /// none of it needs to be awaited.
    private let temporaryFiles = TemporaryFiles()

    /// Write an executable shell script and return its path. Stands in for the
    /// QEMU binary; `QEMUProcess` appends its usual arguments, which the script
    /// is free to ignore.
    private func makeFakeQEMU(body: String) throws -> String {
        let path = temporaryFiles.track(NSTemporaryDirectory() + "fake-qemu-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
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

    /// Build a process at a socket path of the test's choosing.
    ///
    /// Nothing registers a `stop()` against the test, because there is no async
    /// teardown hook to register it with — and none is needed: releasing a
    /// `QEMUProcess` SIGKILLs a child that outlived it and removes its socket and
    /// private directory (fix 11). Dropping out of scope, including on a failure
    /// path, is therefore already the cleanup. Tests that are *about* stopping
    /// still call `stop()` themselves, because a graceful stop is what they assert.
    private func makeProcess(qemuPath: String) -> (QEMUProcess, String) {
        let socketPath = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-test-\(UUID().uuidString).sock"
        )
        let process = QEMUProcess(
            qemuPath: qemuPath,
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )
        return (process, socketPath)
    }

    /// Build a process that places its own socket, the way a caller who does not
    /// name a path gets one.
    private func makeManagedProcess(qemuPath: String, runtimeDirectory: String? = nil) -> QEMUProcess {
        let process = QEMUProcess(
            qemuPath: qemuPath,
            runtimeDirectory: runtimeDirectory,
            logger: Logger(label: "test")
        )
        temporaryFiles.track(Self.directory(containing: process.getQMPSocketPath()))
        return process
    }

    /// The stock configuration — which now starts on every supported host, so
    /// there is nothing left to override.
    private static let defaultConfig = QEMUConfiguration()

    // MARK: - Tests

    /// A binary that dies on startup must fail with its own stderr attached,
    /// not with a bare socket-creation failure.
    @Test func startSurfacesStderrWhenProcessExitsImmediately() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "qemu-system-x86_64: -machine q35: unsupported machine type" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .processExited(let exitCode, let killedBySignal, let stderr) = error else {
            Issue.record("Expected .processExited, got \(error)")
            return
        }
        #expect(exitCode == 1)
        #expect(!killedBySignal)
        #expect(
            stderr.contains("unsupported machine type"),
            "stderr should carry the reason QEMU gave up, got: \(stderr)"
        )
        // The whole point: the message reads as a diagnosis on its own.
        #expect(
            error.localizedDescription.contains("unsupported machine type"),
            "error description should include stderr, got: \(error.localizedDescription)"
        )
    }

    /// The early-exit check must short-circuit the socket wait. Waiting out the
    /// full 10-second retry budget is what made the original failure look like a
    /// connection problem.
    ///
    /// The budget is the assertion, so it is measured rather than left to
    /// `.hangBackstop`: a minute is the finest a time-limit trait can express, and
    /// this has to fail if the socket wait runs to *ten seconds*.
    @Test func earlyExitIsReportedWithoutWaitingOutTheSocketTimeout() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "fatal: no such file or directory" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let started = ContinuousClock.now
        await #expect(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        #expect(
            started.duration(to: .now) < .seconds(5),
            "Early exit should be detected well before the 10s socket timeout"
        )
    }

    // MARK: - Failures that used to escape this library's vocabulary

    /// A binary that cannot be spawned at all is a `QMPError`, not a raw
    /// `NSError` from Foundation.
    ///
    /// `Process.run()`'s error used to propagate untouched, so a caller saw
    /// `The file “qemu” doesn’t exist.` with nothing to say which file, or that
    /// launching a VM was what wanted it. The path is now part of the error.
    @Test func missingBinaryIsReportedAsALaunchFailure() async throws {
        let missing = NSTemporaryDirectory() + "definitely-not-qemu-\(UUID().uuidString)"
        let (process, _) = makeProcess(qemuPath: missing)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .processLaunchFailed(let path, _) = error else {
            Issue.record("Expected .processLaunchFailed, got \(error)")
            return
        }
        #expect(path == missing)
        #expect(
            error.localizedDescription.contains(missing),
            "The description should name the binary, got: \(error.localizedDescription)"
        )
    }

    /// A runtime directory that cannot be created is named as such, rather than
    /// surfacing as whatever `FileManager` happened to throw.
    @Test func uncreatableRuntimeDirectoryIsReportedAsItsOwnFailure() async throws {
        // A *file* where the base directory should be: creating anything beneath
        // it fails, and it fails before QEMU is ever spawned.
        let blocker = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-blocker-\(UInt32.random(in: .min ... .max))"
        )
        try "not a directory".write(toFile: blocker, atomically: true, encoding: .utf8)

        let process = QEMUProcess(
            qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive),
            runtimeDirectory: blocker,
            logger: Logger(label: "test")
        )

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .runtimeDirectoryCreationFailed(let path, _) = error else {
            Issue.record("Expected .runtimeDirectoryCreationFailed, got \(error)")
            return
        }
        #expect(path.hasPrefix(blocker + "/"), "Got \(path)")

        let isRunning = await process.isRunning
        #expect(!isRunning, "Nothing should have been spawned")
    }

    /// Cancelling a start reports `.cancelled`.
    ///
    /// The socket wait is where cancellation lands, and it used to throw
    /// `CancellationError` straight through an untyped `throws`. A typed-throws
    /// API cannot do that, so cancellation is a case of this library's own error
    /// rather than a type beside it.
    @Test func cancellingAStartIsReportedAsCancelled() async throws {
        // Never creates its socket, so the start sits in the retry loop.
        let (process, _) = makeProcess(qemuPath: try makeFakeQEMU(body: "sleep 30"))

        let config = Self.defaultConfig
        let start = Task { try await process.start(with: config) }
        try await Task.sleep(for: .milliseconds(200))
        start.cancel()

        let error = try await #require(throws: QMPError.self) { try await start.value }
        guard case .cancelled = error else {
            Issue.record("Expected .cancelled, got \(error)")
            return
        }
    }

    /// And so does cancelling a wait for exit.
    @Test func cancellingAWaitForExitIsReportedAsCancelled() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive))

        try await process.start(with: Self.defaultConfig)

        let wait = Task { try await process.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(200))
        wait.cancel()

        let error = try await #require(throws: QMPError.self) { try await wait.value }
        guard case .cancelled = error else {
            Issue.record("Expected .cancelled, got \(error)")
            return
        }
    }

    /// A process killed by a signal is reported as such rather than as an exit code.
    @Test func terminationBySignalIsDistinguishedFromExitCode() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "about to be killed" >&2
        kill -TERM $$
        sleep 5
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .processExited(let exitCode, let killedBySignal, _) = error else {
            Issue.record("Expected .processExited, got \(error)")
            return
        }
        #expect(killedBySignal, "SIGTERM should be reported as a signal")
        #expect(exitCode == SIGTERM)
    }

    /// Stderr is drained continuously and only the tail is retained. Writing far
    /// more than the 64KB pipe buffer is the case that used to take QEMU down
    /// when a `Pipe()` was attached without a reader.
    @Test func stderrIsDrainedBeyondThePipeBufferAndKeepsTheTail() async throws {
        let fake = try makeFakeQEMU(body: """
        awk 'BEGIN { for (i = 0; i < 4000; i++) print "qemu noise line " i }' >&2
        echo "FINAL_MARKER_9f3c" >&2
        exit 3
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .processExited(let exitCode, _, let stderr) = error else {
            Issue.record("Expected .processExited, got \(error)")
            return
        }
        #expect(exitCode == 3)
        #expect(stderr.contains("FINAL_MARKER_9f3c"), "The last thing written must survive")
        #expect(!stderr.contains("qemu noise line 0\n"), "Old output should have been dropped")
        #expect(
            stderr.utf8.count <= 16 * 1024,
            "Capture must stay bounded, got \(stderr.utf8.count) bytes"
        )
    }

    /// The capture outlives `stop()` so a caller cleaning up after a failure can
    /// still report what went wrong — the path `QEMUManager.createVM` takes.
    @Test func capturedStderrRemainsReadableAfterStop() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "could not open disk image /nope.qcow2" >&2
        exit 1
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        try? await process.start(with: Self.defaultConfig)
        await process.stop()

        let stderr = await process.capturedStderr
        #expect(
            stderr.contains("could not open disk image"),
            "Expected stderr to survive stop(), got: \(stderr)"
        )
    }

    /// A process that comes up normally still starts, and stderr capture does
    /// not interfere with the socket wait.
    @Test func startSucceedsWhenTheSocketAppears() async throws {
        let fake = try makeSocketCreatingQEMU(body: "sleep 30")
        let (process, _) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let isRunning = await process.isRunning
        let stderr = await process.capturedStderr
        #expect(isRunning)
        #expect(stderr == "", "A healthy start writes nothing to stderr")
    }

    // MARK: - Waiting for exit

    /// `waitUntilExit()` returns when the process actually exits.
    @Test func waitUntilExitReturnsWhenTheProcessExits() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 0.5"))

        try await process.start(with: Self.defaultConfig)
        try await process.waitUntilExit()

        let isRunning = await process.isRunning
        #expect(!isRunning)
    }

    /// A process that has already gone is a completed wait, not a wait forever.
    @Test func waitUntilExitReturnsImmediatelyForAnExitedProcess() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "exit 0"))

        try await process.start(with: Self.defaultConfig)
        try await Task.sleep(for: .milliseconds(300)) // certainly gone

        let started = ContinuousClock.now
        try await process.waitUntilExit()
        #expect(started.duration(to: .now) < .seconds(1))
    }

    /// The wait must be cancellable, and this is the shape that matters:
    /// `QEMUManager.shutdown()` races it against a timeout in a task group.
    ///
    /// Parked on a bare `withCheckedContinuation`, the wait ignored cancellation,
    /// so when the timeout leg won, the group's implicit drain waited on a task
    /// that would never finish — a shutdown that hung *past its own timeout*,
    /// never reaching the forced termination meant to follow. The budget is the
    /// assertion, and much tighter than `.hangBackstop`: the child sleeps 120s, so
    /// a wait that ignores cancellation shows up as ten seconds here, not sixty.
    @Test func waitUntilExitIsCancellableSoATimedWaitCanFinish() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))

        try await process.start(with: Self.defaultConfig)

        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: .milliseconds(500)) }
            group.addTask { try? await process.waitUntilExit() }
            await group.next()
            group.cancelAll()
        }
        let elapsed = started.duration(to: .now)

        let isRunning = await process.isRunning
        #expect(elapsed < .seconds(10), "Leaving the group took \(elapsed); the cancelled wait never returned")
        #expect(isRunning, "The process outlives a cancelled wait")
    }

    /// Cancelling one wait must not satisfy a later one — otherwise a subsequent
    /// `waitUntilExit()` reports a live process as finished.
    @Test func cancellingOneWaitDoesNotSatisfyTheNext() async throws {
        let (process, _) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 120"))

        try await process.start(with: Self.defaultConfig)

        let first = Task { try await process.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(200))
        first.cancel()
        _ = try? await first.value

        // The second wait must still be waiting on a process that is still alive.
        let second = Task { try await process.waitUntilExit() }
        try await Task.sleep(for: .milliseconds(500))
        let isRunning = await process.isRunning
        #expect(!second.isCancelled)
        #expect(isRunning)

        second.cancel()
        _ = try? await second.value

        await process.stop()
    }

    /// A process that lives but never creates the socket still reports the
    /// original socket failure rather than being misattributed to an exit.
    @Test func socketCreationFailureIsStillReportedWhenProcessStaysAlive() async throws {
        let fake = try makeFakeQEMU(body: """
        echo "warning: something odd" >&2
        sleep 30
        """)
        let (process, _) = makeProcess(qemuPath: fake)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .socketCreationFailed = error else {
            Issue.record("Expected .socketCreationFailed, got \(error)")
            return
        }
        let stderr = await process.capturedStderr
        #expect(
            stderr.contains("something odd"),
            "Live-process stderr should still be available to the caller"
        )

        await process.stop()
    }

    // MARK: - Stopping

    /// `stop()` must not return until the child has actually exited.
    ///
    /// It used to send SIGTERM and clear `process` in the next statement, so
    /// `isRunning` — derived from `process` — reported `false` over a QEMU that was
    /// still shutting down, and the socket file was deleted from under it. A caller
    /// polling `isRunning` saw a stopped VM that was still running.
    @Test func stopWaitsForTheProcessToActuallyExit() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.slowToTerminate(afterSeconds: 1))
        let (process, socketPath) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let startedRunning = await process.isRunning
        #expect(startedRunning)

        let started = ContinuousClock.now
        await process.stop(timeout: .seconds(10))
        let elapsed = started.duration(to: .now)

        let isRunning = await process.isRunning
        let pid = await process.processIdentifier
        #expect(
            elapsed > .milliseconds(500),
            "stop() returned in \(elapsed) without waiting out the child's shutdown"
        )
        #expect(!isRunning, "isRunning must be false once stop() returns")
        #expect(pid == nil, "The exited process should have been released")
        #expect(
            !FileManager.default.fileExists(atPath: socketPath),
            "The socket file should be removed once the process is gone"
        )
    }

    /// A QEMU that ignores SIGTERM — wedged, or stopped by job control — has to be
    /// killed outright. `destroy()` is documented as a force quit, and before this
    /// the forcing amounted to a single SIGTERM.
    @Test func stopEscalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        let fake = try makeSocketCreatingQEMU(body: """
        trap '' TERM
        \(Self.stayAlive)
        """)
        let (process, socketPath) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let startedRunning = await process.isRunning
        #expect(startedRunning)

        let started = ContinuousClock.now
        await process.stop(timeout: .seconds(1))
        let elapsed = started.duration(to: .now)

        let isRunning = await process.isRunning
        #expect(!isRunning, "SIGKILL should have taken down a process that ignored SIGTERM")
        #expect(elapsed < .seconds(10), "Escalation took \(elapsed); the second wait should be bounded too")
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    /// Stopping something that has already exited is cleanup, not an error — and it
    /// still has work to do, because the socket file outlives the process.
    @Test func stopCleansUpAfterAProcessThatAlreadyExited() async throws {
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
        #expect(!isRunning)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(
            stderr.contains("goodbye"),
            "Cleanup must not throw away the stderr a caller may still want to report"
        )
    }

    /// Stopping a process that was never started must not trip over its own
    /// bookkeeping.
    @Test func stopOnANeverStartedProcessIsHarmless() async throws {
        let (process, _) = makeProcess(qemuPath: "/nonexistent/qemu")

        await process.stop()

        let isRunning = await process.isRunning
        let pid = await process.processIdentifier
        #expect(!isRunning)
        #expect(pid == nil)
    }

    /// A restart after a completed `stop()` must be allowed — and must get a socket
    /// of its own rather than colliding with a leftover from the previous run.
    @Test func processCanBeRestartedAfterStop() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, _) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)
        let firstPID = await process.processIdentifier
        await process.stop(timeout: .seconds(5))

        try await process.start(with: Self.defaultConfig)
        let isRunning = await process.isRunning
        let secondPID = await process.processIdentifier
        #expect(isRunning)
        #expect(secondPID != firstPID, "The restart should be a new process")

        await process.stop(timeout: .seconds(5))
    }

    /// A second `start()` while the first process is alive is still refused. This is
    /// the guard that the old `stop()` used to defeat by nilling out `process` under
    /// a live QEMU, letting a restart reuse the same socket path as the survivor.
    @Test func startIsRefusedWhileAProcessIsAlreadyRunning() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)
        let (process, _) = makeProcess(qemuPath: fake)

        try await process.start(with: Self.defaultConfig)

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .processAlreadyRunning = error else {
            Issue.record("Expected .processAlreadyRunning, got \(error)")
            return
        }

        await process.stop(timeout: .seconds(5))
    }

    /// Dropping a `QEMUProcess` without stopping it used to leave QEMU running for
    /// the lifetime of the host process. Verified by watching the child's own
    /// heartbeat rather than the pid, which stays visible while it is a zombie.
    @Test func droppingTheProcessKillsAStillRunningChild() async throws {
        let heartbeat = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-heartbeat-\(UUID().uuidString)"
        )

        let fake = try makeSocketCreatingQEMU(body: """
        while :; do
            echo tick >> "\(heartbeat)"
            sleep 0.05
        done
        """)
        let socketPath = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-test-\(UUID().uuidString).sock"
        )

        var process: QEMUProcess? = QEMUProcess(
            qemuPath: fake,
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )
        try await process?.start(with: Self.defaultConfig)

        try await Task.sleep(for: .milliseconds(300))
        #expect(ticks(in: heartbeat) > 0, "The fake QEMU should be ticking before it is dropped")

        process = nil // deinit: the only thing left that can stop the child

        try await Task.sleep(for: .milliseconds(400))
        let afterRelease = ticks(in: heartbeat)
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            ticks(in: heartbeat) == afterRelease,
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
    @Test func defaultSocketLivesInAPrivateDirectory() async throws {
        let process = makeManagedProcess(qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive))
        let socketPath = process.getQMPSocketPath()
        let directory = Self.directory(containing: socketPath)

        #expect(
            (socketPath as NSString).lastPathComponent == "qmp.sock",
            "A short fixed name inside a private directory, not a UUID in a shared one"
        )
        #expect(
            directory != (NSTemporaryDirectory() as NSString).standardizingPath,
            "The socket must not sit directly in the shared temporary directory"
        )

        try await process.start(with: Self.defaultConfig)

        #expect(FileManager.default.fileExists(atPath: socketPath))
        #expect(
            Self.mode(of: directory) == 0o700,
            "Directory permissions are the access control for a unix socket"
        )
    }

    /// Teardown removes the whole private directory, not just the socket inside it.
    @Test func privateSocketDirectoryIsRemovedOnStop() async throws {
        let process = makeManagedProcess(qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive))
        let directory = Self.directory(containing: process.getQMPSocketPath())

        try await process.start(with: Self.defaultConfig)
        #expect(FileManager.default.fileExists(atPath: directory))

        await process.stop(timeout: .seconds(5))

        #expect(
            !FileManager.default.fileExists(atPath: directory),
            "The directory this instance created is its own to remove"
        )
    }

    /// Two instances must not share a directory, or one VM's teardown would delete
    /// the other's socket.
    @Test func eachInstanceGetsItsOwnDirectory() {
        let first = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))
        let second = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))

        #expect(first.getQMPSocketPath() != second.getQMPSocketPath())
    }

    /// The base directory is injectable, for callers who want the socket somewhere
    /// other than the temporary directory — `XDG_RUNTIME_DIR`, say.
    @Test func runtimeDirectoryIsInjectable() async throws {
        // Short on purpose: a UUID here and the socket beneath it no longer fits in
        // `sun_path` on macOS, which is the budget this whole scheme is working to.
        let base = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-rt-\(UInt32.random(in: .min ... .max))"
        )

        let process = makeManagedProcess(
            qemuPath: try makeSocketCreatingQEMU(body: Self.stayAlive),
            runtimeDirectory: base
        )
        let socketPath = process.getQMPSocketPath()
        #expect(socketPath.hasPrefix(base + "/"), "Got \(socketPath)")

        // The base does not have to exist beforehand.
        try await process.start(with: Self.defaultConfig)
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    /// The whole point of dropping the UUID from the filename: a unix socket path
    /// has about 100 bytes to work with, and macOS spends half of them on the
    /// temporary directory before this library adds anything.
    @Test func defaultSocketPathFitsInSunPath() {
        let process = QEMUProcess(qemuPath: "/nonexistent/qemu", logger: Logger(label: "test"))
        let length = process.getQMPSocketPath().utf8.count

        #expect(
            length < QEMUProcess.maxSocketPathLength,
            "Path is \(length) bytes: \(process.getQMPSocketPath())"
        )
    }

    /// An over-long path is named as such, rather than presenting as a socket that
    /// never appears — which is how a bind failure otherwise reaches a caller.
    @Test func overLongSocketPathIsRejectedWithItsOwnError() async throws {
        let process = QEMUProcess(
            qemuPath: "/nonexistent/qemu",
            runtimeDirectory: NSTemporaryDirectory() + String(repeating: "d", count: 200),
            logger: Logger(label: "test")
        )

        let error = try await #require(throws: QMPError.self) {
            try await process.start(with: Self.defaultConfig)
        }
        guard case .socketPathTooLong(_, let limit) = error else {
            Issue.record("Expected .socketPathTooLong, got \(error)")
            return
        }
        #expect(limit == QEMUProcess.maxSocketPathLength)
    }

    /// A caller-supplied path is bound and cleaned up, but never treated as
    /// something to delete recursively. `removeItem` on a directory takes
    /// everything under it, and this path comes from outside.
    @Test func callerSuppliedPathThatIsADirectoryIsNotDeleted() async throws {
        let directory = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-not-a-socket-\(UUID().uuidString)"
        )
        let bystander = directory + "/precious.txt"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "do not delete".write(toFile: bystander, atomically: true, encoding: .utf8)

        let process = QEMUProcess(
            qemuPath: try makeFakeQEMU(body: "exit 1"),
            qmpSocketPath: directory,
            logger: Logger(label: "test")
        )

        try? await process.start(with: Self.defaultConfig)
        await process.stop()

        #expect(FileManager.default.fileExists(atPath: bystander), "The directory was deleted")
    }

    /// Dropping the process cleans up its directory too, not just the socket.
    @Test func droppingTheProcessRemovesItsPrivateDirectory() async throws {
        let fake = try makeSocketCreatingQEMU(body: Self.stayAlive)

        var process: QEMUProcess? = QEMUProcess(qemuPath: fake, logger: Logger(label: "test"))
        let directory = temporaryFiles.track(
            Self.directory(containing: process!.getQMPSocketPath())
        )

        try await process?.start(with: Self.defaultConfig)
        #expect(FileManager.default.fileExists(atPath: directory))

        process = nil

        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    // MARK: - Debug log files

    /// The debug log is guest output — with `-nographic` it is the guest console —
    /// so it belongs in the private directory too, and not in a world-readable
    /// `/tmp/qemu-*.log`.
    ///
    /// It also has to outlive the VM: a log you cannot read after the thing you
    /// were debugging exits is no use, so this is the one case where teardown
    /// leaves the directory behind. The suite is `.serialized` because of the
    /// `setenv` here.
    @Test func logFileIsPrivateAndOutlivesTheVM() async throws {
        setenv("ENABLE_QEMU_PROCESS_LOG_FILES", "true", 1)
        defer { unsetenv("ENABLE_QEMU_PROCESS_LOG_FILES") }

        let fake = try makeSocketCreatingQEMU(body: """
        echo "guest console output"
        \(Self.stayAlive)
        """)
        let process = makeManagedProcess(qemuPath: fake)
        let directory = Self.directory(containing: process.getQMPSocketPath())

        try await process.start(with: Self.defaultConfig)
        await process.stop(timeout: .seconds(5))

        #expect(
            FileManager.default.fileExists(atPath: directory),
            "A directory holding a log the caller asked for must survive teardown"
        )
        #expect(Self.mode(of: directory) == 0o700)

        let logs = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".log") }
        #expect(logs.count == 1, "Expected exactly one log, got \(logs)")

        let logPath = directory + "/" + (logs.first ?? "")
        #expect(Self.mode(of: logPath) == 0o600, "The log is guest output; keep it to the owner")
        #expect(
            (try String(contentsOfFile: logPath, encoding: .utf8)).contains("guest console output"),
            "stdout should still be reaching the log"
        )
        #expect(
            !FileManager.default.fileExists(atPath: process.getQMPSocketPath()),
            "The socket still goes, even when the directory stays"
        )
    }

    // MARK: - Concurrent access

    /// Reading status while a start is still in flight.
    ///
    /// This is the shape `QEMUManager.createVM` takes: a task-group child runs
    /// `start(with:)` — which writes `child` and `stderrCapture` — while another
    /// leg reads `isRunning`/`capturedStderr` off the failure path. As a
    /// `@unchecked Sendable` class that overlap was an unsynchronized read of
    /// mutable fields; as an actor the reads interleave at the start's suspension
    /// points instead.
    ///
    /// Against the class this test reports two races under
    /// `swift test --sanitize=thread` — the writes of `stderrCapture` and `process`
    /// in `start(with:)` against these reads — and none against the actor. Without
    /// a sanitizer it still asserts the observable half: the concurrent reads see
    /// the stderr QEMU has already written rather than an empty value.
    @Test func statusCanBeReadConcurrentlyWithAStartInFlight() async throws {
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
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(
            sawStderrDuringStart,
            "Concurrent readers should see stderr while start(with:) is still running"
        )
        #expect(!start.isCancelled)

        start.cancel()
        _ = try? await start.value
    }

    /// Many readers at once, which is only meaningful now that they serialize on
    /// the actor. Also pins `getQMPSocketPath()` as callable without `await`, since
    /// the path is fixed at init and `QEMUManager` reads it that way.
    @Test func concurrentReadersAgreeOnState() async throws {
        let (process, socketPath) = makeProcess(qemuPath: try makeSocketCreatingQEMU(body: "sleep 30"))

        #expect(process.getQMPSocketPath() == socketPath)

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

        #expect(running.count == 32)
        #expect(running.allSatisfy { $0 }, "Every reader should see the same live process")
    }
}
