import XCTest
import Logging
@testable import SwiftQEMU

/// Tests for disk hot-plug on a PCIe machine type.
///
/// The failure these cover: `machineType` defaults to `q35`, whose `pcie.0` is a
/// PCIe root complex and refuses hot-plug outright, and `attachDisk` named no bus.
/// So `device_add` came back with `Bus 'pcie.0' does not support hotplugging` and
/// hot-plug was unusable under the library's own defaults. A root port is the only
/// thing a PCIe complex will hot-plug into, and a root port cannot itself be
/// hot-plugged — it has to be on the command line at launch, which is why this is a
/// configuration concern and not something `attachDisk` can fix on its own.
///
/// Every QEMU behaviour asserted here was verified against QEMU 11.0.2 over a raw
/// QMP socket before being encoded: q35 and arm `virt` refuse hot-plug on `pcie.0`
/// and accept it through a root port, `pc` accepts it on `pci.0` directly, a root
/// port holds exactly one device, two root ports without `chassis` stop QEMU from
/// starting, and `microvm` has no PCI bus to put a root port on at all.
final class QEMUHotplugTests: XCTestCase {

    // MARK: - Helpers

    private func arguments(for config: QEMUConfiguration) -> [String] {
        QEMUProcess(
            qemuPath: "/nonexistent/qemu-system-x86_64",
            qmpSocketPath: "/tmp/unused.sock",
            logger: Logger(label: "test")
        ).buildArguments(from: config)
    }

    /// Every `-device` value that declares a `pcie-root-port`, in argument order.
    private func rootPortDevices(in args: [String]) -> [String] {
        var devices: [String] = []
        for (index, arg) in args.enumerated() where arg == "-device" && index + 1 < args.count {
            let value = args[index + 1]
            if value.hasPrefix("pcie-root-port") { devices.append(value) }
        }
        return devices
    }

    /// The value of one comma-separated property of a `-device` argument.
    private func property(_ key: String, of device: String) -> String? {
        device
            .split(separator: ",")
            .compactMap { part -> String? in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, pair[0] == key else { return nil }
                return String(pair[1])
            }
            .first
    }

    // MARK: - The default configuration

    /// The headline of the bug: what a caller gets without configuring anything.
    func testDefaultConfigurationPreCreatesRootPortsForHotplug() {
        let config = QEMUConfiguration()
        let ports = rootPortDevices(in: arguments(for: config))

        XCTAssertEqual(config.machineType, "q35", "the machine type this all hinges on")
        XCTAssertEqual(
            ports.count, QEMUConfiguration.automaticHotplugPortCount,
            "q35 cannot hot-plug onto pcie.0, so the default config must ship root ports"
        )
        XCTAssertEqual(config.resolvedHotplugPortCount, ports.count)
    }

    /// `chassis` is not decoration: two root ports that both leave it unset take
    /// QEMU down at startup with `Can't add chassis slot, error -16`.
    func testEachRootPortCarriesItsOwnChassisNumber() {
        let ports = rootPortDevices(in: arguments(for: QEMUConfiguration()))
        let chassis = ports.compactMap { property("chassis", of: $0) }

        XCTAssertEqual(chassis.count, ports.count, "every port must name a chassis")
        XCTAssertEqual(Set(chassis).count, chassis.count, "chassis numbers must be unique")
        XCTAssertFalse(chassis.contains("0"), "chassis 0 is the root complex itself")
        XCTAssertEqual(chassis, (1...ports.count).map(String.init))
    }

    /// No `bus=`, deliberately: the machine's own default PCIe root complex is the
    /// right parent, and naming `pcie.0` outright would break the `.count(n)` case
    /// on a machine whose bus is called something else.
    func testRootPortsDoNotHardCodeAParentBus() {
        for device in rootPortDevices(in: arguments(for: QEMUConfiguration())) {
            XCTAssertNil(property("bus", of: device), "unexpected bus in \(device)")
        }
    }

    /// The launch arguments and the pool `QEMUManager` allocates from are both
    /// derived from `hotplugPortIDs`. If they ever disagreed, `attachDisk` would
    /// name a bus QEMU has never heard of — which fails with `Bus 'x' not found`.
    func testEmittedPortIDsAreExactlyTheOnesTheManagerHandsOut() {
        let config = QEMUConfiguration()
        let emitted = rootPortDevices(in: arguments(for: config))
            .compactMap { property("id", of: $0) }

        XCTAssertEqual(emitted, config.hotplugPortIDs)
        XCTAssertEqual(Set(emitted).count, emitted.count, "ids must be unique")
    }

    // MARK: - Machine-type gate

    /// `pc` hot-plugs onto `pci.0` without help, and `microvm` has no PCI bus at
    /// all — a root port there is not merely useless, it stops QEMU from starting
    /// with `No 'PCI' bus found for device 'pcie-root-port'`.
    func testAutomaticAddsNoPortsWhereTheDefaultBusAlreadyHotplugs() {
        for machineType in ["pc", "pc-i440fx-10.0", "microvm", "isapc"] {
            var config = QEMUConfiguration()
            config.machineType = machineType

            XCTAssertFalse(config.requiresHotplugPort, "\(machineType) hot-plugs on its own")
            XCTAssertEqual(config.resolvedHotplugPortCount, 0)
            XCTAssertTrue(rootPortDevices(in: arguments(for: config)).isEmpty, machineType)
        }
    }

    /// The versioned aliases are the same machine, and arm `virt` has the same
    /// PCIe root complex with the same refusal.
    func testAutomaticCoversVersionedAndNonX86PCIeMachines() {
        for machineType in ["q35", "pc-q35-10.0", "pc-q35-6.2", "virt", "virt-9.2"] {
            var config = QEMUConfiguration()
            config.machineType = machineType

            XCTAssertTrue(config.requiresHotplugPort, "\(machineType) needs a root port")
            XCTAssertEqual(
                rootPortDevices(in: arguments(for: config)).count,
                QEMUConfiguration.automaticHotplugPortCount,
                machineType
            )
        }
    }

    /// `-machine` takes options after the name, and the name is what decides this.
    func testMachineOptionsDoNotHideTheMachineName() {
        var config = QEMUConfiguration()
        config.machineType = "q35,kernel_irqchip=off"

        XCTAssertTrue(config.requiresHotplugPort)
        XCTAssertEqual(
            rootPortDevices(in: arguments(for: config)).count,
            QEMUConfiguration.automaticHotplugPortCount
        )
    }

    // MARK: - Explicit port counts

    func testExplicitCountOverridesTheMachineTypeGate() {
        var config = QEMUConfiguration()
        config.machineType = "pc"
        config.hotplugPorts = .count(2)

        XCTAssertEqual(rootPortDevices(in: arguments(for: config)).count, 2)
        XCTAssertEqual(config.hotplugPortIDs.count, 2)
    }

    func testDisabledEmitsNoPortsEvenOnQ35() {
        var config = QEMUConfiguration()
        config.hotplugPorts = .disabled

        XCTAssertEqual(config.resolvedHotplugPortCount, 0)
        XCTAssertTrue(rootPortDevices(in: arguments(for: config)).isEmpty)
        XCTAssertTrue(config.hotplugPortIDs.isEmpty)
    }

    /// A nonsense count is clamped rather than crashing a range or emitting
    /// arguments QEMU would reject.
    func testNonPositiveCountsEmitNothing() {
        for count in [0, -1, -100] {
            var config = QEMUConfiguration()
            config.hotplugPorts = .count(count)

            XCTAssertEqual(config.resolvedHotplugPortCount, 0, "count \(count)")
            XCTAssertTrue(rootPortDevices(in: arguments(for: config)).isEmpty)
        }
    }

    // MARK: - Port allocation

    /// One port, one device: QEMU refuses a second `device_add` onto an occupied
    /// port with `slot 0 function 0 already occupied`.
    func testPortsAreHandedOutOneAtATimeAndReused() {
        var pool = HotplugPortPool(portIDs: ["hp0", "hp1"])
        XCTAssertEqual(pool.capacity, 2)

        XCTAssertEqual(pool.nextFreePort, "hp0")
        pool.claim("hp0", for: "vdb")
        XCTAssertEqual(pool.port(for: "vdb"), "hp0")

        XCTAssertEqual(pool.nextFreePort, "hp1", "a claimed port must not be offered twice")
        pool.claim("hp1", for: "vdc")

        XCTAssertNil(pool.nextFreePort, "exhausted")
        XCTAssertEqual(pool.inUseCount, 2)
        XCTAssertEqual(pool.freeCount, 0)

        pool.release("vdb")
        XCTAssertEqual(pool.nextFreePort, "hp0", "a detached disk gives its port back")
        XCTAssertNil(pool.port(for: "vdb"))
        XCTAssertEqual(pool.freeCount, 1)
    }

    /// A caller-supplied `bus` belongs to a topology this pool knows nothing about,
    /// so claiming it must not silently consume one of the pool's own ports.
    func testAForeignBusIsNotTracked() {
        var pool = HotplugPortPool(portIDs: ["hp0"])
        pool.claim("some-other-root-port", for: "vdb")

        XCTAssertEqual(pool.nextFreePort, "hp0")
        XCTAssertEqual(pool.inUseCount, 0)
        XCTAssertNil(pool.port(for: "vdb"))
    }

    /// Detaching a disk that was never plugged into one of these ports — attached
    /// at launch, or onto an explicit bus — must not invent capacity.
    func testReleasingAnUnknownDeviceChangesNothing() {
        var pool = HotplugPortPool(portIDs: ["hp0"])
        pool.claim("hp0", for: "vdb")

        pool.release("never-attached")

        XCTAssertEqual(pool.inUseCount, 1)
        XCTAssertNil(pool.nextFreePort)
    }

    func testAnEmptyPoolOffersNothing() {
        let pool = HotplugPortPool(portIDs: [])

        XCTAssertNil(pool.nextFreePort)
        XCTAssertEqual(pool.capacity, 0)
        XCTAssertEqual(pool.freeCount, 0)
    }

    // MARK: - Diagnostics

    /// The point of these errors: QEMU's own `GenericError` says which bus refused,
    /// but nothing about what a caller is supposed to do about it.
    func testNoHotplugPortErrorNamesTheConfigurationKnob() throws {
        let none = QMPError.noHotplugPortAvailable(machineType: "q35", portCount: 0, inUse: 0)
        let description = try XCTUnwrap(none.errorDescription)

        XCTAssertTrue(description.contains("q35"), description)
        XCTAssertTrue(description.contains("hotplugPorts"), description)

        let exhausted = QMPError.noHotplugPortAvailable(machineType: "q35", portCount: 4, inUse: 4)
        let exhaustedDescription = try XCTUnwrap(exhausted.errorDescription)

        XCTAssertTrue(exhaustedDescription.contains("4"), exhaustedDescription)
        XCTAssertTrue(exhaustedDescription.contains("hotplugPorts"), exhaustedDescription)
    }

    func testHotplugNotSupportedErrorNamesTheBusAndMachine() throws {
        let error = QMPError.hotplugNotSupported(bus: "pcie.0", machineType: "q35")
        let description = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(description.contains("pcie.0"), description)
        XCTAssertTrue(description.contains("q35"), description)
        XCTAssertTrue(description.contains("hotplugPorts"), description)
    }

    // MARK: - Against a real QEMU

    private static let qemuCandidates = [
        "/opt/homebrew/bin/qemu-system-x86_64",
        "/usr/local/bin/qemu-system-x86_64",
        "/usr/bin/qemu-system-x86_64"
    ]

    private static let qemuImgCandidates = [
        "/opt/homebrew/bin/qemu-img",
        "/usr/local/bin/qemu-img",
        "/usr/bin/qemu-img"
    ]

    private func installedQEMU() throws -> String {
        guard let path = Self.qemuCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("qemu-system-x86_64 not installed")
        }
        return path
    }

    /// A real qcow2 image, since `blockdev-add` opens the file for real. Torn down
    /// with the test.
    private func makeDiskImage() throws -> String {
        guard let qemuImg = Self.qemuImgCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("qemu-img not installed")
        }

        let path = NSTemporaryDirectory() + "qemu-hotplug-\(UUID().uuidString).qcow2"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImg)
        process.arguments = ["create", "-f", "qcow2", path, "16M"]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "qemu-img create failed")

        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// A paused VM is enough for hot-plug — `device_add` does not need the guest to
    /// be executing — and it keeps these tests to a fraction of a second under TCG.
    private func startVM(_ config: QEMUConfiguration) async throws -> QEMUManager {
        var config = config
        config.memoryMB = 128

        let manager = QEMUManager(qemuPath: try installedQEMU(), logger: Logger(label: "test"))
        addTeardownBlock { try? await manager.destroy() }

        try await manager.createVM(config: config)
        return manager
    }

    /// The regression test for the issue itself: hot-plug a disk with nothing
    /// configured but the disk. Before the root ports this failed with
    /// `Bus 'pcie.0' does not support hotplugging`.
    func testAttachDiskWorksOnTheDefaultConfiguration() async throws {
        let manager = try await startVM(QEMUConfiguration())
        let image = try makeDiskImage()

        try await manager.attachDisk(path: image, deviceName: "vdb")

        let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
        XCTAssertTrue(
            attached.contains { $0.contains("vdb") },
            "expected vdb among \(attached)"
        )
        let free = await manager.availableHotplugPorts
        XCTAssertEqual(
            free, QEMUConfiguration.automaticHotplugPortCount - 1,
            "the disk should be holding exactly one root port"
        )
    }

    /// Every port is real and independently usable, not just the first.
    func testEveryRootPortCanTakeADisk() async throws {
        let manager = try await startVM(QEMUConfiguration())

        for index in 0..<QEMUConfiguration.automaticHotplugPortCount {
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vd\(index)")
        }

        let free = await manager.availableHotplugPorts
        XCTAssertEqual(free, 0)

        // And the port after the last one is refused here, not by QEMU: a full pool
        // is reported as a full pool rather than as a bus that cannot hot-plug.
        do {
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vd-overflow")
            XCTFail("expected the attach to fail with no ports left")
        } catch QMPError.noHotplugPortAvailable(let machineType, let portCount, let inUse) {
            XCTAssertEqual(machineType, "q35")
            XCTAssertEqual(portCount, QEMUConfiguration.automaticHotplugPortCount)
            XCTAssertEqual(inUse, QEMUConfiguration.automaticHotplugPortCount)
        }
    }

    /// With the ports turned off, q35 is back to the state the issue describes — so
    /// the failure has to name the cause rather than passing QEMU's `GenericError`
    /// up. It is also refused before `blockdev-add`, so there is no orphaned backend
    /// node left behind.
    func testAttachDiskWithoutPortsFailsWithANamedCause() async throws {
        var config = QEMUConfiguration()
        config.hotplugPorts = .disabled
        let manager = try await startVM(config)

        do {
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")
            XCTFail("expected the attach to fail on q35 with no root ports")
        } catch QMPError.noHotplugPortAvailable(let machineType, let portCount, _) {
            XCTAssertEqual(machineType, "q35")
            XCTAssertEqual(portCount, 0)
        }

        let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
        XCTAssertFalse(attached.contains { $0.contains("vdb") }, "nothing should have been added")
    }

    /// The gate's other side: `pc` gets no root ports, and must still hot-plug —
    /// onto its own `pci.0`, with no bus named at all.
    func testAttachDiskStillWorksOnAMachineThatNeedsNoPorts() async throws {
        var config = QEMUConfiguration()
        config.machineType = "pc"
        let manager = try await startVM(config)

        try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")

        let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
        XCTAssertTrue(attached.contains { $0.contains("vdb") }, "expected vdb among \(attached)")
        let free = await manager.availableHotplugPorts
        XCTAssertNil(
            free, "there is no port budget to report on a machine that hot-plugs directly"
        )
    }
}
