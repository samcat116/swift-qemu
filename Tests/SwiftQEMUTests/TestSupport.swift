import Foundation
import Logging
import Synchronization
import Testing
@testable import SwiftQEMU

// Shared machinery for the Swift Testing suites: the traits that gate and bound
// them, the lookup for a real QEMU, scope-bounded cleanup, and the two event
// collectors that used to be copied into every suite that needed one.

// MARK: - Traits

extension Trait where Self == ConditionTrait {

    /// Enabled only where a real `qemu-system-x86_64` is installed.
    ///
    /// This replaces `throw XCTSkip(...)` from inside the test body. The
    /// difference is not cosmetic: a condition trait is evaluated before the test
    /// runs, so a machine without QEMU reports these as skipped without first
    /// building fixtures for a test that was never going to run.
    static var requiresQEMU: Self {
        .enabled(if: QEMUFixtures.systemBinary != nil, "qemu-system-x86_64 is not installed")
    }

    /// Enabled only where both `qemu-system-x86_64` and `qemu-img` are installed —
    /// hot-plug needs a real image to attach, not just a VM to attach it to.
    static var requiresQEMUAndImageTool: Self {
        .enabled(
            if: QEMUFixtures.systemBinary != nil && QEMUFixtures.imageTool != nil,
            "qemu-system-x86_64 and qemu-img are not both installed"
        )
    }
}

extension Trait where Self == TimeLimitTrait {

    /// A backstop for the hang regressions, which is most of what this suite is.
    ///
    /// Nearly every bug these tests cover made a caller wait forever rather than
    /// fail: a greeting that arrived before its waiter, a peer that accepted and
    /// never spoke, a cancelled wait with nothing left to resume it, a timeout that
    /// hung. Under XCTest a regression in any of them stopped the run instead of
    /// failing it, which is the worst way to find out about it in CI.
    ///
    /// A minute is the *finest* limit the trait accepts — `TimeLimitTrait.Duration`
    /// deliberately offers nothing below `.minutes(_:)` — so this is a hang
    /// detector, not a performance budget. Where a specific budget is the actual
    /// assertion (an early exit that must beat the 10s socket wait, a cancellation
    /// that must not wait out a 60s timeout), the test still measures it against
    /// `ContinuousClock` and says so.
    static var hangBackstop: Self { .timeLimit(.minutes(1)) }

    /// The same, for tests that boot a real VM and wait on a guest.
    static var slowHangBackstop: Self { .timeLimit(.minutes(2)) }
}

// MARK: - A real QEMU

/// Where a real QEMU is, if there is one.
///
/// Resolved once: the answer cannot change during a run, and `.requiresQEMU` asks
/// for it while deciding whether a test is enabled at all.
enum QEMUFixtures {

    static let systemBinary: String? = firstExecutable(of: [
        "/opt/homebrew/bin/qemu-system-x86_64",
        "/usr/local/bin/qemu-system-x86_64",
        "/usr/bin/qemu-system-x86_64"
    ])

    static let imageTool: String? = firstExecutable(of: [
        "/opt/homebrew/bin/qemu-img",
        "/usr/local/bin/qemu-img",
        "/usr/bin/qemu-img"
    ])

    /// The installed binary, for a test already gated on `.requiresQEMU`.
    static func requireSystemBinary(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        try #require(systemBinary, "gate this test on .requiresQEMU", sourceLocation: sourceLocation)
    }

    private static func firstExecutable(of candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Cleanup

/// Filesystem paths to remove once the test that made them is over.
///
/// Swift Testing gives every test its own instance of its suite type and releases
/// it when the test ends, so a suite that holds one of these gets its files
/// cleaned up without registering anything — the replacement for `tearDown` and
/// the synchronous half of `addTeardownBlock`.
///
/// What has no equivalent hook is *asynchronous* cleanup: a `deinit` cannot await.
/// So anything whose teardown has to be awaited — stopping a VM — is bounded by a
/// scope instead (`withVM`, `withProcess`), and this handles only the paths.
final class TemporaryFiles: Sendable {

    private let paths = Mutex<[String]>([])

    /// Register `path` for removal and hand it straight back, so it can be used
    /// inline where the path is built.
    @discardableResult
    func track(_ path: String) -> String {
        paths.withLock { $0.append(path) }
        return path
    }

    func removeAll() {
        let tracked = paths.withLock { paths -> [String] in
            defer { paths = [] }
            return paths
        }
        for path in tracked {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    deinit { removeAll() }
}

/// Create a VM from `config`, run `body` against it, and destroy it afterwards —
/// including when `body` throws or an expectation in it fails hard.
///
/// This is the shape asynchronous cleanup takes without a teardown hook: a VM's
/// lifetime is a scope rather than something registered against the test.
/// `QEMUProcess.deinit` would SIGKILL a child that outlived its manager anyway, so
/// what this really preserves is the *graceful* teardown — and the guarantee that
/// it happens before the next test boots a VM of its own.
///
/// Only for tests gated on `.requiresQEMU`: `config` is passed through untouched,
/// so a caller still owns the memory size and everything else the test is about.
func withVM<R>(
    _ config: QEMUConfiguration,
    _ body: (QEMUManager) async throws -> R
) async throws -> R {
    let manager = QEMUManager(
        qemuPath: try QEMUFixtures.requireSystemBinary(),
        logger: Logger(label: "test")
    )
    do {
        try await manager.createVM(config: config)
        let result = try await body(manager)
        try? await manager.destroy()
        return result
    } catch {
        try? await manager.destroy()
        throw error
    }
}

// MARK: - Event collection

/// Reading an event stream without risking the run.
///
/// A bare `for await` over a stream that regressed hangs the test rather than
/// failing it. `.hangBackstop` would eventually cut that short, but a minute per
/// affected test is a poor way to learn that no events arrived — these bound the
/// wait to the scale of the thing being tested and return what they got.
enum QMPEvents {

    /// Take up to `count` events, giving up after `timeout`.
    static func collect(
        _ count: Int,
        from stream: AsyncStream<QMPEvent>,
        timeout: Duration = .seconds(5)
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
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// Drain a stream until it *finishes*, returning `nil` if it has not within
    /// `timeout`.
    ///
    /// The distinction matters: a stream that never ends and a stream that ends
    /// having produced nothing both look like "no events", and only the second one
    /// is correct. Anything asserting on completion has to be able to tell them
    /// apart.
    static func drainUntilFinished(
        _ stream: AsyncStream<QMPEvent>,
        timeout: Duration = .seconds(3)
    ) async -> [QMPEvent]? {
        await withTaskGroup(of: [QMPEvent]?.self) { group in
            group.addTask {
                var collected: [QMPEvent] = []
                for await event in stream {
                    collected.append(event)
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
