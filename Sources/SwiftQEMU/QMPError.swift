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
    /// A single inbound QMP frame exceeded the configured maximum, so the connection
    /// was dropped rather than buffered further. Carries the limit in bytes.
    case frameTooLarge(limit: Int)
    /// There was nowhere to hot-plug the device: the machine type refuses hot-plug
    /// on its default bus and no free `pcie-root-port` was left to target. Thrown
    /// before anything is sent to QEMU, and names the configuration knob that fixes
    /// it — which is the whole point, since QEMU's own answer
    /// (`Bus 'pcie.0' does not support hotplugging`) names nothing actionable.
    case noHotplugPortAvailable(machineType: String, portCount: Int, inUse: Int)
    /// QEMU refused `device_add` because the target bus does not support hot-plug.
    /// The `qmpError` this replaces said which bus, but not what to do about it.
    case hotplugNotSupported(bus: String, machineType: String)

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
        case .frameTooLarge(let limit):
            return "A QMP message exceeded the \(limit) byte frame limit; the connection was closed"
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