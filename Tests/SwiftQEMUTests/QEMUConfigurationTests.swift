import XCTest
import Logging
@testable import SwiftQEMU

/// Tests for accelerator and CPU-model selection.
///
/// The failure these cover: `enableKVM` defaulted to `true` and emitted
/// `-enable-kvm`, so the out-of-the-box configuration died on macOS — the only
/// platform the package declares — with `invalid accelerator kvm`, before QEMU
/// reached anything else in the argument list. `cpuType = "host"` was the same
/// bug one argument later: `host` needs a hardware accelerator, and under TCG
/// QEMU answers `unable to find CPU model 'host'`.
final class QEMUConfigurationTests: XCTestCase {

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
    func testDefaultConfigurationUsesAPortableAcceleratorAndCPU() {
        let args = arguments(for: QEMUConfiguration())

        XCTAssertEqual(value(of: "-accel", in: args), "tcg")
        XCTAssertEqual(
            value(of: "-cpu", in: args), "qemu64",
            "`host` is invalid under TCG — QEMU rejects it with 'unable to find CPU model'"
        )
    }

    /// `-enable-kvm` is gone entirely. It could only ever name one accelerator,
    /// and named it on a platform that has none.
    func testLegacyEnableKVMFlagIsNeverEmitted() {
        for accelerator in QEMUAccelerator.allCases {
            var config = QEMUConfiguration()
            config.accelerator = accelerator
            XCTAssertFalse(
                arguments(for: config).contains("-enable-kvm"),
                "-enable-kvm should not survive for \(accelerator)"
            )
        }
    }

    // MARK: - Accelerator selection

    func testEachAcceleratorEmitsItsOwnName() {
        for accelerator in [QEMUAccelerator.kvm, .hvf, .tcg] {
            var config = QEMUConfiguration()
            config.accelerator = accelerator
            XCTAssertEqual(value(of: "-accel", in: arguments(for: config)), accelerator.rawValue)
        }
    }

    /// `.unspecified` exists to stay out of the way of a caller selecting the
    /// accelerator through `-machine accel=...`, so it must emit nothing.
    func testUnspecifiedAcceleratorEmitsNoAccelArgument() {
        var config = QEMUConfiguration()
        config.accelerator = .unspecified

        XCTAssertFalse(arguments(for: config).contains("-accel"))
    }

    func testHostNativeIsTheHostPlatformsHardwareAccelerator() {
        #if os(macOS)
        XCTAssertEqual(QEMUAccelerator.hostNative, .hvf)
        #else
        XCTAssertEqual(QEMUAccelerator.hostNative, .kvm)
        #endif
        XCTAssertTrue(QEMUAccelerator.hostNative.isHardwareAccelerated)
    }

    // MARK: - CPU model

    /// `host` passes through the accelerator's capabilities, so it is only
    /// meaningful under hardware virtualization.
    func testCPUModelFollowsWhetherTheAcceleratorIsHardwareBacked() {
        let expected: [QEMUAccelerator: String] = [
            .kvm: "host",
            .hvf: "host",
            .tcg: "qemu64",
            .unspecified: "qemu64"
        ]

        for (accelerator, cpu) in expected {
            var config = QEMUConfiguration()
            config.accelerator = accelerator
            XCTAssertEqual(config.resolvedCPUType, cpu, "wrong default CPU for \(accelerator)")
            XCTAssertEqual(value(of: "-cpu", in: arguments(for: config)), cpu)
        }
    }

    func testExplicitCPUTypeOverridesTheAcceleratorDefault() {
        var config = QEMUConfiguration()
        config.accelerator = .tcg
        config.cpuType = "Nehalem"

        XCTAssertEqual(config.resolvedCPUType, "Nehalem")
        XCTAssertEqual(value(of: "-cpu", in: arguments(for: config)), "Nehalem")
    }

    // MARK: - Compatibility shim

    /// Marked deprecated so exercising the deprecated shim does not warn.
    @available(*, deprecated)
    func testDeprecatedEnableKVMStillMapsBothWays() {
        var config = QEMUConfiguration()

        config.enableKVM = true
        XCTAssertEqual(config.accelerator, .kvm)
        XCTAssertTrue(config.enableKVM)

        // `false` used to mean "omit -enable-kvm", which left QEMU on TCG.
        config.enableKVM = false
        XCTAssertEqual(config.accelerator, .tcg)
        XCTAssertFalse(config.enableKVM)

        // The shim cannot express hvf, and says so rather than lying upward.
        config.accelerator = .hvf
        XCTAssertFalse(config.enableKVM)
    }

    // MARK: - Against a real QEMU

    /// The end of the argument list is the only place this is really settled:
    /// every combination above is a guess until a real QEMU accepts or rejects
    /// it. Skipped where QEMU is not installed.
    func testDefaultConfigurationStartsRealQEMU() async throws {
        let candidates = [
            "/opt/homebrew/bin/qemu-system-x86_64",
            "/usr/local/bin/qemu-system-x86_64",
            "/usr/bin/qemu-system-x86_64"
        ]
        guard let qemuPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("qemu-system-x86_64 not installed")
        }

        let socketPath = NSTemporaryDirectory() + "qemu-accel-\(UUID().uuidString).sock"
        let process = QEMUProcess(qemuPath: qemuPath, qmpSocketPath: socketPath, logger: Logger(label: "test"))
        defer {
            process.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        var config = QEMUConfiguration()
        config.memoryMB = 128

        try await process.start(with: config)
        XCTAssertTrue(process.isRunning, "stderr was: \(process.capturedStderr)")
    }
}
