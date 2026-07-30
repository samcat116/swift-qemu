import Foundation

/// Errors that can occur when interacting with QEMU.
///
/// This is the *whole* failure vocabulary of the library: every throwing member
/// of the public API is `throws(QMPError)`, so a caller's `switch` over these
/// cases is one the compiler can check for exhaustiveness. That is why the
/// cases below include ones that only wrap somebody else's error —
/// `processLaunchFailed`, `connectionFailed`, `underlying`. A raw `NSError` from
/// `Process.run()` used to reach callers with nothing to say it came from
/// spawning QEMU; now the case it arrives in says so, and the original is still
/// attached.
public enum QMPError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionLost
    case invalidResponse
    case qmpError(String, String)
    case processNotRunning
    case processAlreadyRunning
    case invalidConfiguration
    case socketCreationFailed
    case timeout
    /// The awaiting task was cancelled.
    ///
    /// This is where `CancellationError` lands. A typed-throws API cannot throw
    /// it, so cancellation has to be part of this vocabulary rather than beside
    /// it — a caller that used to write `catch is CancellationError` now writes
    /// `catch QMPError.cancelled`, and `Task.isCancelled` is unaffected either
    /// way.
    case cancelled
    /// QEMU exited before the QMP socket was ready, carrying its stderr so the cause
    /// (a rejected argument, a missing disk image) is in the error itself.
    case processExited(exitCode: Int32, killedBySignal: Bool, stderr: String)
    /// The QEMU process outlived both SIGTERM and SIGKILL, so a force quit could not
    /// deliver what it promises. Carries the pid of the survivor.
    case processTerminationFailed(pid: Int32?)
    /// A single inbound QMP frame exceeded the configured maximum, so the connection
    /// was dropped rather than buffered further. Carries the limit in bytes.
    case frameTooLarge(limit: Int)
    /// The QMP socket path does not fit in `sockaddr_un.sun_path` (104 bytes on
    /// Darwin, 108 on Linux). QEMU would fail to bind, which reaches a caller only
    /// as a socket that never appears.
    case socketPathTooLong(path: String, limit: Int)
    /// There was nowhere to hot-plug the device: the machine type refuses hot-plug
    /// on its default bus and no free `pcie-root-port` was left to target. Thrown
    /// before anything is sent to QEMU, and names the configuration knob that fixes
    /// it — which is the whole point, since QEMU's own answer
    /// (`Bus 'pcie.0' does not support hotplugging`) names nothing actionable.
    case noHotplugPortAvailable(machineType: String, portCount: Int, inUse: Int)
    /// QEMU refused `device_add` because the target bus does not support hot-plug.
    /// The `qmpError` this replaces said which bus, but not what to do about it.
    case hotplugNotSupported(bus: String, machineType: String)
    /// QEMU could not be spawned at all: the binary is missing, is not
    /// executable, or the fork failed. Carries `Process.run()`'s own error,
    /// which used to propagate raw with nothing to say where it came from.
    case processLaunchFailed(path: String, underlying: any Error)
    /// The private `0700` directory that holds the QMP socket could not be
    /// created, so there is nowhere safe to put it.
    case runtimeDirectoryCreationFailed(path: String, underlying: any Error)
    /// The QMP socket could not be connected to. For a unix socket this is
    /// thrown only once the retry budget is spent, and carries the last
    /// attempt's error — a NIO or POSIX one, hence the wrapper.
    case connectionFailed(endpoint: String, underlying: any Error)
    /// A QMP command could not be encoded, so nothing was sent.
    case requestEncodingFailed(command: String, underlying: any Error)
    /// An error from outside this library's own vocabulary.
    ///
    /// The typed-throws surface maps everything into `QMPError`, and this is the
    /// case for whatever has no more specific home — a Foundation or NIO error
    /// reaching a boundary that did not anticipate it. Deliberately kept: a
    /// wrapper that silently rewrote such an error as one of the named cases
    /// would be lying about what happened.
    case underlying(any Error)

    /// Bring an arbitrary error into this domain.
    ///
    /// Used where an untyped API — a `CheckedContinuation`, a task group —
    /// hands back `any Error` at a boundary that is declared `throws(QMPError)`.
    /// Total by construction: anything unrecognised keeps its identity inside
    /// ``underlying(_:)`` rather than being mapped onto a case it is not.
    public static func wrapping(_ error: any Error) -> QMPError {
        switch error {
        case let error as QMPError: return error
        case is CancellationError: return .cancelled
        default: return .underlying(error)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to QEMU"
        case .connectionLost:
            return "Connection to QEMU was lost"
        case .invalidResponse:
            return "Invalid response from QEMU"
        case .qmpError(let errorClass, let description):
            return "QMP error (\(errorClass)): \(description)"
        case .processNotRunning:
            return "QEMU process is not running"
        case .processAlreadyRunning:
            return "QEMU process is already running"
        case .invalidConfiguration:
            return "Invalid QEMU configuration"
        case .socketCreationFailed:
            return "Failed to create QMP socket"
        case .timeout:
            return "Operation timed out"
        case .cancelled:
            return "The operation was cancelled"
        case .processExited(let exitCode, let killedBySignal, let stderr):
            let cause = killedBySignal ? "was killed by signal \(exitCode)" : "exited with code \(exitCode)"
            let detail = QMPError.lastLines(of: stderr)
            guard !detail.isEmpty else {
                return "QEMU \(cause) before the QMP socket was ready (no stderr output)"
            }
            return "QEMU \(cause) before the QMP socket was ready: \(detail)"
        case .processTerminationFailed(let pid):
            let which = pid.map { "process \($0)" } ?? "process"
            return "QEMU \(which) is still running after SIGTERM and SIGKILL"
        case .frameTooLarge(let limit):
            return "A QMP message exceeded the \(limit) byte frame limit; the connection was closed"
        case .socketPathTooLong(let path, let limit):
            return """
            QMP socket path is \(path.utf8.count) bytes, over the \(limit)-byte \
            limit for a unix socket: \(path)
            """
        case .noHotplugPortAvailable(let machineType, let portCount, let inUse):
            guard portCount > 0 else {
                return """
                    Machine type '\(machineType)' does not support hot-plug on its default bus, \
                    and this VM was started with no PCIe root ports to plug into. \
                    Set QEMUConfiguration.hotplugPorts to .automatic or .count(n) before \
                    starting the VM, or pass an explicit `bus` to attachDisk.
                    """
            }
            return """
                All \(portCount) pre-created PCIe root ports are in use (\(inUse) attached device\
                \(inUse == 1 ? "" : "s")), and machine type '\(machineType)' cannot hot-plug onto \
                its default bus. Detach a disk, or start the VM with \
                QEMUConfiguration.hotplugPorts = .count(\(portCount + 1)) or more.
                """
        case .hotplugNotSupported(let bus, let machineType):
            return """
                QEMU refused to hot-plug onto bus '\(bus)' of machine type '\(machineType)': \
                that bus does not support hot-plug. Pre-create PCIe root ports with \
                QEMUConfiguration.hotplugPorts, or target a bus that accepts hot-plug.
                """
        case .processLaunchFailed(let path, let underlying):
            return "Could not launch QEMU at \(path): \(QMPError.describe(underlying))"
        case .runtimeDirectoryCreationFailed(let path, let underlying):
            return """
                Could not create the private QEMU runtime directory at \(path): \
                \(QMPError.describe(underlying))
                """
        case .connectionFailed(let endpoint, let underlying):
            return "Could not connect to the QMP socket at \(endpoint): \(QMPError.describe(underlying))"
        case .requestEncodingFailed(let command, let underlying):
            return "Could not encode the QMP command '\(command)': \(QMPError.describe(underlying))"
        case .underlying(let underlying):
            return QMPError.describe(underlying)
        }
    }

    /// The wrapped error's own message. `localizedDescription` rather than
    /// `"\(error)"`: the errors that land here are `NSError`s from Foundation and
    /// NIO, which print as a domain-and-code blob but describe themselves well.
    private static func describe(_ error: any Error) -> String {
        error.localizedDescription
    }

    /// Keep error messages to the tail of stderr, which is where QEMU puts the reason
    /// it gave up.
    private static func lastLines(of stderr: String, count: Int = 10) -> String {
        let lines = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }
}

// MARK: - Cancellable sleep

/// `Task.sleep(for:)` brought into this library's error domain.
///
/// Cancellation is the only thing `Task.sleep` reports, so the conversion is
/// total; a `throws(QMPError)` caller would otherwise have to spell the same
/// three-line `do`/`catch` out at every wait.
func sleepOrCancel(for duration: Duration) async throws(QMPError) {
    do {
        try await Task.sleep(for: duration)
    } catch {
        throw .cancelled
    }
}
