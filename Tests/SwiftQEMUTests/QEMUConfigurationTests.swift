import Foundation
import Logging
import Testing
@testable import SwiftQEMU

/// Tests for accelerator and CPU-model selection.
///
/// The failure these cover: `enableKVM` defaulted to `true` and emitted
/// `-enable-kvm`, so the out-of-the-box configuration died on macOS — the only
/// platform the package declares — with `invalid accelerator kvm`, before QEMU
/// reached anything else in the argument list. `cpuType = "host"` was the same
/// bug one argument later: `host` needs a hardware accelerator, and under TCG
/// QEMU answers `unable to find CPU model 'host'`.
@Suite("QEMU configuration")
struct QEMUConfigurationTests {

    private func arguments(for config: QEMUConfiguration) -> [String] {
        QEMUProcess(
            qemuPath: "/nonexistent/qemu-system-x86_64",
            qmpSocketPath: "/tmp/unused.sock",
            logger: Logger(label: "test")
        ).buildArguments(from: config)
    }

    /// The value of a flag, given the flag's own position in the argument list.
    private func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - The default configuration

    /// The headline of the bug: what a caller gets without configuring anything.
    @Test func defaultConfigurationUsesAPortableAcceleratorAndCPU() {
        let args = arguments(for: QEMUConfiguration())

        #expect(value(of: "-accel", in: args) == "tcg")
        #expect(
            value(of: "-cpu", in: args) == "qemu64",
            "`host` is invalid under TCG — QEMU rejects it with 'unable to find CPU model'"
        )
    }

    /// `-enable-kvm` is gone entirely. It could only ever name one accelerator,
    /// and named it on a platform that has none.
    @Test("The legacy -enable-kvm flag is never emitted", arguments: QEMUAccelerator.allCases)
    func legacyEnableKVMFlagIsNeverEmitted(accelerator: QEMUAccelerator) {
        var config = QEMUConfiguration()
        config.accelerator = accelerator

        #expect(
            !arguments(for: config).contains("-enable-kvm"),
            "-enable-kvm should not survive for \(accelerator)"
        )
    }

    // MARK: - Accelerator selection

    @Test("Each accelerator emits its own name", arguments: [QEMUAccelerator.kvm, .hvf, .tcg])
    func eachAcceleratorEmitsItsOwnName(accelerator: QEMUAccelerator) {
        var config = QEMUConfiguration()
        config.accelerator = accelerator

        #expect(value(of: "-accel", in: arguments(for: config)) == accelerator.rawValue)
    }

    /// `.unspecified` exists to stay out of the way of a caller selecting the
    /// accelerator through `-machine accel=...`, so it must emit nothing.
    @Test func unspecifiedAcceleratorEmitsNoAccelArgument() {
        var config = QEMUConfiguration()
        config.accelerator = .unspecified

        #expect(!arguments(for: config).contains("-accel"))
    }

    @Test func hostNativeIsTheHostPlatformsHardwareAccelerator() {
        #if os(macOS)
        #expect(QEMUAccelerator.hostNative == .hvf)
        #else
        #expect(QEMUAccelerator.hostNative == .kvm)
        #endif
        #expect(QEMUAccelerator.hostNative.isHardwareAccelerated)
    }

    // MARK: - CPU model

    /// `host` passes through the accelerator's capabilities, so it is only
    /// meaningful under hardware virtualization.
    @Test("The default CPU model follows whether the accelerator is hardware-backed", arguments: [
        (QEMUAccelerator.kvm, "host"),
        (.hvf, "host"),
        (.tcg, "qemu64"),
        (.unspecified, "qemu64")
    ])
    func cpuModelFollowsTheAccelerator(accelerator: QEMUAccelerator, cpu: String) {
        var config = QEMUConfiguration()
        config.accelerator = accelerator

        #expect(config.resolvedCPUType == cpu, "wrong default CPU for \(accelerator)")
        #expect(value(of: "-cpu", in: arguments(for: config)) == cpu)
    }

    @Test func explicitCPUTypeOverridesTheAcceleratorDefault() {
        var config = QEMUConfiguration()
        config.accelerator = .tcg
        config.cpuType = "Nehalem"

        #expect(config.resolvedCPUType == "Nehalem")
        #expect(value(of: "-cpu", in: arguments(for: config)) == "Nehalem")
    }

    // MARK: - Compatibility shim

    /// Marked deprecated so exercising the deprecated shim does not warn.
    @available(*, deprecated)
    @Test func deprecatedEnableKVMStillMapsBothWays() {
        var config = QEMUConfiguration()

        config.enableKVM = true
        #expect(config.accelerator == .kvm)
        #expect(config.enableKVM)

        // `false` used to mean "omit -enable-kvm", which left QEMU on TCG.
        config.enableKVM = false
        #expect(config.accelerator == .tcg)
        #expect(!config.enableKVM)

        // The shim cannot express hvf, and says so rather than lying upward.
        config.accelerator = .hvf
        #expect(!config.enableKVM)
    }
}

// MARK: - Against a real QEMU

/// The end of the argument list is the only place any of this is really settled:
/// every combination above is a guess until a real QEMU accepts or rejects it.
@Suite("QEMU configuration against a real QEMU", .requiresQEMU, .hangBackstop)
struct RealQEMUConfigurationTests {

    private let temporaryFiles = TemporaryFiles()

    @Test func defaultConfigurationStartsRealQEMU() async throws {
        let socketPath = temporaryFiles.track(
            NSTemporaryDirectory() + "qemu-accel-\(UUID().uuidString).sock"
        )
        let process = QEMUProcess(
            qemuPath: try QEMUFixtures.requireSystemBinary(),
            qmpSocketPath: socketPath,
            logger: Logger(label: "test")
        )

        var config = QEMUConfiguration()
        config.memoryMB = 128

        try await process.start(with: config)
        let isRunning = await process.isRunning
        let stderr = await process.capturedStderr
        #expect(isRunning, "stderr was: \(stderr)")

        await process.stop()
    }
}
