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
- Owns the running VM's hot-plug topology: it keeps the `QEMUConfiguration` the VM was started with, and a `HotplugPortPool` of the `pcie-root-port` devices from its command line, because which bus `device_add` may target is decided at launch and not at attach time (see fix 16)
- Tracks VM status (stopped, creating, running, paused, shuttingDown, unknown), kept current from QMP events rather than only on demand (see fix 18)
- Re-exposes the event stream as `events(bufferSize:)` for applications, alongside its own subscription
- Actor-based for thread-safe concurrent access

**QEMUProcess** (Sources/SwiftQEMU/QEMUProcess.swift)
- Manages the QEMU process lifecycle using **swift-subprocess**, not Foundation's `Process` (see fix 19)
- An `actor`. `isRunning`, `capturedStderr`, `start(with:)` and `stop()` are all isolated, so reads of process state are `await`-ed. `getQMPSocketPath()` is `nonisolated` (the path is fixed at init)
- `Subprocess.run` does not return until the child has exited, so it runs in a detached task that outlives `start(with:)`. That task and the actor meet only in two internally-locked helpers — `ChildProcess` (pid, exit latch, signalling) and `StderrCapture` — and the task captures nothing else, which is what lets the actor be deinitialized out from under a live child
- Builds QEMU command-line arguments from QEMUConfiguration
- Handles QMP Unix socket creation and readiness with retry logic (up to 10 seconds)
- **Puts the socket in a private `0700` directory** (`<runtimeDirectory>/qemu-<token>/qmp.sock`), not loose in `/tmp` — see fix 17
- stdout is a plain `FileDescriptor` handed to `Subprocess`
  - If `ENABLE_QEMU_PROCESS_LOG_FILES=true` (or `yes`, `1`): stdout goes to `<instance directory>/qemu-<token>.log`, mode `0600`
  - Otherwise: redirects to `/dev/null` (default behavior)
- **Captures stderr** into a bounded tail buffer (last 16KB) from `Subprocess`'s `.sequence` output, exposed as `capturedStderr` and attached to errors. Also teed to the log file when log files are enabled.
- Detects early process exit during the socket wait and throws `QMPError.processExited(exitCode:killedBySignal:stderr:)` immediately
- `stop(timeout:)` is **async**: SIGTERM → bounded wait → SIGKILL → bounded wait. The child reference and the socket file are released only once the child is confirmed gone, and a `deinit` SIGKILLs a child that outlives its `QEMUProcess` (see fix 11)

**QMPClient** (Sources/SwiftQEMU/QMPClient.swift)
- Implements QMP protocol communication using SwiftNIO
- Supports Unix domain socket and TCP connections
- **Critical fix**: Implements exponential backoff retry logic (up to 10 attempts) for socket connection timing issues
- Handles QMP greeting, capability negotiation, and command execution
- Executes QMP commands: query-status, cont, stop, system_powerdown, system_reset, quit, query-yank, yank
- **Events**: `events(bufferSize:)` hands out an `AsyncStream<QMPEvent>` per subscriber — bounded, oldest-dropped, finished when the connection ends (see fix 18)
- **Capabilities**: the greeting is kept (`greeting`), and the capabilities it offers that appear in `requestedCapabilities` are enabled and reported as `negotiatedCapabilities`. `executeOutOfBand` sends `exec-oob` requests for the handful of commands QEMU allows out-of-band
- Connection state (channel, handler, connected flag) lives in one lock-guarded box, so the type is honestly `Sendable` rather than `@unchecked Sendable`. Losing the channel clears the connected flag, so the next command fails fast instead of being written into a dead socket
- Every wait is bounded by a deadline scheduled on the channel's event loop and cancelled when the waiter resolves, and every wait is cancellation-aware (see fix 14). Both halves have the same ordering hazard — the deadline, or the cancellation, can land before the waiter parks — and both are handled by installing the waiter's record first and resolving against it under the lock
- `disconnect()` is idempotent and treats an already-closed channel as success
- Inbound frames are newline-delimited and **bounded**: `maximumFrameSize` (default 512 KB) caps what one frame may buffer, and a peer that exceeds it gets `QMPError.frameTooLarge` and a closed connection (see fix 15)

**QMPProtocol** (Sources/SwiftQEMU/QMPProtocol.swift)
- Defines QMP message types: QMPGreeting, QMPRequest, QMPResponse, QMPEvent
- `QMPCapability` (`.oob`) is the negotiable half of the greeting; `QMPEventName` names the events with behaviour attached, since a misspelled event name silently never matches
- `QMPRequest.outOfBand` encodes as `exec-oob`. **Never** the `"control": {"run-oob": true}` form — QEMU 11 rejects it outright (see fix 18)
- Provides type-safe QMPCommand enum for common commands
- `QMPMessage` discriminates inbound traffic by its key (`QMP`/`event`/`return`/`error`). **Never** go back to trying each type in turn — every property of `QMPResponse` is optional, so a try-in-sequence decode accepts an event as an empty response (see fix 6)

**JSONValue** (Sources/SwiftQEMU/JSONValue.swift)
- Typed JSON enum used for all command arguments and response payloads, replacing the previous `AnyCodable` (`Any` + `@unchecked Sendable`)
- Literal conformances let nested arguments read as plain JSON: `["driver": "qcow2", "file": ["driver": "file", "filename": path]]`
- Read with `stringValue`/`intValue`/`boolValue`/`objectValue`/`arrayValue` and the `[key]`/`[index]` subscripts. Integers stay integers on the wire — QEMU rejects an integer field that arrives as `1.0`

### Critical Reliability Fixes

The codebase includes critical fixes for production reliability:

1. **Pipe Buffer Overflow Prevention**: QEMU stdout is redirected away from pipes to prevent crashes when buffers fill up. The original implementation used `Pipe()` objects but never read from them, causing QEMU to crash with `NIOCore.IOError` when the 64KB buffer filled. Current behavior:
   - Set `ENABLE_QEMU_PROCESS_LOG_FILES=true` to capture output in a log file inside the instance's private directory (see fix 17)
   - Default behavior (when env var not set): stdout redirects to `/dev/null`
   - stderr is `Subprocess`'s `.sequence` output, drained by the run task into `StderrCapture` (bounded to the last 16KB). Since fix 19 there is no `Pipe()` and no `readabilityHandler` here at all — but the underlying rule has not changed: a pipe is only ever safe with an active reader, so **never** hand QEMU a descriptor nothing is draining.

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

9. **Cancellable Exit Wait**: `waitUntilExit()` is cancellation-aware. Parked on a bare `withCheckedContinuation` around Foundation's `terminationHandler` it ignored cancellation, so when `shutdown()`'s timeout leg won, the task group's implicit drain waited forever on it — a shutdown that hung *past its own timeout*, never reaching the forced termination meant to follow. `ExitWaiter` handles the three orderings that each used to hang: exit before anyone waits, several waiters at once, and cancellation arriving before a waiter parks. Since fix 19 it is fired by the run task once `Subprocess.run` returns rather than by a Foundation callback, but the three orderings are unchanged and it is still needed — `run` resolves exactly once, and this is what fans that out to many cancellable waiters. `shutdown(timeout:)` is now configurable.

10. **Accelerator Selection**: `enableKVM: Bool` defaulted to `true` and emitted `-enable-kvm`, so the stock configuration could not start on the only platform `Package.swift` declares — QEMU exits with `invalid accelerator kvm`. A Bool cannot express the choice; `QEMUAccelerator` (`.kvm`/`.hvf`/`.tcg`/`.unspecified`) does, emitted as `-accel <name>`.
    - **The default is `.tcg`, not the host-native accelerator.** An accelerator has to be built into QEMU *for the target being emulated*, not merely available on the host: on Apple Silicon, `qemu-system-x86_64 -accel hvf` fails with `invalid accelerator hvf` while `qemu-system-aarch64` accepts it (verified on QEMU 11.0.2). Since `qemuPath` defaults to `qemu-system-x86_64`, an `hvf` default would have reproduced the same out-of-the-box failure it was meant to fix. `QEMUAccelerator.hostNative` is there for callers whose target matches the host
    - `cpuType` is now `String?`. `host` only means something under hardware virtualization — under TCG, QEMU answers `unable to find CPU model 'host'` — so `resolvedCPUType` supplies `host` for kvm/hvf and `qemu64` otherwise. An explicit `cpuType` always wins
    - `.unspecified` emits no `-accel` at all, for callers configuring it through `-machine accel=...` in `additionalArgs`
    - `enableKVM` remains as a deprecated shim: `true` → `.kvm`, `false` → `.tcg` (what QEMU fell back to when the flag was absent). It cannot represent `hvf`, and reads `false` for it

11. **Termination That Actually Terminates**: `stop()` sent SIGTERM and cleared `process` in the very next statement, which was wrong four ways at once — `isRunning` (derived from `process`) reported false over a live QEMU, the socket file was deleted from under it, the child was never waited on, and the `processAlreadyRunning` guard in `start()` waved through a restart that reused the survivor's socket path. A wedged QEMU that ignored SIGTERM was never killed at all, so `destroy()`'s documented force quit could not force anything. Now:
    - `stop(timeout:)` is `async`: SIGTERM, wait up to `timeout`, SIGKILL, wait again. Both signals are a raw `kill(2)` on the pid — see fix 19 for why they cannot go through `Subprocess`'s own `Execution.send(signal:)`/`teardown(using:)`. Default 5s via `QEMUProcess.defaultTerminationTimeout`
    - The `ChildProcess` reference and the socket file are released only after the exit is *confirmed*. If even SIGKILL fails, the reference is deliberately kept so `isRunning` stays truthful, and `destroy()` throws `QMPError.processTerminationFailed(pid:)` with `status = .unknown` rather than reporting a success it did not achieve
    - `stop()`'s waits are deliberately **not** cancellable (a detached-task wait on `ChildProcess`, unlike `waitUntilExit()`). A cancelled wait would hand `stop()` an unearned "still running" and it would escalate — or clear its state — without having confirmed anything
    - `stop()` first settles `waitForSpawn()`, because `start(with:)` publishes the `ChildProcess` *before* the spawn completes. A stop interleaving with a start would otherwise find no pid, drop its SIGTERM, and run the whole escalation against nothing
    - `deinit` SIGKILLs a still-running child. Neither Foundation's `Process` nor `Subprocess` does, so dropping a `QEMUProcess`/`QEMUManager` used to leak a running VM for the lifetime of the host process. It cannot await, so there is no graceful path here: call `shutdown()` or `stop()` if the guest should power itself down
    - `shutdown()`'s graceful branch now also calls `stop()` — the child is gone but its process record and socket file are not

12. **`QEMUProcess` Isolation**: `QEMUProcess` was a `final class` marked `@unchecked Sendable` while holding four unsynchronized mutable fields (`process`, `stderrPipe`, `stderrCapture`, `exitWaiter`). `createVM` touches it from two concurrency domains at once — a task-group child runs `start(with:)`, which writes all four, while the failure path reads `capturedStderr`/`isRunning`. The annotation was the only reason Swift 6 did not diagnose it; the inner `StderrCapture`/`ExitWaiter` locks protect their contents, not the fields referencing them. It is now an `actor`, and `QEMUProcessTests.testStatusCanBeReadConcurrentlyWithAStartInFlight` covers the overlap — under `swift test --sanitize=thread` it reported races on the `stderrCapture` and `process` writes against a class and none against the actor.
    - `nonisolated` is used in five deliberate places, and nowhere else: `getQMPSocketPath()` and `buildArguments(from:)` (both derive only from `let` state, so call sites and argument-list assertions stay synchronous), `static runQEMU`, which the detached run task calls and which must therefore *not* be able to reach the actor (see fix 19), and the two `static` cleanup helpers (`removeRuntimeFiles`/`removeSocketFile`), which `deinit` calls with the paths passed in as arguments
    - `deinit` is `nonisolated` by language rule, and reaches stored properties under the exception for a deinitializing actor — which is what lets fix 11's SIGKILL-on-drop survive the conversion. It touches only stored properties of `self`, and reads them one `if` at a time: folding two into `a && b` makes the second operand an autoclosure, which is nonisolated and will not compile there. Anything computed on `self`, or any isolated method call, is out for the same reason. Calling into `child` is fine, and has to be — the run task holds the only other reference to it and outlives the actor
    - Tests clean up via `addTeardownBlock` rather than `defer`, because `stop()` is `await`-ed and `defer` bodies cannot await. That also reaches cleanup on failure paths, which the hand-written `await process.stop()` calls it replaced did not

13. **A Created VM Reports `.paused`, Not `.creating`**: `startPaused` defaults to `true`, so the stock `createVM` launches QEMU with `-S`, and QEMU reports that run state as `prelaunch` — which mapped to `.creating`. A VM that was fully created and waiting to be started therefore read as still being created, and `.creating` meant two things at once, so a caller could not tell "still coming up" from "waiting for me". Now:
    - `prelaunch` maps to `.paused`. It is a stopped-but-live VM that `start()` resumes, which is what `.paused` means everywhere else in the API
    - `.creating` is left to the window before `createVM` returns. `inmigrate` keeps it — an incoming migration really is a VM still being constructed — and nothing else QEMU reports maps to it
    - The mapping moved out of `updateStatus()` into `QEMUVMStatus.init?(_ response: QMPStatusResponse)`, a pure function testable without a process or a socket. It returns `nil` for an unrecognised run state so the manager still logs the raw string before falling back to `.unknown`

14. **Scheduled Deadlines and Cancellable Waits**: every waiter in `QMPChannelHandler` armed its deadline as a `Task.detached` that slept out the *whole* budget, and no wait observed cancellation. So a burst of commands left one task per command idling for the full 10s default long after each resolved, and a cancelled caller had nothing to resume it but the deadline it was trying to escape. Now:
    - `armDeadline` returns an `EventLoop.scheduleTask` `Scheduled<Void>`, stored on the waiter's record and cancelled the moment the waiter resolves — no task, no sleep, and no deadline outliving what it bounds. It is still armed only *after* the waiter is installed (fix 6's ordering rule), so it either finds the waiter or finds it already resolved; `attachDeadline` closes the remaining window by cancelling a deadline whose waiter resolved while it was being armed. Scheduling on the loop also preserves what `Task.detached` was there for: the deadline is out of reach of caller cancellation, and a deadline that inherited cancellation and skipped `expire` would strand its waiter
    - All three waits (`waitForGreeting`, `sendRequest`, `waitForDeviceDeleted`) run under `withTaskCancellationHandler` and throw `CancellationError` promptly. The mirror image of the deadline hazard applies — a cancellation can arrive *before* the waiter parks — so each waiter's record is created before the handler is installed and the canceller marks it rather than finding nothing; the parking waiter then resumes itself. This is why `sendRequest` now registers its `PendingRequest` before writing to the channel, and why a cancelled command may never be written at all
    - A `PendingRequest` without a continuation has not been written yet, so no reply can belong to it. The untagged-response FIFO fallback (old QEMU that does not echo `id`) skips those records rather than taking the head blindly

15. **Bounded Inbound Frames**: `channelRead` accumulated everything it read and only drained on a newline, so a peer that never sent one grew the buffer for as long as it kept writing. Fix 6's `discardReadBytes()` stopped *consumed* frames accumulating; a single unterminated frame was still unbounded. `maximumFrameSize` (default `QMPClient.defaultMaximumFrameSize`, 512 KB, settable per client) now caps one frame including its terminating newline, and exceeding it fails the connection with `QMPError.frameTooLarge(limit:)`.
    - QEMU does not do this, so this is hardening — it matters because a half-written frame should surface as a named error rather than as growing memory and, eventually, a bare `.timeout`. It used to matter more: the socket lived in a world-writable directory until fix 17 moved it into a private one
    - The cap is on **frame size**, not merely on withheld newlines: an over-limit frame is rejected whether or not its newline has arrived. The unterminated branch (`readableBytes > limit`) and the complete-frame branch (`messageLength > limit`) are both reachable and both tested — which arrives depends only on how the peer's bytes land across socket reads
    - Waiters are failed *before* the close, so the in-flight caller gets `frameTooLarge` rather than the `connectionLost` that `channelInactive` would otherwise latch a moment later. `failAllWaiters` keeps the first error
    - 512 KB is far above any real QMP message (`query-block` on a long device list, the largest realistic payload, runs to tens of KB). `testLargeFrameWithinTheLimitIsStillDelivered` exists because a cap that clipped legitimate payloads would be worse than no cap
    - `NIOExtras.LineBasedFrameDecoder` would give this for free via its `maximumBufferSize`; it is deliberately not used here, since adding the dependency belongs with the `NIOAsyncChannel` migration (issue #21)

16. **Hot-Plug on the Default Machine Type**: `machineType` defaults to `q35`, whose `pcie.0` is a PCIe root complex, and `attachDisk` named no bus — so `device_add` landed on `pcie.0` and QEMU answered `Bus 'pcie.0' does not support hotplugging`. `attachDisk`/`detachDisk` were therefore unusable as shipped unless the caller knew to switch to `-machine pc`. A PCIe complex hot-plugs only through a `pcie-root-port`, and a root port **cannot itself be hot-plugged** — it has to be on the command line at launch, which is why this could not be fixed inside `attachDisk`. Now:
    - `QEMUConfiguration.hotplugPorts` (`.automatic`/`.count(n)`/`.disabled`, default `.automatic`) pre-creates root ports, and `QEMUManager` hands one out per `attachDisk`, releasing it on `detachDisk`. A port holds exactly one device — a second `device_add` onto an occupied port is refused with `slot 0 function 0 already occupied` — so the pool is a real capacity limit, `automaticHotplugPortCount` (4) by default, and `QEMUManager.availableHotplugPorts` reports what is left
    - **`chassis` is mandatory and must be unique.** Two root ports that both leave it unset stop QEMU from starting with `Can't add chassis slot, error -16`. The emitted arguments are `pcie-root-port,id=swiftqemu-hotplug<i>,chassis=<i+1>`, and deliberately carry **no `bus=`**: the machine's own default root complex is the right parent, verified on q35, `pc` and arm `virt` alike
    - `.automatic` is gated on the machine type by allowlist (`q35`, `pc-q35-*`, `virt`, `virt-*`), because a root port is only valid where there is a PCI bus to put it on — on `microvm` the argument alone is fatal (`No 'PCI' bus found for device 'pcie-root-port'`). Being wrong in that direction costs a launch; being wrong the other way costs one clear error at attach time, so unknown machine types get no ports
    - `pc` deliberately gets none: its `pci.0` hot-plugs directly, and `attachDisk` names no bus there
    - Both failure modes now name their cause: `QMPError.noHotplugPortAvailable(machineType:portCount:inUse:)` when there is no free port (thrown *before* `blockdev-add`, so a refused attach leaves no orphaned backend node), and `QMPError.hotplugNotSupported(bus:machineType:)` in place of QEMU's bare `GenericError`. `attachDisk(bus:)` lets a caller with its own topology bypass the pool entirely
    - Every QEMU behaviour above was checked over a raw QMP socket against QEMU 11.0.2 before being encoded, and `QEMUHotplugTests` starts real VMs to cover both sides of the gate: default-config attach, all four ports, pool exhaustion, `pc` with no ports, and `.disabled` on q35 (which is the pre-fix state, and must fail with the named error)

17. **A Private Directory for the QMP Socket**: the socket defaulted to `/tmp/qemu-<uuid>.sock`, and `start()` deleted whatever sat at that path before launching. `/tmp` is world-writable and shared with every user on the host, and a QMP socket is a full control channel for the VM — connect to it and you can `quit` the guest, hot-plug devices, or read block device state. The UUID made it hard to guess rather than protected. Now:
    - The socket is `<runtimeDirectory>/qemu-<token>/qmp.sock`, in a directory created with mode `0700`. **The directory's mode is the access control** — a socket file's own permission bits are not portably honoured, so putting the socket somewhere private is the only thing that works. The mode is set twice (as a `createDirectory` attribute, then via `setAttributes`) because Foundation does not promise the attribute reaches `mkdir(2)` rather than being applied afterwards
    - `withIntermediateDirectories: false` for the leaf, so anything already at that path is an error rather than something to adopt
    - `runtimeDirectory` is injectable on both `QEMUProcess` and `QEMUManager` (defaults to `NSTemporaryDirectory()`, already per-user on macOS)
    - Teardown removes the *directory*, and only ever one this instance created. The old code deleted a caller-supplied path outright; `removeSocketFile` now refuses anything that is not a socket, regular file, or symlink, because `removeItem` on a directory takes everything under it
    - **The name is a 13-character base-36 token, not a UUID, and this matters**: `sun_path` is 104 bytes on Darwin and `NSTemporaryDirectory()` spends ~50 of them before this library adds anything. A UUID-named directory plus `qmp.sock` does not fit — the injectable-base-directory test hit exactly that and had to be shortened. `QEMUProcess.maxSocketPathLength` is read from `sockaddr_un`, and `start()` throws `QMPError.socketPathTooLong(path:limit:)` rather than letting an over-long path present as a socket that never appears
    - The debug log moved into the same private directory at mode `0600` (with `-nographic` it is the guest console). It is named per *run*, not per instance, so a restart does not overwrite the log being diagnosed — and a directory holding a log is the one thing teardown leaves behind, since a log you cannot read after the VM exits is no use

18. **Events Reach Callers, and the Greeting's Capabilities Are Used**: events were decoded correctly (fix 6) but only `DEVICE_DELETED` was acted on — everything else was logged at debug level and dropped, so `QEMUManager.status` went stale until someone called `getStatus()` and a guest powering itself off was invisible. The greeting's `capabilities` were decoded and discarded in the same way, leaving the protocol's only optional feature permanently off. Now:
    - `QMPClient.events(bufferSize:)` returns an `AsyncStream<QMPEvent>`. **Per subscriber**, so the manager's own bookkeeping and an application's `for await` do not displace each other; **bounded** at `bufferSize` (default 64) keeping the *newest*, because these are yielded from the NIO event loop and a blocking yield would stall QEMU's socket for every waiter; and **finished when the connection ends**, so a `for await` terminates instead of parking. A stream belongs to one connection — reconnecting means resubscribing
    - `DEVICE_DELETED` keeps its dedicated ticket path (a detach needs a targeted, timed wait, not a scan of a shared stream) *and* is published to subscribers. `QMPClientTests.testDeviceDeletedReachesBothItsTicketAndTheStream` is the guard on that
    - `QEMUManager` consumes the stream in a task started at the end of `createVM`, subscribing *before* the first `updateStatus()` so no transition falls in the gap. `QEMUVMStatus.init?(event:)` is the mapping, pure and testable: `STOP`/`SUSPEND` → `.paused`, `RESUME`/`WAKEUP` → `.running`, `POWERDOWN` → `.shuttingDown`, `SHUTDOWN` → `.stopped`. `RESET` and `GUEST_PANICKED` map to **nothing** — verified on 11.0.2, `system_reset` leaves the run state alone and emits `RESET` *twice*, and what a panic implies depends on `-action panic`
    - `POWERDOWN` → `.shuttingDown` is a statement about the *request*, not the run state, and QEMU has no run state for it — so a `getStatus()` while the guest is still working through the poweroff reports `.running` again. Same as `shutdown()`, which sets `.shuttingDown` for the same reason and has always had the same property
    - Event-derived updates apply only while the manager considers itself connected, and the teardown paths stop the monitor before deciding the final status. Otherwise a `SHUTDOWN` still sitting in the buffer could relabel a VM that `destroy()` failed to kill as `.stopped`
    - `updateStatus()` reports `.stopped` rather than `.unknown` when the query fails against an exited QEMU. Without that, the accurate `.stopped` from a `SHUTDOWN` event was overwritten by the next query, which cannot succeed against a socket that has gone
    - Capability negotiation sends `qmp_capabilities` with `enable` set to the **intersection** of the greeting's offer and `requestedCapabilities` (default `[.oob]`). Never the wish list: `qmp_capabilities` fails outright on a capability QEMU did not advertise, and a failed negotiation leaves a monitor that answers every later command with "Expecting capabilities negotiation". The reply is now checked for an error, which it previously was not
    - **An out-of-band request is `{"exec-oob": "<command>", "id": ...}`.** The `{"execute": ..., "control": {"run-oob": true}}` form from the original OOB proposal is rejected by QEMU 11 with `QMP input member 'control' is unexpected` — verified against 11.0.2, including for commands that *are* `allow-oob`. Encoding it that way would have shipped a feature that never worked, so `QMPProtocolTests.testOutOfBandRequestEncoding` asserts the wire form
    - `executeOutOfBand` refuses with `QMPError.capabilityNotNegotiated(.oob)` rather than letting QEMU answer `QMP input member 'exec-oob' is unexpected`, which names the JSON instead of the problem
    - QEMU permits OOB only for commands its schema marks `allow-oob`: on 11.0.2 exactly `migrate-pause`, `migrate-recover`, `query-yank`, `yank` — and **not** `quit`. So `yank(instances:outOfBand:)` (plus `queryYank`) is what the capability buys: the recovery path for a monitor blocked on an unresponsive backend
    - Enabling `oob` carries no in-band cost on any supported QEMU. The old `COMMAND_DROPPED`/queue-full behaviour is gone — the event is absent from 11.0.2's `query-qmp-schema` entirely, and 64 pipelined in-band requests were all answered with `oob` on and off

19. **`Subprocess` Instead of Foundation's `Process`**: most of `QEMUProcess` was compensating for `Process` — a `Pipe()` that takes QEMU down with it unless a `readabilityHandler` drains it (fix 1), a `terminationHandler` callback bridged by hand into a cancellable async wait (fix 9), and three manual `FileHandle` redirections. [swift-subprocess](https://github.com/swiftlang/swift-subprocess) covers all of it, so `QEMUProcess` now runs on it. The public surface is unchanged: `start(with:)`, `stop(timeout:)`, `waitUntilExit()`, `capturedStderr`, `isRunning`, `processIdentifier`, `getQMPSocketPath()`.
    - stderr is `error: .sequence`, drained as an `AsyncSequence` into the same bounded `StderrCapture`. There is no fixed-size buffer to overflow and no handler to forget to install, which retires fix 1's footgun rather than merely observing it. `testStderrIsDrainedBeyondThePipeBufferAndKeepsTheTail` — 4000 lines, far past the old 64KB pipe buffer — still passes unchanged, which is the point
    - stdin/stdout are `FileDescriptor`s passed as `input:`/`output:`. When log files are enabled the child's stdout descriptor is a **`dup`** of the parent's, not a second `open`: a dup shares the file offset, which is what keeps the teed stderr interleaved with stdout instead of the two overwriting each other. The log file itself is opened with `.exclusiveCreate` at mode `0600`, keeping fix 17's guarantees
    - Exit status comes back from the `await` as a `TerminationStatus`, so `.signaled(SIGTERM)` is a distinct case rather than Foundation's `terminationReason == .uncaughtSignal` alongside a `terminationStatus` that means two different things
    - **`Subprocess.run` does not return until the child has exited**, and `QEMUProcess` must return from `start(with:)` with QEMU alive. So `run` lives in a `Task.detached` that outlives the call. That task captures no actor state — only `ChildProcess` and `StderrCapture`, both internally locked — which is also what lets `deinit` still SIGKILL a live child (fix 11) while the run task is mid-flight
    - **Signalling goes through the pid, not through `Execution`.** `Subprocess` scopes `Execution` — and with it `send(signal:)` and `teardown(using:)` — to `run`'s body closure. That fits a caller whose child lifetime is a scope; `QEMUProcess`'s is not, since `stop()` arrives from an unrelated call. Nor can the body wait for a stop request instead of returning: the body has no way to learn the child exited on its own (`kill(pid, 0)` succeeds on the un-reaped zombie, and stderr EOF is the only signal available), so a body that waited for a stop request would hang for a VM that shut itself down. Hence `kill(2)` on the pid `ChildProcess` publishes
    - That is safe for one specific reason: `run` reaps the child only after its body returns, so the pid cannot be recycled while `ChildProcess` still holds it. `signal(_:)` additionally refuses once stderr has closed, which `run` orders strictly *before* the reap — so the one window in which the pid could go stale is the one window in which nothing will signal it
    - The platform floor was the open question in the issue (`Subprocess` was documented as needing macOS 15). It turned out to be moot twice over: `Package.swift` already declares `.macOS(.v26)`, and 1.0.0-beta.1 declares `.macOS(.v13)` anyway. Pinned with `exact:` because SPM's `from:` will not resolve a pre-release
    - `QEMUProcessTests` is unchanged by this — every case passes as written, and still reports no races under `swift test --sanitize=thread --filter QEMUProcessTests`. `QEMUHotplugTests` boots real VMs through the new path

### Known Gaps

Reviewed and deliberately left for follow-up work — do not assume these are handled:

- **Thin end-to-end `QEMUManager` coverage**: most of its bugs were regression-tested at the `QMPClient`/`QEMUProcess` level. `QEMUVMStatusTests` and `QEMUHotplugTests` drive the manager against a real QEMU for the create → start → attach → destroy paths (skipped where QEMU is absent); covering the failure paths still needs an injectable QMP-speaking fake, since `QMPClient` is created in `init`
- **PCI hot-unplug needs guest cooperation**: `detachDisk` legitimately times out against a VM with no guest OS — verified over a raw QMP socket that QEMU emits no `DEVICE_DELETED` at all in that case. This is documented on the API and its timeout is now a parameter, but nothing can make a guest-less VM release a device
- **The manager does not reconcile `isConnected` when QEMU exits on its own**: a guest-initiated poweroff now moves `status` to `.stopped` via the `SHUTDOWN` event, but `isConnected` stays true and the process record and socket file are only released by an explicit `shutdown()`/`destroy()`. Commands in that window fail from the client as `.notConnected` rather than being refused up front
- **Event subscriptions do not survive a reconnect** and do not replay: a stream belongs to one connection, and events emitted before `events()` was called are gone. Subscribe first, then read state

### Configuration Types

**QEMUConfiguration**: Main VM configuration
- Machine type, CPU count, memory
- **Accelerator** (`QEMUAccelerator`: `.kvm`/`.hvf`/`.tcg`/`.unspecified`), emitted as `-accel <name>`. Defaults to `.tcg` — see Accelerator Selection below. `enableKVM` survives only as a deprecated shim (`true` → `.kvm`, `false` → `.tcg`)
- `cpuType` is optional; when `nil` it resolves from the accelerator (`host` under kvm/hvf, `qemu64` otherwise) via `resolvedCPUType`
- Disks (QEMUDisk): path, format (qcow2/raw), interface (virtio/ide)
- Networks (QEMUNetwork): backend (user/tap/bridge), model (virtio-net-pci)
- Kernel, initrd, and kernel arguments for direct kernel boot
- **Hot-plug ports** (`QEMUHotplugPorts`: `.automatic`/`.count(n)`/`.disabled`), emitted as `-device pcie-root-port,...`. Defaults to `.automatic`, which provides `automaticHotplugPortCount` (4) ports on machine types whose default bus refuses hot-plug and none on the rest — see Hot-Plug on the Default Machine Type above. `hotplugPortIDs` is the single source of both the launch arguments and the manager's pool
- Display options (noGraphic flag)
- Start paused option for controlled initialization

### Concurrency Model

- QEMUManager is an actor for thread-safe state management
- QEMUProcess is an actor. Its child-process state is genuinely shared across domains, which is the reason it is isolated rather than annotated (see fix 12). The detached task running `Subprocess.run` reaches it only through the locked `ChildProcess`/`StderrCapture` (see fix 19)
- QMPClient is `Sendable`, with its connection state in one lock-guarded box
- All async operations use Swift's async/await and structured concurrency

### Dependencies

- swift-nio: Async networking for QMP socket communication
- swift-log: Structured logging throughout the library
- swift-subprocess: The QEMU child-process lifecycle — spawn, stderr streaming, exit status, reaping (see fix 19). Pinned `exact: "1.0.0-beta.1"`, since SPM's `from:` will not resolve a pre-release; revisit when 1.0.0 ships

## Development Notes

### Environment Variables

**ENABLE_QEMU_PROCESS_LOG_FILES**: Controls QEMU process output handling
- Set to `true`, `yes`, or `1` to capture output in `<instance directory>/qemu-<token>.log` (mode `0600`); the path is logged at `info` when the process starts
- When unset or any other value: redirects stdout to `/dev/null`
- Usage: `ENABLE_QEMU_PROCESS_LOG_FILES=true swift run`
- Does **not** affect stderr capture — stderr is always captured in memory and reported on failure, regardless of this variable
- Setting it means the instance directory is **not** removed on teardown, so the log survives the VM. Those directories are yours to clean up

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

`QEMUHotplugTests` goes further and drives `QEMUManager` end to end against a real QEMU — create, `attachDisk`, `query-block`, destroy — because whether a `device_add` lands anywhere is a fact about QEMU's PCI topology that no fake can answer. It needs `qemu-img` as well (each test hot-plugs a real 16M qcow2) and skips when either binary is missing. Each VM boots paused with 128MB under TCG, so the whole suite is under a second per VM.

```bash
# Machine types this binary provides. The name is what decides whether root ports
# are pre-created, versioned aliases (pc-q35-10.0) included
qemu-system-x86_64 -machine help
```

Three more tests need a real QEMU for the same reason — the fake server accepts whatever it is sent, so only QEMU can say whether a request is *valid*:

- `QEMUVMStatusTests.testCreatedVMReportsPausedAndBecomesRunningOnStart` — the run state comes from QEMU, not the test
- `QEMUVMStatusTests.testEventsFromARealQEMUReachTheManagersSubscribers` — real event names and ordering (`RESUME` then `STOP`), and that `oob` negotiation succeeds
- `QMPClientTests.testOutOfBandCommandIsAcceptedByARealQEMU` — an `exec-oob` request QEMU actually answers, which is the only check that would have caught the rejected `control` spelling

Which commands a given QEMU allows out-of-band is in its own schema, and is the
only trustworthy source: negotiate, send `query-qmp-schema` over the QMP socket,
and collect the entries with `"allow-oob": true` (11.0.2 answers with
`migrate-pause`, `migrate-recover`, `query-yank`, `yank`). Note that `-qmp stdio`
truncates a reply that large — use a Unix socket for this.

### QMP Socket Debugging

When debugging QMP issues:
- Enable log files: `export ENABLE_QEMU_PROCESS_LOG_FILES=true`
- The socket and log live in a private per-instance directory under `NSTemporaryDirectory()` — `/var/folders/…/T/qemu-<token>/` on macOS, `/tmp/qemu-<token>/` on Linux. `getQMPSocketPath()` reports the exact path, and it is logged at `info` on start
- Check socket file creation: `ls -la "$(dirname "$SOCKET")"` — or `ls -la "${TMPDIR:-/tmp}"/qemu-*/`
- Monitor QEMU output logs: `tail -f "${TMPDIR:-/tmp}"/qemu-*/*.log`
- Watch for "Connection refused" errors (indicates timing issues)
- Verify socket permissions and ownership

### Common VM Lifecycle Pattern

```swift
let manager = QEMUManager(qemuPath: "/usr/bin/qemu-system-x86_64")
// The QMP socket goes in a private 0700 directory under NSTemporaryDirectory().
// To put it elsewhere — XDG_RUNTIME_DIR, say — pass `runtimeDirectory:`. Keep the
// base short: the whole socket path has to fit in ~100 bytes.

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

// Hot-plug a disk. On q35 this goes into one of the pcie-root-port devices
// `config.hotplugPorts` put on the command line — four by default, one per disk.
try await manager.attachDisk(path: "/path/to/extra.qcow2", deviceName: "vdb")
// await manager.availableHotplugPorts  // 3, or nil where the default bus hot-plugs
// Detach needs the *guest* to release the device; a VM with no guest OS never does,
// and this times out with nothing removed.
try await manager.detachDisk(deviceName: "vdb", timeout: 30)

// Later: gracefully shutdown (default 30 second timeout, then force quit)
try await manager.shutdown()
// Or with a custom budget: try await manager.shutdown(timeout: 10)

// Force quit: SIGTERM, then SIGKILL after `terminationTimeout` (default 5s).
// Throws QMPError.processTerminationFailed if QEMU survives both.
try await manager.destroy()
```

Dropping a `QEMUManager` without shutting it down no longer leaks the VM —
`QEMUProcess.deinit` SIGKILLs the child — but that is a backstop, not a shutdown:
the guest gets no chance to power itself off.

`status` is kept current from QMP events while connected, so a guest that pauses,
resumes or powers itself off is reflected without polling. Watch the events
directly to react to the rest:

```swift
// Bounded (newest kept), one stream per subscriber, finished when the connection
// ends — so this loop terminates on shutdown rather than parking.
for await event in try await manager.events() {
    switch event.event {
    case QMPEventName.shutdown:
        print("guest powered off:", event.data?["reason"]?.stringValue ?? "?")
    case "BLOCK_IO_ERROR", QMPEventName.guestPanicked:
        print("needs attention:", event.event)
    default:
        break
    }
}
```

Out-of-band execution is negotiated by default where QEMU offers it, for the few
commands that accept it:

```swift
if await manager.negotiatedCapabilities.contains(.oob) {
    // Reaches a monitor blocked on an unresponsive backend, which an in-band
    // command would queue behind. `quit` is *not* allow-oob; `yank` is.
    let instances = try await client.queryYank(outOfBand: true)
    try await client.yank(instances: instances, outOfBand: true)
}
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
- processTerminationFailed(pid:) (QEMU outlived both SIGTERM and SIGKILL, so `destroy()` could not force anything)
- socketPathTooLong(path:limit:) (the QMP socket path does not fit in `sockaddr_un.sun_path`; QEMU would fail to bind, which otherwise reads as a socket that never appears)
- noHotplugPortAvailable(machineType:portCount:inUse:) (nowhere to hot-plug the disk: the machine type refuses hot-plug on its default bus and no free `pcie-root-port` was left. Thrown before anything reaches QEMU)
- hotplugNotSupported(bus:machineType:) (QEMU refused `device_add` because the target bus does not support hot-plug, in place of its own bare `GenericError`)
- timeout (createVM operation exceeded timeout)
- frameTooLarge(limit:) (an inbound QMP frame exceeded `maximumFrameSize`, so the connection was closed)
- invalidResponse, invalidConfiguration
- capabilityNotNegotiated(QMPCapability) (an out-of-band request on a connection without `oob`)
- qmpError(class, description) for QMP-specific errors

### Logging

All components use swift-log with labeled loggers:
- "SwiftQEMU.QEMUManager"
- "SwiftQEMU.QEMUProcess"
- "SwiftQEMU.QMPClient"

Set log level in consuming applications to control verbosity.
