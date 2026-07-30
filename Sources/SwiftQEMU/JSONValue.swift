import Foundation

/// A JSON value as it appears on the QMP wire.
///
/// QMP payloads are only ever these seven shapes, so an enum can model them
/// exactly. The predecessor wrapped `Any` and claimed `@unchecked Sendable`,
/// which meant the compiler could not object to a mutable reference type
/// crossing an isolation boundary inside a command argument or a decoded
/// response — and `as? [String: Any]` casts at every read site papered over the
/// same gap. This type is `Sendable` because its contents genuinely are.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Coding

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            // Ahead of `Double` so integers survive a round-trip as integers;
            // QMP command arguments are rejected by QEMU if an integer field
            // arrives as `1.0`.
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .int(let int): try container.encode(int)
        case .double(let double): try container.encode(double)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let int):
            return int
        case .double(let double) where double == double.rounded() && double.magnitude < 9.2e18:
            // QEMU emits sizes and offsets as JSON numbers; a value large
            // enough to have gone through `Double` is still an integer to the
            // caller.
            return Int(double)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let double): return double
        case .int(let int): return Double(int)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    /// Member of an object, or `nil` for any other shape.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Element of an array, or `nil` if out of range or not an array.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Literals

// Nested QMP command arguments read as plain JSON at the call site:
//
//     ["driver": "qcow2", "file": ["driver": "file", "filename": path]]
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Description

extension JSONValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let bool): return String(bool)
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .string(let string): return string
        case .array(let array): return "[\(array.map(\.description).joined(separator: ", "))]"
        case .object(let object):
            let members = object
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
            return "{\(members.joined(separator: ", "))}"
        }
    }
}
