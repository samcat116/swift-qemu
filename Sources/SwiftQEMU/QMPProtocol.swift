import Foundation

// MARK: - QMP Message Types

/// QMP greeting message sent by QEMU when connection is established
public struct QMPGreeting: Codable, Sendable {
    public struct QMP: Codable, Sendable {
        public struct Version: Codable, Sendable {
            public struct QEMU: Codable, Sendable {
                public let micro: Int
                public let minor: Int
                public let major: Int
            }
            public let qemu: QEMU
            public let package: String
        }
        public let version: Version
        public let capabilities: [String]
    }
    public let QMP: QMP
}

/// QMP request structure
public struct QMPRequest: Codable, Sendable {
    public let execute: String
    public let arguments: [String: JSONValue]?
    /// Correlation token echoed back by QEMU. Always a string here; the client
    /// generates it so responses can be matched to their request.
    public let id: String?
    /// Ask for the command to be run out-of-band, ahead of whatever the monitor
    /// is working through.
    ///
    /// Encoded by naming the command under `exec-oob` instead of `execute`, which
    /// is the *only* form QEMU 11 accepts: the `"control": {"run-oob": true}`
    /// spelling from the original OOB proposal is rejected outright with
    /// `QMP input member 'control' is unexpected` (verified against 11.0.2).
    public let outOfBand: Bool

    public init(
        execute: String,
        arguments: [String: JSONValue]? = nil,
        id: String? = nil,
        outOfBand: Bool = false
    ) {
        self.execute = execute
        self.arguments = arguments
        self.id = id
        self.outOfBand = outOfBand
    }

    private enum CodingKeys: String, CodingKey {
        case execute
        case execOOB = "exec-oob"
        case arguments
        case id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(execute, forKey: outOfBand ? .execOOB : .execute)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(id, forKey: .id)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let execOOB = try container.decodeIfPresent(String.self, forKey: .execOOB) {
            self.execute = execOOB
            self.outOfBand = true
        } else {
            self.execute = try container.decode(String.self, forKey: .execute)
            self.outOfBand = false
        }
        self.arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
    }
}

// MARK: - Capabilities

/// A QMP capability QEMU offers in its greeting and enables through
/// `qmp_capabilities`.
///
/// The greeting's `capabilities` list was decoded and thrown away, which left the
/// only optional part of the protocol permanently off. A capability has to be
/// asked for by name: QEMU rejects the machinery for an un-negotiated capability
/// rather than ignoring it (an `exec-oob` request without negotiation comes back
/// as `QMP input member 'exec-oob' is unexpected`).
public enum QMPCapability: String, Codable, Sendable, CaseIterable {
    /// Out-of-band command execution: a request marked out-of-band is run as soon
    /// as it is parsed, ahead of anything queued in the monitor.
    ///
    /// QEMU permits it only for commands marked `allow-oob` in its schema — on
    /// 11.0.2 that is `migrate-pause`, `migrate-recover`, `query-yank` and `yank`,
    /// and notably *not* `quit`. `yank` is the one that can free a monitor blocked
    /// on a stuck device, which is what makes this worth negotiating.
    case oob
}

/// QMP response structure
///
/// Decoded only via ``QMPMessage``, which is what guarantees at least one of
/// `return`/`error` is present. Decoding this type directly accepts any JSON
/// object, because every property is optional.
public struct QMPResponse: Codable, Sendable {
    public let `return`: JSONValue?
    public let error: QMPErrorResponse?
    /// Whatever QEMU echoed back, kept untyped so an unexpected id shape cannot
    /// fail the decode of an otherwise usable response.
    public let id: JSONValue?

    public init(return: JSONValue? = nil, error: QMPErrorResponse? = nil, id: JSONValue? = nil) {
        self.return = `return`
        self.error = error
        self.id = id
    }
}

/// QMP error response
public struct QMPErrorResponse: Codable, Sendable {
    public let `class`: String
    public let desc: String

    public init(class: String, desc: String) {
        self.class = `class`
        self.desc = desc
    }
}

/// QMP event structure
public struct QMPEvent: Codable, Sendable {
    public let event: String
    public let data: JSONValue?
    /// Optional so a future or trimmed-down event still decodes. An event that
    /// fails to decode is an event that goes undelivered, and `DEVICE_DELETED`
    /// going undelivered is what makes a disk detach hang.
    public let timestamp: QMPTimestamp?

    public init(event: String, data: JSONValue? = nil, timestamp: QMPTimestamp? = nil) {
        self.event = event
        self.data = data
        self.timestamp = timestamp
    }
}

/// QMP timestamp
public struct QMPTimestamp: Codable, Sendable {
    public let seconds: Int
    public let microseconds: Int

    public init(seconds: Int, microseconds: Int) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

// MARK: - Inbound Message Discrimination

/// One message read off the QMP socket, identified by which key it carries.
///
/// The three inbound shapes must be told apart by their discriminating key, not
/// by trying each type in turn: every property of ``QMPResponse`` is optional, so
/// a try-in-sequence decode accepts an *event* as an all-`nil` response. That
/// silently swallowed every asynchronous event — `DEVICE_DELETED` never reached
/// the waiter, so disk detach always timed out — and worse, an event arriving
/// while a command was in flight was handed to that command as its reply. QEMU
/// really does interleave the two: `cont` produces
///
///     {"timestamp": {...}, "event": "RESUME"}
///     {"return": {}, "id": "..."}
///
/// so the reply a caller received depended on event timing.
public enum QMPMessage: Sendable {
    case greeting(QMPGreeting)
    case response(QMPResponse)
    case event(QMPEvent)
}

extension QMPMessage: Decodable {
    private enum DiscriminatingKey: String, CodingKey {
        case QMP
        case event
        case `return`
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatingKey.self)

        if container.contains(.QMP) {
            self = .greeting(try QMPGreeting(from: decoder))
        } else if container.contains(.event) {
            self = .event(try QMPEvent(from: decoder))
        } else if container.contains(.return) || container.contains(.error) {
            self = .response(try QMPResponse(from: decoder))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: DiscriminatingKey.return,
                in: container,
                debugDescription: "Message carries none of QMP, event, return or error"
            )
        }
    }
}

// MARK: - QMP Commands

public enum QMPCommand: Sendable {
    case capabilities
    case queryStatus
    case cont
    case stop
    case systemPowerdown
    case systemReset
    case quit
    case queryVersion
    case queryMachines
    case queryKVM

    // Block device hot-plug commands
    case blockdevAdd
    case blockdevDel
    case deviceAdd
    case deviceDel
    case queryBlock

    // Yank. Both are `allow-oob`, which makes them reachable on a monitor that is
    // otherwise blocked — see ``QMPCapability/oob``.
    case queryYank
    case yank

    public var name: String {
        switch self {
        case .capabilities: return "qmp_capabilities"
        case .queryStatus: return "query-status"
        case .cont: return "cont"
        case .stop: return "stop"
        case .systemPowerdown: return "system_powerdown"
        case .systemReset: return "system_reset"
        case .quit: return "quit"
        case .queryVersion: return "query-version"
        case .queryMachines: return "query-machines"
        case .queryKVM: return "query-kvm"
        case .blockdevAdd: return "blockdev-add"
        case .blockdevDel: return "blockdev-del"
        case .deviceAdd: return "device_add"
        case .deviceDel: return "device_del"
        case .queryBlock: return "query-block"
        case .queryYank: return "query-yank"
        case .yank: return "yank"
        }
    }
}

// MARK: - Event Names

/// The QMP event names this library acts on.
///
/// QMP event names are plain strings on the wire, and every one of them is a
/// silent no-op if misspelled — the event simply never matches. Naming the ones
/// with behaviour attached keeps that failure out of the code that reacts to them.
public enum QMPEventName {
    /// A device finished being unplugged. Delivered to `device_del`'s own waiter as
    /// well as to the event stream.
    public static let deviceDeleted = "DEVICE_DELETED"
    /// Execution stopped (`stop`, or the guest being paused for another reason).
    public static let stop = "STOP"
    /// Execution resumed.
    public static let resume = "RESUME"
    /// The guest was asked to power itself off. QEMU keeps reporting the run state
    /// as `running` until the guest acts — a guest with no OS never does.
    public static let powerdown = "POWERDOWN"
    /// The machine is shutting down. Emitted before the reply to `quit`, and
    /// before QEMU exits on a guest-initiated poweroff.
    public static let shutdown = "SHUTDOWN"
    /// The machine was reset. QEMU emits it twice for a single `system_reset`
    /// (verified on 11.0.2), and the run state is unchanged either way.
    public static let reset = "RESET"
    /// The guest suspended itself (S3).
    public static let suspend = "SUSPEND"
    /// The guest woke from suspend.
    public static let wakeup = "WAKEUP"
    /// The guest panicked. What QEMU does next depends on `-action panic`, so this
    /// implies no particular run state.
    public static let guestPanicked = "GUEST_PANICKED"
}

// MARK: - QMP Status Response

public struct QMPStatusResponse: Codable, Sendable {
    public let status: String
    /// Absent on QEMU releases that dropped it from `query-status` (verified
    /// missing on 11.0.2). Requiring it made every status query fail, which left
    /// the manager reporting `.unknown` for a perfectly healthy VM.
    public let singlestep: Bool?
    public let running: Bool

    public init(status: String, singlestep: Bool? = nil, running: Bool) {
        self.status = status
        self.singlestep = singlestep
        self.running = running
    }
}
