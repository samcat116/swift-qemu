# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftQEMU is a Swift library for managing QEMU virtual machines via the QEMU Monitor Protocol (QMP). It provides a high-level API for creating, controlling, and monitoring QEMU processes using Swift concurrency (async/await) and SwiftNIO for networking.

## Build and Test Commands

```bash
# Build the project
swift build

# Run tests
swift test

# Build in release mode
swift build -c release

# Run specific test
swift test --filter QMPProtocolTests
```

## Architecture

### Core Components

**QEMUManager** (Sources/SwiftQEMU/QEMUManager.swift)
- High-level API that coordinates process and QMP management
- Manages VM lifecycle: create, start, pause, reset, shutdown, destroy
- Tracks VM status (stopped, creating, running, paused, shuttingDown, unknown)
- Actor-based for thread-safe concurrent access

**QEMUProcess** (Sources/SwiftQEMU/QEMUProcess.swift)
- Manages the QEMU process lifecycle using Foundation's Process API
- Builds QEMU command-line arguments from QEMUConfiguration
- Handles QMP Unix socket creation and readiness with retry logic (up to 10 seconds)
- **Critical fix**: Redirects stdout to prevent pipe buffer overflow crashes
  - If `ENABLE_QEMU_PROCESS_LOG_FILES=true` (or `yes`, `1`): stdout goes to `/tmp/qemu-*.log`
  - Otherwise: redirects to `/dev/null` (default behavior)
- **Captures stderr** into a bounded tail buffer (last 16KB) via an actively drained pipe, exposed as `capturedStderr` and attached to errors. Also teed to the log file when log files are enabled.
- Detects early process exit during the socket wait and throws `QMPError.processExited(exitCode:killedBySignal:stderr:)` immediately

**QMPClient** (Sources/SwiftQEMU/QMPClient.swift)
- Implements QMP protocol communication using SwiftNIO
- Supports Unix domain socket and TCP connections
- **Critical fix**: Implements exponential backoff retry logic (up to 10 attempts) for socket connection timing issues
- Handles QMP greeting, capability negotiation, and command execution
- Executes QMP commands: query-status, cont, stop, system_powerdown, system_reset, quit
- Connection state (channel, handler, connected flag) lives in one lock-guarded box, so the type is honestly `Sendable` rather than `@unchecked Sendable`. Losing the channel clears the connected flag, so the next command fails fast instead of being written into a dead socket
- `disconnect()` is idempotent and treats an already-closed channel as success

**QMPProtocol** (Sources/SwiftQEMU/QMPProtocol.swift)
- Defines QMP message types: QMPGreeting, QMPRequest, QMPResponse, QMPEvent
- Provides type-safe QMPCommand enum for common commands
- `QMPMessage` discriminates inbound traffic by its key (`QMP`/`event`/`return`/`error`). **Never** go back to trying each type in turn — every property of `QMPResponse` is optional, so a try-in-sequence decode accepts an event as an empty response (see fix 6)

**JSONValue** (Sources/SwiftQEMU/JSONValue.swift)
- Typed JSON enum used for all command arguments and response payloads, replacing the previous `AnyCodable` (`Any` + `@unchecked Sendable`)
- Literal conformances let nested arguments read as plain JSON: `["driver": "qcow2", "file": ["driver": "file", "filename": path]]`
- Read with `stringValue`/`intValue`/`boolValue`/`objectValue`/`arrayValue` and the `[key]`/`[index]` subscripts. Integers stay integers on the wire — QEMU rejects an integer field that arrives as `1.0`

### Critical Reliability Fixes

The codebase includes critical fixes for production reliability:

1. **Pipe Buffer Overflow Prevention**: QEMU stdout is redirected away from pipes to prevent crashes when buffers fill up. The original implementation used `Pipe()` objects but never read from them, causing QEMU to crash with `NIOCore.IOError` when the 64KB buffer filled. Current behavior:
   - Set `ENABLE_QEMU_PROCESS_LOG_FILES=true` to capture output in `/tmp/qemu-*.log` files
   - Default behavior (when env var not set): stdout redirects to `/dev/null`
   - stderr uses a `Pipe()` that **is** continuously drained by a `readabilityHandler` into `StderrCapture` (bounded to the last 16KB). A pipe is only ever safe with an active reader — **never** attach one without draining it.

2. **QMP Connection Retry Logic**:
   - QEMUProcess waits up to 10 seconds (20 retries × 0.5s) for QMP socket file creation
   - QMPClient retries connection up to 10 times with exponential backoff (0.1s, 0.2s, 0.4s, 0.8s, max 1s)
   - Handles timing issues where socket file exists but isn't ready for connections

3. **stdin Job Control Prevention**: QEMU stdin is redirected to `/dev/null` to prevent job control issues. When running from a terminal, not setting stdin causes QEMU to inherit the TTY, triggering SIGSTOP/SIGTTOU signals and putting the process in T (stopped) state, making the QMP socket unresponsive.

4. **createVM Timeout and Cleanup**: The `createVM()` method has a configurable timeout (default 30 seconds) and automatic cleanup:
   - If the operation times out or fails, the QEMU process is automatically terminated
   - State is properly reset (`isConnected = false`, `status = .stopped`)
   - Throws `QMPError.timeout` on timeout
   - Prevents orphaned QEMU processes on connection failures
   - Logs QEMU's stderr (`qemuStderr` metadata) on every failure, before the process is torn down

5. **Startup Failure Diagnosis**: QEMU reports a bad argument or a missing disk image by printing to stderr and exiting. With stderr discarded that surfaced only as a QMP connect timeout, naming nothing. Now:
   - The socket wait polls process liveness and bails out as soon as QEMU exits, instead of waiting out the full 10 seconds
   - `QMPError.processExited(exitCode:killedBySignal:stderr:)` carries the stderr tail, and its `errorDescription` includes the last 10 lines — so the thrown error alone names the cause
   - `QEMUProcess.capturedStderr` stays readable after `stop()` for post-mortem reporting

6. **Event/Response Discrimination**: Inbound messages are decoded through `QMPMessage`, keyed on the discriminating field. Trying `QMPResponse` before `QMPEvent` accepted every event as an all-`nil` response, which had two consequences:
   - The event branch was unreachable, so `DEVICE_DELETED` never reached its waiter and `detachDisk` always failed with a timeout
   - An event arriving mid-command was handed to that command as its reply. QEMU really does interleave them — `cont` emits `RESUME` *before* its `{"return": {}}` — so what a caller received depended on event timing
   - `deviceDel` now registers its interest in `DEVICE_DELETED` *before* sending the command, and each registration is scoped to that one `device_del` (keyed by ticket, not device name), so neither event ordering nor a repeat detach of a re-added device can go wrong

7. **Tolerant Status Parsing**: `query-status` returns only `status` reliably. `singlestep` is gone from modern QEMU (verified absent on 11.0.2), and requiring it failed every status query — which `updateStatus()` swallows into `.unknown`, making a healthy VM indistinguishable from a broken one. Only `status` is required now; `running` is derived when absent, `singlestep` is optional.

8. **Teardown That Cannot Orphan the Process**: QEMU exits in response to `quit`, closing the channel from its end, so `disconnect()`'s close failed with `ChannelError.alreadyClosed`. That error propagated out of `destroy()` *before* `process.stop()` ran, leaving exactly the orphaned QEMU the cleanup path exists to prevent. Two independent guards now: `disconnect()` does not treat an already-closed peer as a failure, and `destroy()` cannot skip process termination on a teardown error.

9. **Cancellable Exit Wait**: `waitUntilExit()` is cancellation-aware. Parked on a bare `withCheckedContinuation` around `terminationHandler` it ignored cancellation, so when `shutdown()`'s timeout leg won, the task group's implicit drain waited forever on it — a shutdown that hung *past its own timeout*, never reaching the forced termination meant to follow. `ExitWaiter` handles the three orderings that each used to hang: exit before anyone waits, several waiters at once, and cancellation arriving before a waiter parks. `shutdown(timeout:)` is now configurable.

10. **Accelerator Selection**: `enableKVM: Bool` defaulted to `true` and emitted `-enable-kvm`, so the stock configuration could not start on the only platform `Package.swift` declares — QEMU exits with `invalid accelerator kvm`. A Bool cannot express the choice; `QEMUAccelerator` (`.kvm`/`.hvf`/`.tcg`/`.unspecified`) does, emitted as `-accel <name>`.
    - **The default is `.tcg`, not the host-native accelerator.** An accelerator has to be built into QEMU *for the target being emulated*, not merely available on the host: on Apple Silicon, `qemu-system-x86_64 -accel hvf` fails with `invalid accelerator hvf` while `qemu-system-aarch64` accepts it (verified on QEMU 11.0.2). Since `qemuPath` defaults to `qemu-system-x86_64`, an `hvf` default would have reproduced the same out-of-the-box failure it was meant to fix. `QEMUAccelerator.hostNative` is there for callers whose target matches the host
    - `cpuType` is now `String?`. `host` only means something under hardware virtualization — under TCG, QEMU answers `unable to find CPU model 'host'` — so `resolvedCPUType` supplies `host` for kvm/hvf and `qemu64` otherwise. An explicit `cpuType` always wins
    - `.unspecified` emits no `-accel` at all, for callers configuring it through `-machine accel=...` in `additionalArgs`
    - `enableKVM` remains as a deprecated shim: `true` → `.kvm`, `false` → `.tcg` (what QEMU fell back to when the flag was absent). It cannot represent `hvf`, and reads `false` for it

### Known Gaps

Reviewed and deliberately left for follow-up work — do not assume these are handled:

- **`stop()` neither waits nor escalates**: `terminate()` (SIGTERM) is followed immediately by `process = nil`, so `isRunning` reports false while QEMU may still be alive, the socket file is removed under a live process, the child is never reaped, and there is no SIGKILL escalation. There is also no `deinit`, so dropping a manager leaks a running VM
- **`QEMUProcess` is `@unchecked Sendable` and genuinely raced**: `createVM` mutates its state from a task-group child while the actor's failure path reads `capturedStderr`/`isRunning`. Making it an `actor` would remove the class of bug
- **Per-request deadlines spawn a detached task each** that sleeps out the full timeout even after the request resolves, and requests are not cancellation-aware (a cancelled caller waits out the timeout)
- **`prelaunch` maps to `.creating`**: a VM created with `startPaused: true` reports `.creating` rather than `.paused` until it is started, because QEMU reports `prelaunch` for both cases
- **No end-to-end `QEMUManager` coverage**: its bugs were regression-tested at the `QMPClient`/`QEMUProcess` level. Covering the manager needs an injectable QMP-speaking fake
- **PCI hot-unplug needs guest cooperation**: `detachDisk` legitimately times out against a VM with no guest OS — verified over a raw QMP socket that QEMU emits no `DEVICE_DELETED` at all in that case. Also, `deviceAdd` with no explicit `bus` cannot hotplug on `q35` (`pcie.0` does not support it); use `pc` or an explicit root port

### Configuration Types

**QEMUConfiguration**: Main VM configuration
- Machine type, CPU count, memory
- **Accelerator** (`QEMUAccelerator`: `.kvm`/`.hvf`/`.tcg`/`.unspecified`), emitted as `-accel <name>`. Defaults to `.tcg` — see Accelerator Selection below. `enableKVM` survives only as a deprecated shim (`true` → `.kvm`, `false` → `.tcg`)
- `cpuType` is optional; when `nil` it resolves from the accelerator (`host` under kvm/hvf, `qemu64` otherwise) via `resolvedCPUType`
- Disks (QEMUDisk): path, format (qcow2/raw), interface (virtio/ide)
- Networks (QEMUNetwork): backend (user/tap/bridge), model (virtio-net-pci)
- Kernel, initrd, and kernel arguments for direct kernel boot
- Display options (noGraphic flag)
- Start paused option for controlled initialization

### Concurrency Model

- QEMUManager is an actor for thread-safe state management
- QEMUProcess uses @unchecked Sendable (process management is inherently thread-unsafe)
- QMPClient uses @unchecked Sendable (manages its own thread safety via SwiftNIO EventLoopGroup)
- All async operations use Swift's async/await and structured concurrency

### Dependencies

- swift-nio: Async networking for QMP socket communication
- swift-log: Structured logging throughout the library

## Development Notes

### Environment Variables

**ENABLE_QEMU_PROCESS_LOG_FILES**: Controls QEMU process output handling
- Set to `true`, `yes`, or `1` to capture output in `/tmp/qemu-*.log` files
- When unset or any other value: redirects stdout to `/dev/null`
- Usage: `ENABLE_QEMU_PROCESS_LOG_FILES=true swift run`
- Does **not** affect stderr capture — stderr is always captured in memory and reported on failure, regardless of this variable

### Testing with Real QEMU

Tests in SwiftQEMUTests primarily cover protocol encoding/decoding. Integration testing requires a QEMU installation:

```bash
# Verify QEMU is installed
which qemu-system-x86_64

# List the accelerators this binary was actually built with — the check that
# matters, since availability is per-target, not per-host
qemu-system-x86_64 -accel help
```

`QEMUConfigurationTests.testDefaultConfigurationStartsRealQEMU` starts a real QEMU with the stock configuration when one is installed, and skips otherwise. It is the only test that can confirm the accelerator and CPU model are actually accepted.

### QMP Socket Debugging

When debugging QMP issues:
- Enable log files: `export ENABLE_QEMU_PROCESS_LOG_FILES=true`
- Check socket file creation: `ls -la /tmp/qemu-*.sock`
- Monitor QEMU output logs: `tail -f /tmp/qemu-*.log`
- Watch for "Connection refused" errors (indicates timing issues)
- Verify socket permissions and ownership

### Common VM Lifecycle Pattern

```swift
let manager = QEMUManager(qemuPath: "/usr/bin/qemu-system-x86_64")

var config = QEMUConfiguration()
config.memoryMB = 2048
config.cpuCount = 2
config.disks.append(QEMUDisk(path: "/path/to/disk.qcow2"))
// Accelerator defaults to .tcg, which starts anywhere. For hardware
// acceleration, match the QEMU target to the host architecture first:
// config.accelerator = .hostNative  // .hvf on macOS, .kvm on Linux

// Create VM (starts QEMU process in paused state by default)
// Optional timeout parameter (default 30 seconds)
try await manager.createVM(config: config)
// Or with custom timeout: try await manager.createVM(config: config, timeout: 60)

// Start VM execution
try await manager.start()

// Later: gracefully shutdown (default 30 second timeout, then force quit)
try await manager.shutdown()
// Or with a custom budget: try await manager.shutdown(timeout: 10)
```

QMP payloads come back as `JSONValue`:

```swift
for disk in try await manager.listDisks() {
    let name = disk["device"]?.stringValue
    let size = disk["inserted"]?["image"]?["virtual-size"]?.intValue
}
```

### Error Handling

All errors conform to QMPError enum (Sources/SwiftQEMU/QMPError.swift):
- notConnected, connectionLost
- processNotRunning, processAlreadyRunning
- socketCreationFailed (QMP socket not created within timeout, process still alive)
- processExited(exitCode:killedBySignal:stderr:) (QEMU died before the socket was ready; carries its stderr)
- timeout (createVM operation exceeded timeout)
- invalidResponse, invalidConfiguration
- qmpError(class, description) for QMP-specific errors

### Logging

All components use swift-log with labeled loggers:
- "SwiftQEMU.QEMUManager"
- "SwiftQEMU.QEMUProcess"
- "SwiftQEMU.QMPClient"

Set log level in consuming applications to control verbosity.
