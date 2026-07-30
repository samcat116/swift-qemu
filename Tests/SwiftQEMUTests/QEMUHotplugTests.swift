import Foundation
import Logging
import Testing
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
@Suite("Hot-plug configuration")
struct QEMUHotplugTests {

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
    @Test func defaultConfigurationPreCreatesRootPortsForHotplug() {
        let config = QEMUConfiguration()
        let ports = rootPortDevices(in: arguments(for: config))

        #expect(config.machineType == "q35", "the machine type this all hinges on")
        #expect(
            ports.count == QEMUConfiguration.automaticHotplugPortCount,
            "q35 cannot hot-plug onto pcie.0, so the default config must ship root ports"
        )
        #expect(config.resolvedHotplugPortCount == ports.count)
    }

    /// `chassis` is not decoration: two root ports that both leave it unset take
    /// QEMU down at startup with `Can't add chassis slot, error -16`.
    @Test func eachRootPortCarriesItsOwnChassisNumber() {
        let ports = rootPortDevices(in: arguments(for: QEMUConfiguration()))
        let chassis = ports.compactMap { property("chassis", of: $0) }

        #expect(chassis.count == ports.count, "every port must name a chassis")
        #expect(Set(chassis).count == chassis.count, "chassis numbers must be unique")
        #expect(!chassis.contains("0"), "chassis 0 is the root complex itself")
        #expect(chassis == (1...ports.count).map(String.init))
    }

    /// No `bus=`, deliberately: the machine's own default PCIe root complex is the
    /// right parent, and naming `pcie.0` outright would break the `.count(n)` case
    /// on a machine whose bus is called something else.
    @Test func rootPortsDoNotHardCodeAParentBus() {
        for device in rootPortDevices(in: arguments(for: QEMUConfiguration())) {
            #expect(property("bus", of: device) == nil, "unexpected bus in \(device)")
        }
    }

    /// The launch arguments and the pool `QEMUManager` allocates from are both
    /// derived from `hotplugPortIDs`. If they ever disagreed, `attachDisk` would
    /// name a bus QEMU has never heard of — which fails with `Bus 'x' not found`.
    @Test func emittedPortIDsAreExactlyTheOnesTheManagerHandsOut() {
        let config = QEMUConfiguration()
        let emitted = rootPortDevices(in: arguments(for: config))
            .compactMap { property("id", of: $0) }

        #expect(emitted == config.hotplugPortIDs)
        #expect(Set(emitted).count == emitted.count, "ids must be unique")
    }

    // MARK: - Machine-type gate

    /// `pc` hot-plugs onto `pci.0` without help, and `microvm` has no PCI bus at
    /// all — a root port there is not merely useless, it stops QEMU from starting
    /// with `No 'PCI' bus found for device 'pcie-root-port'`.
    @Test("A machine whose default bus already hot-plugs gets no ports",
          arguments: ["pc", "pc-i440fx-10.0", "microvm", "isapc"])
    func automaticAddsNoPortsWhereTheDefaultBusAlreadyHotplugs(machineType: String) {
        var config = QEMUConfiguration()
        config.machineType = machineType

        #expect(!config.requiresHotplugPort, "\(machineType) hot-plugs on its own")
        #expect(config.resolvedHotplugPortCount == 0)
        #expect(rootPortDevices(in: arguments(for: config)).isEmpty, "\(machineType)")
    }

    /// The versioned aliases are the same machine, and arm `virt` has the same
    /// PCIe root complex with the same refusal. The last one is the rule that
    /// `-machine` takes options after the name, and the name is what decides this.
    @Test("A PCIe machine gets the automatic ports",
          arguments: ["q35", "pc-q35-10.0", "pc-q35-6.2", "virt", "virt-9.2", "q35,kernel_irqchip=off"])
    func automaticCoversVersionedAndNonX86PCIeMachines(machineType: String) {
        var config = QEMUConfiguration()
        config.machineType = machineType

        #expect(config.requiresHotplugPort, "\(machineType) needs a root port")
        #expect(
            rootPortDevices(in: arguments(for: config)).count
                == QEMUConfiguration.automaticHotplugPortCount,
            "\(machineType)"
        )
    }

    // MARK: - Explicit port counts

    @Test func explicitCountOverridesTheMachineTypeGate() {
        var config = QEMUConfiguration()
        config.machineType = "pc"
        config.hotplugPorts = .count(2)

        #expect(rootPortDevices(in: arguments(for: config)).count == 2)
        #expect(config.hotplugPortIDs.count == 2)
    }

    @Test func disabledEmitsNoPortsEvenOnQ35() {
        var config = QEMUConfiguration()
        config.hotplugPorts = .disabled

        #expect(config.resolvedHotplugPortCount == 0)
        #expect(rootPortDevices(in: arguments(for: config)).isEmpty)
        #expect(config.hotplugPortIDs.isEmpty)
    }

    /// A nonsense count is clamped rather than crashing a range or emitting
    /// arguments QEMU would reject.
    @Test("A non-positive port count emits nothing", arguments: [0, -1, -100])
    func nonPositiveCountsEmitNothing(count: Int) {
        var config = QEMUConfiguration()
        config.hotplugPorts = .count(count)

        #expect(config.resolvedHotplugPortCount == 0, "count \(count)")
        #expect(rootPortDevices(in: arguments(for: config)).isEmpty)
    }

    // MARK: - Port allocation

    /// One port, one device: QEMU refuses a second `device_add` onto an occupied
    /// port with `slot 0 function 0 already occupied`.
    @Test func portsAreHandedOutOneAtATimeAndReused() {
        var pool = HotplugPortPool(portIDs: ["hp0", "hp1"])
        #expect(pool.capacity == 2)

        #expect(pool.nextFreePort == "hp0")
        pool.claim("hp0", for: "vdb")
        #expect(pool.port(for: "vdb") == "hp0")

        #expect(pool.nextFreePort == "hp1", "a claimed port must not be offered twice")
        pool.claim("hp1", for: "vdc")

        #expect(pool.nextFreePort == nil, "exhausted")
        #expect(pool.inUseCount == 2)
        #expect(pool.freeCount == 0)

        pool.release("vdb")
        #expect(pool.nextFreePort == "hp0", "a detached disk gives its port back")
        #expect(pool.port(for: "vdb") == nil)
        #expect(pool.freeCount == 1)
    }

    /// A caller-supplied `bus` belongs to a topology this pool knows nothing about,
    /// so claiming it must not silently consume one of the pool's own ports.
    @Test func aForeignBusIsNotTracked() {
        var pool = HotplugPortPool(portIDs: ["hp0"])
        pool.claim("some-other-root-port", for: "vdb")

        #expect(pool.nextFreePort == "hp0")
        #expect(pool.inUseCount == 0)
        #expect(pool.port(for: "vdb") == nil)
    }

    /// Detaching a disk that was never plugged into one of these ports — attached
    /// at launch, or onto an explicit bus — must not invent capacity.
    @Test func releasingAnUnknownDeviceChangesNothing() {
        var pool = HotplugPortPool(portIDs: ["hp0"])
        pool.claim("hp0", for: "vdb")

        pool.release("never-attached")

        #expect(pool.inUseCount == 1)
        #expect(pool.nextFreePort == nil)
    }

    /// The rollback for an attach that claimed a port and then failed, and why it is
    /// matched on the device *and* the port: releasing by name alone would hand back
    /// a port whose device is still plugged into it.
    @Test func releasingAPortOnlyWorksForTheDeviceHoldingIt() {
        var pool = HotplugPortPool(portIDs: ["hp0", "hp1"])
        pool.claim("hp0", for: "vdb")

        pool.release("vdb", from: "hp1")
        #expect(pool.port(for: "vdb") == "hp0", "an unmatched release must change nothing")
        #expect(pool.inUseCount == 1)

        pool.release("vdb", from: "hp0")
        #expect(pool.port(for: "vdb") == nil)
        #expect(pool.nextFreePort == "hp0")
    }

    /// A device that already holds a port keeps it. Overwriting would orphan the
    /// first — leaving a slot that is physically occupied but that this pool reports
    /// as free, which outlives the duplicate `device_add` QEMU is about to refuse.
    @Test func claimingASecondPortForTheSameDeviceIsRefused() {
        var pool = HotplugPortPool(portIDs: ["hp0", "hp1"])
        pool.claim("hp0", for: "vdb")
        pool.claim("hp1", for: "vdb")

        #expect(pool.port(for: "vdb") == "hp0")
        #expect(pool.inUseCount == 1)
        #expect(pool.nextFreePort == "hp1", "hp1 was never actually taken")
    }

    @Test func anEmptyPoolOffersNothing() {
        let pool = HotplugPortPool(portIDs: [])

        #expect(pool.nextFreePort == nil)
        #expect(pool.capacity == 0)
        #expect(pool.freeCount == 0)
    }

    // MARK: - Diagnostics

    /// The point of these errors: QEMU's own `GenericError` says which bus refused,
    /// but nothing about what a caller is supposed to do about it.
    @Test func noHotplugPortErrorNamesTheConfigurationKnob() throws {
        let none = QMPError.noHotplugPortAvailable(machineType: "q35", portCount: 0, inUse: 0)
        let description = try #require(none.errorDescription)

        #expect(description.contains("q35"), "\(description)")
        #expect(description.contains("hotplugPorts"), "\(description)")

        let exhausted = QMPError.noHotplugPortAvailable(machineType: "q35", portCount: 4, inUse: 4)
        let exhaustedDescription = try #require(exhausted.errorDescription)

        #expect(exhaustedDescription.contains("4"), "\(exhaustedDescription)")
        #expect(exhaustedDescription.contains("hotplugPorts"), "\(exhaustedDescription)")
    }

    @Test func hotplugNotSupportedErrorNamesTheBusAndMachine() throws {
        let error = QMPError.hotplugNotSupported(bus: "pcie.0", machineType: "q35")
        let description = try #require(error.errorDescription)

        #expect(description.contains("pcie.0"), "\(description)")
        #expect(description.contains("q35"), "\(description)")
        #expect(description.contains("hotplugPorts"), "\(description)")
    }
}

// MARK: - Against a real QEMU

/// Hot-plug driven end to end, because whether a `device_add` lands anywhere is a
/// fact about QEMU's PCI topology that no fake can answer.
///
/// Needs `qemu-img` as well as `qemu-system-x86_64`: `blockdev-add` opens the image
/// for real. Each VM boots paused with 128MB under TCG, which is a fraction of a
/// second — `device_add` does not need the guest to be executing.
@Suite("Hot-plug against a real QEMU", .requiresQEMUAndImageTool, .slowHangBackstop)
struct RealQEMUHotplugTests {

    private let temporaryFiles = TemporaryFiles()

    /// A real qcow2 image, removed with the test.
    private func makeDiskImage() throws -> String {
        let qemuImg = try #require(QEMUFixtures.imageTool, "gate this test on .requiresQEMUAndImageTool")
        let path = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-hotplug-\(UUID().uuidString).qcow2"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImg)
        process.arguments = ["create", "-f", "qcow2", path, "16M"]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "qemu-img create failed")

        return path
    }

    /// The config every test here starts from: whatever the test is about, plus the
    /// small memory that keeps a real boot cheap.
    private func config(_ customize: (inout QEMUConfiguration) -> Void = { _ in }) -> QEMUConfiguration {
        var config = QEMUConfiguration()
        config.memoryMB = 128
        customize(&config)
        return config
    }

    /// The regression test for the issue itself: hot-plug a disk with nothing
    /// configured but the disk. Before the root ports this failed with
    /// `Bus 'pcie.0' does not support hotplugging`.
    @Test func attachDiskWorksOnTheDefaultConfiguration() async throws {
        try await withVM(config()) { manager in
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")

            let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
            #expect(attached.contains { $0.contains("vdb") }, "expected vdb among \(attached)")

            let free = await manager.availableHotplugPorts
            #expect(
                free == QEMUConfiguration.automaticHotplugPortCount - 1,
                "the disk should be holding exactly one root port"
            )
        }
    }

    /// Every port is real and independently usable, not just the first.
    @Test func everyRootPortCanTakeADisk() async throws {
        try await withVM(config()) { manager in
            for index in 0..<QEMUConfiguration.automaticHotplugPortCount {
                try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vd\(index)")
            }

            let free = await manager.availableHotplugPorts
            #expect(free == 0)

            // And the port after the last one is refused here, not by QEMU: a full
            // pool is reported as a full pool rather than as a bus that cannot
            // hot-plug.
            let error = try await #require(throws: QMPError.self) {
                try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vd-overflow")
            }
            guard case .noHotplugPortAvailable(let machineType, let portCount, let inUse) = error else {
                Issue.record("Expected .noHotplugPortAvailable, got \(error)")
                return
            }
            #expect(machineType == "q35")
            #expect(portCount == QEMUConfiguration.automaticHotplugPortCount)
            #expect(inUse == QEMUConfiguration.automaticHotplugPortCount)
        }
    }

    /// With the ports turned off, q35 is back to the state the issue describes — so
    /// the failure has to name the cause rather than passing QEMU's `GenericError`
    /// up. It is also refused before `blockdev-add`, so there is no orphaned backend
    /// node left behind.
    @Test func attachDiskWithoutPortsFailsWithANamedCause() async throws {
        try await withVM(config { $0.hotplugPorts = .disabled }) { manager in
            let error = try await #require(throws: QMPError.self) {
                try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")
            }
            guard case .noHotplugPortAvailable(let machineType, let portCount, _) = error else {
                Issue.record("Expected .noHotplugPortAvailable, got \(error)")
                return
            }
            #expect(machineType == "q35")
            #expect(portCount == 0)

            let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
            #expect(!attached.contains { $0.contains("vdb") }, "nothing should have been added")
        }
    }

    /// Two attaches at once must land on two different ports.
    ///
    /// Selecting a port and claiming it used to sit on opposite sides of two QMP
    /// round-trips, so that an attach QEMU rejected would not burn one. But
    /// `QEMUManager` is a reentrant actor: across those suspensions the second
    /// attach saw the first's port as still free, picked it, and was refused by QEMU
    /// with `slot 0 function 0 already occupied` — a bare `GenericError` that
    /// `hotplugFailure` does not rewrite, so the pool's whole purpose was defeated
    /// exactly when it was being used.
    @Test func concurrentAttachesTakeDifferentPorts() async throws {
        try await withVM(config()) { manager in
            let firstImage = try makeDiskImage()
            let secondImage = try makeDiskImage()

            let first = Task { try await manager.attachDisk(path: firstImage, deviceName: "vdb") }
            let second = Task { try await manager.attachDisk(path: secondImage, deviceName: "vdc") }

            if case .failure(let error) = await first.result {
                Issue.record("First concurrent attach failed: \(error)")
            }
            if case .failure(let error) = await second.result {
                Issue.record("Second concurrent attach failed: \(error)")
            }

            let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
            #expect(attached.contains { $0.contains("vdb") }, "expected vdb among \(attached)")
            #expect(attached.contains { $0.contains("vdc") }, "expected vdc among \(attached)")

            // Two disks, two ports. A pool that handed out the same port twice would
            // report one still free here even in the run where QEMU accepted both.
            let free = await manager.availableHotplugPorts
            #expect(
                free == QEMUConfiguration.automaticHotplugPortCount - 2,
                "two attached disks must be holding two distinct ports"
            )
        }
    }

    /// A port claimed for an attach that QEMU then rejects has to go back to the
    /// pool: claiming up front is what makes the concurrent case correct, and this
    /// is the property that used to come for free from claiming late.
    @Test func aFailedAttachGivesItsPortBack() async throws {
        try await withVM(config()) { manager in
            let before = await manager.availableHotplugPorts

            // A path QEMU cannot open, so `blockdev-add` fails and nothing is
            // plugged in anywhere.
            await #expect(throws: QMPError.self) {
                try await manager.attachDisk(
                    path: NSTemporaryDirectory() + "no-such-image-\(UUID().uuidString).qcow2",
                    deviceName: "vdb"
                )
            }

            #expect(
                await manager.availableHotplugPorts == before,
                "a rejected attach must not burn a port for the life of the VM"
            )

            // And the port is genuinely reusable, not merely counted as free.
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")
            let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
            #expect(attached.contains { $0.contains("vdb") }, "expected vdb among \(attached)")
        }
    }

    /// The gate's other side: `pc` gets no root ports, and must still hot-plug —
    /// onto its own `pci.0`, with no bus named at all.
    @Test func attachDiskStillWorksOnAMachineThatNeedsNoPorts() async throws {
        try await withVM(config { $0.machineType = "pc" }) { manager in
            try await manager.attachDisk(path: try makeDiskImage(), deviceName: "vdb")

            let attached = try await manager.listDisks().compactMap { $0["qdev"]?.stringValue }
            #expect(attached.contains { $0.contains("vdb") }, "expected vdb among \(attached)")

            let free = await manager.availableHotplugPorts
            #expect(
                free == nil,
                "there is no port budget to report on a machine that hot-plugs directly"
            )
        }
    }
}
