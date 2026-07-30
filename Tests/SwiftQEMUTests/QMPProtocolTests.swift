import XCTest
@testable import SwiftQEMU

final class QMPProtocolTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decodeMessage(_ json: String) throws -> QMPMessage {
        try decoder.decode(QMPMessage.self, from: Data(json.utf8))
    }

    // MARK: - Greeting

    func testQMPGreetingDecoding() throws {
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

        XCTAssertEqual(greeting.QMP.version.qemu.major, 7)
        XCTAssertEqual(greeting.QMP.version.qemu.minor, 0)
        XCTAssertEqual(greeting.QMP.version.qemu.micro, 0)
        XCTAssertEqual(greeting.QMP.capabilities.count, 0)

        guard case .greeting = try decodeMessage(json) else {
            return XCTFail("A greeting must be discriminated as a greeting")
        }
    }

    // MARK: - Request encoding

    func testQMPRequestEncoding() throws {
        let request = QMPRequest(
            execute: "query-status",
            arguments: nil,
            id: "swiftqemu-1"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let json = String(decoding: try encoder.encode(request), as: UTF8.self)

        XCTAssertTrue(json.contains("\"execute\":\"query-status\""))
        XCTAssertTrue(json.contains("\"id\":\"swiftqemu-1\""))
    }

    /// An out-of-band request names its command under `exec-oob`.
    ///
    /// This is the only spelling QEMU 11 accepts. The `"execute"` +
    /// `"control": {"run-oob": true}` form from the original OOB proposal is
    /// rejected with `QMP input member 'control' is unexpected` (verified against
    /// 11.0.2), so encoding it that way would produce a feature that never works.
    func testOutOfBandRequestEncoding() throws {
        let request = QMPRequest(execute: "yank", arguments: ["instances": []], id: "swiftqemu-1", outOfBand: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)

        XCTAssertTrue(json.contains("\"exec-oob\":\"yank\""), json)
        XCTAssertFalse(json.contains("\"execute\""), json)
        XCTAssertFalse(json.contains("control"), json)
        // OOB requests have to be correlatable: they are answered out of order by
        // definition, so the id is what matches the reply to the caller.
        XCTAssertTrue(json.contains("\"id\":\"swiftqemu-1\""), json)
    }

    func testRequestRoundTripPreservesOutOfBand() throws {
        let encoder = JSONEncoder()

        for outOfBand in [true, false] {
            let original = QMPRequest(
                execute: "query-yank",
                arguments: ["k": 1],
                id: "swiftqemu-2",
                outOfBand: outOfBand
            )
            let decoded = try decoder.decode(QMPRequest.self, from: try encoder.encode(original))

            XCTAssertEqual(decoded.execute, "query-yank")
            XCTAssertEqual(decoded.id, "swiftqemu-2")
            XCTAssertEqual(decoded.arguments?["k"]?.intValue, 1)
            XCTAssertEqual(decoded.outOfBand, outOfBand)
        }
    }

    /// A request is in-band unless asked otherwise; nothing existing changes shape.
    func testRequestsAreInBandByDefault() throws {
        XCTAssertFalse(QMPRequest(execute: "quit").outOfBand)
    }

    // MARK: - Capabilities

    /// QEMU 11 advertises exactly this, and the greeting's list is what negotiation
    /// has to be driven from rather than discarded.
    func testGreetingCapabilitiesAreDecoded() throws {
        let json = """
        {"QMP": {"version": {"qemu": {"micro": 2, "minor": 0, "major": 11}, "package": ""},
         "capabilities": ["oob"]}}
        """

        let greeting = try decoder.decode(QMPGreeting.self, from: Data(json.utf8))

        XCTAssertEqual(greeting.QMP.capabilities, ["oob"])
        XCTAssertEqual(greeting.QMP.capabilities.compactMap(QMPCapability.init(rawValue:)), [.oob])
    }

    /// A capability QEMU invents later must not decode into one we claim to support.
    func testUnknownCapabilityIsNotMistakenForASupportedOne() {
        XCTAssertNil(QMPCapability(rawValue: "something-qemu-invents-later"))
    }

    /// Nested arguments must go out as the JSON QEMU expects, and integers must
    /// stay integers — QEMU rejects an integer field that arrives as `1.0`.
    func testNestedArgumentEncoding() throws {
        let request = QMPRequest(
            execute: "blockdev-add",
            arguments: [
                "driver": "qcow2",
                "node-name": "drive-vdb",
                "file": ["driver": "file", "filename": "/disks/vdb.qcow2"],
                "read-only": false,
                "size": 1024
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)

        XCTAssertTrue(json.contains("\"filename\":\"\\/disks\\/vdb.qcow2\""), json)
        XCTAssertTrue(json.contains("\"read-only\":false"), json)
        XCTAssertTrue(json.contains("\"size\":1024"), json)
        XCTAssertFalse(json.contains("1024.0"), "Integers must not be widened to doubles: \(json)")
    }

    // MARK: - Response decoding

    func testQMPResponseDecoding() throws {
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
            return XCTFail("A payload carrying `return` is a response")
        }

        XCTAssertNotNil(response.return)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.id?.stringValue, "swiftqemu-1")
        XCTAssertEqual(response.return?["status"]?.stringValue, "running")
        XCTAssertEqual(response.return?["running"]?.boolValue, true)
        XCTAssertEqual(response.return?["singlestep"]?.boolValue, false)
    }

    func testQMPErrorResponseDecoding() throws {
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
            return XCTFail("A payload carrying `error` is a response")
        }

        XCTAssertNil(response.return)
        XCTAssertEqual(response.error?.class, "CommandNotFound")
        XCTAssertTrue(response.error?.desc.contains("invalid-command") ?? false)
    }

    // MARK: - Event/response discrimination

    /// The bug this exists for: every property of `QMPResponse` is optional, so
    /// trying response-then-event decoded an *event* as an all-nil response.
    /// `DEVICE_DELETED` then never reached its waiter (disk detach always timed
    /// out), and an event arriving mid-command was handed over as that command's
    /// reply.
    func testEventIsNotDecodedAsAResponse() throws {
        let json = """
        {
            "event": "DEVICE_DELETED",
            "data": {"device": "vdb", "path": "/machine/peripheral/vdb"},
            "timestamp": {"seconds": 1745000000, "microseconds": 123456}
        }
        """

        guard case .event(let event) = try decodeMessage(json) else {
            return XCTFail("An event must be discriminated as an event, not a response")
        }

        XCTAssertEqual(event.event, "DEVICE_DELETED")
        XCTAssertEqual(event.data?["device"]?.stringValue, "vdb")
        XCTAssertEqual(event.timestamp?.seconds, 1745000000)
    }

    /// Events QEMU sends with no `data` still have to decode; a decode failure is
    /// a dropped event.
    func testEventWithoutDataOrTimestampStillDecodes() throws {
        guard case .event(let event) = try decodeMessage(#"{"event": "SHUTDOWN"}"#) else {
            return XCTFail("Expected an event")
        }
        XCTAssertEqual(event.event, "SHUTDOWN")
        XCTAssertNil(event.data)
        XCTAssertNil(event.timestamp)
    }

    /// An object carrying none of the discriminating keys is not a response with
    /// nothing in it — it is not a message we understand, and accepting it as an
    /// empty response is what let events be mistaken for replies.
    func testObjectWithNoDiscriminatingKeyIsRejected() {
        XCTAssertThrowsError(try decodeMessage(#"{"unrelated": 1}"#))
    }

    // MARK: - Status parsing

    /// Modern QEMU (verified on 11.0.2) answers `query-status` without
    /// `singlestep`. Requiring it made every status query fail.
    func testStatusResponseDecodesWithoutSinglestep() throws {
        let status = try decoder.decode(
            QMPStatusResponse.self,
            from: Data(#"{"status": "running", "running": true}"#.utf8)
        )

        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(status.running)
        XCTAssertNil(status.singlestep)
    }

    // MARK: - JSONValue

    func testJSONValueEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        XCTAssertEqual(String(decoding: try encoder.encode(JSONValue.int(42)), as: UTF8.self), "42")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONValue.string("test")), as: UTF8.self), "\"test\"")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONValue.bool(true)), as: UTF8.self), "true")
        XCTAssertEqual(String(decoding: try encoder.encode(JSONValue.null), as: UTF8.self), "null")

        let object: JSONValue = ["key": "value", "number": 123]
        let json = String(decoding: try encoder.encode(object), as: UTF8.self)
        XCTAssertTrue(json.contains("\"key\":\"value\""))
        XCTAssertTrue(json.contains("\"number\":123"))
    }

    func testJSONValueRoundTrip() throws {
        let original: JSONValue = [
            "string": "s",
            "int": 7,
            "double": 1.5,
            "bool": true,
            "null": nil,
            "array": [1, "two", false],
            "object": ["nested": 1]
        ]

        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(JSONValue.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testJSONValueAccessors() {
        let value: JSONValue = ["list": [10, 20], "flag": false, "name": "vdb"]

        XCTAssertEqual(value["name"]?.stringValue, "vdb")
        XCTAssertEqual(value["flag"]?.boolValue, false)
        XCTAssertEqual(value["list"]?[1]?.intValue, 20)
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["name"]?.intValue, "A string is not an integer")
        XCTAssertTrue(JSONValue.null.isNull)

        // QEMU emits sizes as JSON numbers; a whole number that arrived as a
        // double is still an integer to the caller.
        XCTAssertEqual(JSONValue.double(4096).intValue, 4096)
        XCTAssertNil(JSONValue.double(1.5).intValue)
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3.0)
    }
}
