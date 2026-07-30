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

    public init(execute: String, arguments: [String: JSONValue]? = nil, id: String? = nil) {
        self.execute = execute
        self.arguments = arguments
        self.id = id
    }
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
        }
    }
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
