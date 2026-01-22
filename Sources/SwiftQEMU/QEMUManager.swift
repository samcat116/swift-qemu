import Foundation
import Logging

/// High-level QEMU VM manager combining process and QMP management
public actor QEMUManager {
    private let logger: Logger
    private let process: QEMUProcess
    private let qmpClient: QMPClient
    private var isConnected = false
    
    /// Current VM status
    public private(set) var status: QEMUVMStatus = .stopped
    
    public init(
        qemuPath: String = "/usr/bin/qemu-system-x86_64",
        logger: Logger = Logger(label: "SwiftQEMU.QEMUManager")
    ) {
        self.logger = logger
        self.process = QEMUProcess(qemuPath: qemuPath, logger: logger)
        self.qmpClient = QMPClient(logger: logger)
    }
    
    // MARK: - VM Lifecycle
    
    /// Create and start a VM with the given configuration
    /// - Parameters:
    ///   - config: The QEMU VM configuration
    ///   - timeout: Timeout in seconds for the entire operation (default: 30)
    public func createVM(config: QEMUConfiguration, timeout: TimeInterval = 30) async throws {
        guard !process.isRunning else {
            throw QMPError.processAlreadyRunning
        }

        logger.info("Creating QEMU VM")
        status = .creating

        do {
            // Wrap entire operation in a timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw QMPError.timeout
                }

                // Main creation task
                group.addTask {
                    // Start QEMU process
                    try await self.process.start(with: config)

                    // Connect to QMP
                    let socketPath = self.process.getQMPSocketPath()
                    try await self.qmpClient.connectUnix(path: socketPath)
                }

                // Wait for first task to complete (either timeout or creation)
                do {
                    _ = try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            // Success path
            isConnected = true
            await updateStatus()
            logger.info("QEMU VM created successfully")

        } catch {
            // Cleanup on any failure
            logger.error("Failed to create QEMU VM: \(error)")

            // Reset state
            isConnected = false
            status = .stopped

            // Clean up process if it was started
            if process.isRunning {
                logger.warning("Cleaning up orphaned QEMU process")
                process.stop()
            }

            throw error
        }
    }
    
    /// Start/resume VM execution
    public func start() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Starting VM")
        
        try await qmpClient.cont()
        status = .running
        
        logger.info("VM started")
    }
    
    /// Pause VM execution
    public func pause() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Pausing VM")
        
        try await qmpClient.stop()
        status = .paused
        
        logger.info("VM paused")
    }
    
    /// Reset the VM
    public func reset() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Resetting VM")
        
        try await qmpClient.systemReset()
        await updateStatus()
        
        logger.info("VM reset")
    }
    
    /// Shutdown the VM gracefully
    public func shutdown() async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }
        
        logger.info("Shutting down VM")
        
        try await qmpClient.systemPowerdown()
        status = .shuttingDown
        
        // Wait for shutdown with timeout
        // Wait for shutdown with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            }
            
            group.addTask {
                try await self.process.waitUntilExit()
            }
            
            // Wait for first task to complete (either timeout or shutdown)
            _ = try await group.next()
            group.cancelAll()
        }
        
        if process.isRunning {
            logger.warning("VM did not shut down gracefully, forcing termination")
            try await destroy()
        } else {
            status = .stopped
            isConnected = false
        }
        
        logger.info("VM shutdown complete")
    }
    
    /// Force quit the VM
    public func destroy() async throws {
        logger.info("Destroying VM")
        
        if isConnected {
            do {
                try await qmpClient.quit()
            } catch {
                logger.debug("QMP quit failed, process may already be terminating")
            }
            
            try await qmpClient.disconnect()
            isConnected = false
        }
        
        process.stop()
        status = .stopped
        
        logger.info("VM destroyed")
    }
    
    /// Get current VM status
    public func getStatus() async throws -> QEMUVMStatus {
        guard isConnected else {
            return .stopped
        }
        
        await updateStatus()
        return status
    }
    
    /// Update status from QMP
    private func updateStatus() async {
        do {
            let qmpStatus = try await qmpClient.queryStatus()

            switch qmpStatus.status.lowercased() {
            case "running":
                status = qmpStatus.running ? .running : .paused
            case "paused", "suspended":
                status = .paused
            case "shutdown", "poweroff":
                status = .stopped
            case "inmigrate", "prelaunch":
                status = .creating
            default:
                logger.warning("Unknown QMP status: \(qmpStatus.status)")
                status = .unknown
            }
        } catch {
            logger.error("Failed to query VM status: \(error)")
            status = .unknown
        }
    }

    // MARK: - Disk Hot-Plug Operations

    /// Attach a disk to a running VM
    /// - Parameters:
    ///   - path: Path to the qcow2 disk image
    ///   - deviceName: Name for the device (e.g., "vdb")
    ///   - readOnly: Whether the disk should be read-only
    public func attachDisk(path: String, deviceName: String, readOnly: Bool = false) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let nodeName = "drive-\(deviceName)"

        logger.info("Attaching disk", metadata: [
            "path": .string(path),
            "deviceName": .string(deviceName),
            "readOnly": .stringConvertible(readOnly)
        ])

        // Step 1: Add block device backend
        try await qmpClient.blockdevAdd(nodeName: nodeName, filename: path, readOnly: readOnly)

        // Step 2: Add virtio-blk frontend
        do {
            try await qmpClient.deviceAdd(deviceId: deviceName, driveId: nodeName)
        } catch {
            // Rollback: remove the block device if frontend fails
            try? await qmpClient.blockdevDel(nodeName: nodeName)
            throw error
        }

        logger.info("Disk attached successfully", metadata: ["deviceName": .string(deviceName)])
    }

    /// Detach a disk from a running VM
    /// - Parameter deviceName: The device name to detach (e.g., "vdb")
    public func detachDisk(deviceName: String) async throws {
        guard isConnected else {
            throw QMPError.notConnected
        }

        let nodeName = "drive-\(deviceName)"

        logger.info("Detaching disk", metadata: ["deviceName": .string(deviceName)])

        // Step 1: Remove the device frontend (waits for DEVICE_DELETED event)
        try await qmpClient.deviceDel(deviceId: deviceName)

        // Step 2: Remove the block device backend
        try await qmpClient.blockdevDel(nodeName: nodeName)

        logger.info("Disk detached successfully", metadata: ["deviceName": .string(deviceName)])
    }

    /// List attached block devices
    public func listDisks() async throws -> [AnyCodable] {
        guard isConnected else {
            throw QMPError.notConnected
        }
        return try await qmpClient.queryBlock()
    }
}

// MARK: - VM Status

public enum QEMUVMStatus: String, Codable, Sendable {
    case stopped
    case creating
    case running
    case paused
    case shuttingDown
    case unknown
}

