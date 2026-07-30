import Foundation
import Testing
@testable import SwiftQEMU

@Suite("QMP protocol")
struct QMPProtocolTests {

    private let decoder = JSONDecoder()

    private func decodeMessage(_ json: String) throws -> QMPMessage {
        try decoder.decode(QMPMessage.self, from: Data(json.utf8))
    }

    private func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Greeting

    @Test func greetingDecoding() throws {
        let json = """
        {
            "QMP": {
                "version": {
                    "qemu": {"micro": 0, "minor": 0, "major": 7},
                    "package": ""
                },
                "capabilities": []
            }
        }
        """

        let greeting = try decoder.decode(QMPGreeting.self, from: Data(json.utf8))

        #expect(greeting.QMP.version.qemu.major == 7)
        #expect(greeting.QMP.version.qemu.minor == 0)
        #expect(greeting.QMP.version.qemu.micro == 0)
        #expect(greeting.QMP.capabilities.isEmpty)

        guard case .greeting = try decodeMessage(json) else {
            Issue.record("A greeting must be discriminated as a greeting")
            return
        }
    }

    // MARK: - Request encoding

    @Test func requestEncoding() throws {
        let json = try encoded(QMPRequest(execute: "query-status", arguments: nil, id: "swiftqemu-1"))

        #expect(json.contains("\"execute\":\"query-status\""))
        #expect(json.contains("\"id\":\"swiftqemu-1\""))
    }

    /// An out-of-band request names its command under `exec-oob`.
    ///
    /// This is the only spelling QEMU 11 accepts. The `"execute"` +
    /// `"control": {"run-oob": true}` form from the original OOB proposal is
    /// rejected with `QMP input member 'control' is unexpected` (verified against
    /// 11.0.2), so encoding it that way would produce a feature that never works.
    @Test func outOfBandRequestEncoding() throws {
        let json = try encoded(
            QMPRequest(execute: "yank", arguments: ["instances": []], id: "swiftqemu-1", outOfBand: true)
        )

        #expect(json.contains("\"exec-oob\":\"yank\""), "\(json)")
        #expect(!json.contains("\"execute\""), "\(json)")
        #expect(!json.contains("control"), "\(json)")
        // OOB requests have to be correlatable: they are answered out of order by
        // definition, so the id is what matches the reply to the caller.
        #expect(json.contains("\"id\":\"swiftqemu-1\""), "\(json)")
    }

    @Test("A request survives a round trip in band and out", arguments: [true, false])
    func requestRoundTripPreservesOutOfBand(outOfBand: Bool) throws {
        let original = QMPRequest(
            execute: "query-yank",
            arguments: ["k": 1],
            id: "swiftqemu-2",
            outOfBand: outOfBand
        )
        let decoded = try decoder.decode(QMPRequest.self, from: try JSONEncoder().encode(original))

        #expect(decoded.execute == "query-yank")
        #expect(decoded.id == "swiftqemu-2")
        #expect(decoded.arguments?["k"]?.intValue == 1)
        #expect(decoded.outOfBand == outOfBand)
    }

    /// A request is in-band unless asked otherwise; nothing existing changes shape.
    @Test func requestsAreInBandByDefault() {
        #expect(!QMPRequest(execute: "quit").outOfBand)
    }

    // MARK: - Capabilities

    /// QEMU 11 advertises exactly this, and the greeting's list is what negotiation
    /// has to be driven from rather than discarded.
    @Test func greetingCapabilitiesAreDecoded() throws {
        let json = """
        {"QMP": {"version": {"qemu": {"micro": 2, "minor": 0, "major": 11}, "package": ""},
         "capabilities": ["oob"]}}
        """

        let greeting = try decoder.decode(QMPGreeting.self, from: Data(json.utf8))

        #expect(greeting.QMP.capabilities == ["oob"])
        #expect(greeting.QMP.capabilities.compactMap(QMPCapability.init(rawValue:)) == [.oob])
    }

    /// A capability QEMU invents later must not decode into one we claim to support.
    @Test func unknownCapabilityIsNotMistakenForASupportedOne() {
        #expect(QMPCapability(rawValue: "something-qemu-invents-later") == nil)
    }

    /// Nested arguments must go out as the JSON QEMU expects, and integers must
    /// stay integers — QEMU rejects an integer field that arrives as `1.0`.
    @Test func nestedArgumentEncoding() throws {
        let json = try encoded(QMPRequest(
            execute: "blockdev-add",
            arguments: [
                "driver": "qcow2",
                "node-name": "drive-vdb",
                "file": ["driver": "file", "filename": "/disks/vdb.qcow2"],
                "read-only": false,
                "size": 1024
            ]
        ))

        #expect(json.contains("\"filename\":\"\\/disks\\/vdb.qcow2\""), "\(json)")
        #expect(json.contains("\"read-only\":false"), "\(json)")
        #expect(json.contains("\"size\":1024"), "\(json)")
        #expect(!json.contains("1024.0"), "Integers must not be widened to doubles: \(json)")
    }

    // MARK: - Response decoding

    @Test func responseDecoding() throws {
        let json = """
        {
            "return": {
                "status": "running",
                "singlestep": false,
                "running": true
            },
            "id": "swiftqemu-1"
        }
        """

        guard case .response(let response) = try decodeMessage(json) else {
            Issue.record("A payload carrying `return` is a response")
            return
        }

        #expect(response.return != nil)
        #expect(response.error == nil)
        #expect(response.id?.stringValue == "swiftqemu-1")
        #expect(response.return?["status"]?.stringValue == "running")
        #expect(response.return?["running"]?.boolValue == true)
        #expect(response.return?["singlestep"]?.boolValue == false)
    }

    @Test func errorResponseDecoding() throws {
        let json = """
        {
            "error": {
                "class": "CommandNotFound",
                "desc": "The command invalid-command has not been found"
            },
            "id": "swiftqemu-1"
        }
        """

        guard case .response(let response) = try decodeMessage(json) else {
            Issue.record("A payload carrying `error` is a response")
            return
        }

        #expect(response.return == nil)
        #expect(response.error?.class == "CommandNotFound")
        #expect(response.error?.desc.contains("invalid-command") == true)
    }

    // MARK: - Event/response discrimination

    /// The bug this exists for: every property of `QMPResponse` is optional, so
    /// trying response-then-event decoded an *event* as an all-nil response.
    /// `DEVICE_DELETED` then never reached its waiter (disk detach always timed
    /// out), and an event arriving mid-command was handed over as that command's
    /// reply.
    @Test func eventIsNotDecodedAsAResponse() throws {
        let json = """
        {
            "event": "DEVICE_DELETED",
            "data": {"device": "vdb", "path": "/machine/peripheral/vdb"},
            "timestamp": {"seconds": 1745000000, "microseconds": 123456}
        }
        """

        guard case .event(let event) = try decodeMessage(json) else {
            Issue.record("An event must be discriminated as an event, not a response")
            return
        }

        #expect(event.event == "DEVICE_DELETED")
        #expect(event.data?["device"]?.stringValue == "vdb")
        #expect(event.timestamp?.seconds == 1745000000)
    }

    /// Events QEMU sends with no `data` still have to decode; a decode failure is
    /// a dropped event.
    @Test func eventWithoutDataOrTimestampStillDecodes() throws {
        guard case .event(let event) = try decodeMessage(#"{"event": "SHUTDOWN"}"#) else {
            Issue.record("Expected an event")
            return
        }
        #expect(event.event == "SHUTDOWN")
        #expect(event.data == nil)
        #expect(event.timestamp == nil)
    }

    /// An object carrying none of the discriminating keys is not a response with
    /// nothing in it — it is not a message we understand, and accepting it as an
    /// empty response is what let events be mistaken for replies.
    @Test func objectWithNoDiscriminatingKeyIsRejected() {
        #expect(throws: (any Error).self) {
            try decodeMessage(#"{"unrelated": 1}"#)
        }
    }

    // MARK: - Status parsing

    /// Modern QEMU (verified on 11.0.2) answers `query-status` without
    /// `singlestep`. Requiring it made every status query fail.
    @Test func statusResponseDecodesWithoutSinglestep() throws {
        let status = try decoder.decode(
            QMPStatusResponse.self,
            from: Data(#"{"status": "running", "running": true}"#.utf8)
        )

        #expect(status.status == "running")
        #expect(status.running)
        #expect(status.singlestep == nil)
    }

    // MARK: - JSONValue

    @Test("Scalars encode as bare JSON values", arguments: [
        (JSONValue.int(42), "42"),
        (JSONValue.string("test"), "\"test\""),
        (JSONValue.bool(true), "true"),
        (JSONValue.null, "null")
    ])
    func scalarEncoding(value: JSONValue, expected: String) throws {
        let json = try encoded(value)
        #expect(json == expected)
    }

    @Test func objectEncoding() throws {
        let object: JSONValue = ["key": "value", "number": 123]
        let json = try encoded(object)

        #expect(json.contains("\"key\":\"value\""))
        #expect(json.contains("\"number\":123"))
    }

    @Test func roundTrip() throws {
        let original: JSONValue = [
            "string": "s",
            "int": 7,
            "double": 1.5,
            "bool": true,
            "null": nil,
            "array": [1, "two", false],
            "object": ["nested": 1]
        ]

        let decoded = try decoder.decode(JSONValue.self, from: try JSONEncoder().encode(original))

        #expect(decoded == original)
    }

    @Test func accessorsReadWhatTheyName() {
        let value: JSONValue = ["list": [10, 20], "flag": false, "name": "vdb"]

        #expect(value["name"]?.stringValue == "vdb")
        #expect(value["flag"]?.boolValue == false)
        #expect(value["list"]?[1]?.intValue == 20)
        #expect(value["missing"] == nil)
        #expect(value["name"]?.intValue == nil, "A string is not an integer")
        #expect(JSONValue.null.isNull)
    }

    /// QEMU emits sizes as JSON numbers, and whether one arrives as `4096` or
    /// `4096.0` is not something a caller should have to care about — but `1.5` is
    /// not an integer however it is spelled.
    @Test("Numbers read as the types they actually represent", arguments: [
        (JSONValue.double(4096), 4096, 4096.0),
        (JSONValue.double(1.5), nil, 1.5),
        (JSONValue.int(3), 3, 3.0)
    ])
    func numericAccessors(value: JSONValue, int: Int?, double: Double?) {
        #expect(value.intValue == int)
        #expect(value.doubleValue == double)
    }
}
