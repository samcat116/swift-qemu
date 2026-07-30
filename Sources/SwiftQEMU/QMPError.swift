import Foundation

/// Errors that can occur when interacting with QEMU
public enum QMPError: Error, LocalizedError {
    case notConnected
    case connectionLost
    case invalidResponse
    case qmpError(String, String)
    case processNotRunning
    case processAlreadyRunning
    case invalidConfiguration
    case socketCreationFailed
    case timeout
    /// QEMU exited before the QMP socket was ready, carrying its stderr so the cause
    /// (a rejected argument, a missing disk image) is in the error itself.
    case processExited(exitCode: Int32, killedBySignal: Bool, stderr: String)
    /// The QEMU process outlived both SIGTERM and SIGKILL, so a force quit could not
    /// deliver what it promises. Carries the pid of the survivor.
    case processTerminationFailed(pid: Int32?)
    /// The QMP socket path does not fit in `sockaddr_un.sun_path` (104 bytes on
    /// Darwin, 108 on Linux). QEMU would fail to bind, which reaches a caller only
    /// as a socket that never appears.
    case socketPathTooLong(path: String, limit: Int)

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
        case .socketPathTooLong(let path, let limit):
            return """
            QMP socket path is \(path.utf8.count) bytes, over the \(limit)-byte \
            limit for a unix socket: \(path)
            """
        }
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