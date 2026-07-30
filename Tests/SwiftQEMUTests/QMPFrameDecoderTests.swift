import XCTest
import NIOCore
import NIOEmbedded
@testable import SwiftQEMU

/// Framing, in isolation from the socket.
///
/// These used to be unreachable: newline scanning lived inside the channel
/// handler alongside the waiter registry, so the only way to exercise it was to
/// stand up a fake QMP server and drive a whole client through it. As a
/// `ByteToMessageDecoder` it is a value with one job, and the awkward cases — a
/// frame split across reads, several frames in one read, a frame right on the
/// size limit — can be stated directly.
final class QMPFrameDecoderTests: XCTestCase {

    private func makeChannel(maximumFrameSize: Int) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(QMPFrameDecoder(maximumFrameSize: maximumFrameSize))
        )
        return channel
    }

    private func write(_ string: String, to channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        _ = try channel.writeInbound(buffer)
    }

    private func readFrame(from channel: EmbeddedChannel) throws -> String? {
        guard let frame: ByteBuffer = try channel.readInbound() else { return nil }
        return String(buffer: frame)
    }

    // MARK: - Framing

    /// Several frames arriving in one read are all delivered, in order, without
    /// their terminators.
    func testMultipleFramesInOneReadAreAllDelivered() throws {
        let channel = try makeChannel(maximumFrameSize: 1024)
        try write("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "{\"a\":1}")
        XCTAssertEqual(try readFrame(from: channel), "{\"b\":2}")
        XCTAssertEqual(try readFrame(from: channel), "{\"c\":3}")
        XCTAssertNil(try readFrame(from: channel))
        XCTAssertTrue(try channel.finish().isClean)
    }

    /// A frame split across reads is delivered once, when it completes — and
    /// nothing is delivered before that. Payloads of tens of KB genuinely arrive
    /// this way.
    func testFrameSplitAcrossReadsIsDeliveredOnce() throws {
        let channel = try makeChannel(maximumFrameSize: 1024)

        try write("{\"return\": ", to: channel)
        XCTAssertNil(try readFrame(from: channel), "A partial frame is not a frame")

        try write("{}}", to: channel)
        XCTAssertNil(try readFrame(from: channel), "Still no terminator")

        try write("\n", to: channel)
        XCTAssertEqual(try readFrame(from: channel), "{\"return\": {}}")
        XCTAssertTrue(try channel.finish().isClean)
    }

    /// Bytes trailing the last terminator are held for the frame they belong to,
    /// not delivered as one.
    func testTrailingPartialFrameIsHeldBack() throws {
        let channel = try makeChannel(maximumFrameSize: 1024)
        try write("{\"a\":1}\n{\"b\"", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "{\"a\":1}")
        XCTAssertNil(try readFrame(from: channel))
        // The leftover is still buffered, so this is deliberately not a clean
        // finish.
        _ = try? channel.finish()
    }

    /// QEMU terminates QMP messages with `\r\n`. Only the `\n` is a delimiter, so
    /// the `\r` stays in the payload, where JSON decoding treats it as trailing
    /// whitespace. Stripping it is not this layer's business, but *losing* the
    /// frame would be.
    func testCarriageReturnStaysInThePayload() throws {
        let channel = try makeChannel(maximumFrameSize: 1024)
        try write("{\"a\":1}\r\n", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "{\"a\":1}\r")
        XCTAssertTrue(try channel.finish().isClean)
    }

    /// An empty frame is a frame. Rejecting it belongs to the JSON layer, which
    /// logs an unknown message and carries on; dropping it here would silently
    /// resynchronise on a stream we do not understand.
    func testEmptyFrameIsDelivered() throws {
        let channel = try makeChannel(maximumFrameSize: 1024)
        try write("\n", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "")
        XCTAssertTrue(try channel.finish().isClean)
    }

    // MARK: - Frame limit

    /// The cap counts the terminator, so a frame that exactly fills it is legal.
    func testFrameExactlyAtTheLimitIsDelivered() throws {
        let channel = try makeChannel(maximumFrameSize: 3)
        try write("ab\n", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "ab")
        XCTAssertTrue(try channel.finish().isClean)
    }

    /// One byte more, and the frame is refused. This is the branch
    /// `ByteToMessageHandler(_:maximumBufferSize:)` cannot cover: the frame is
    /// complete, so it would be decoded and delivered before any buffer-size check
    /// ran.
    func testCompleteFrameOverTheLimitIsRejected() throws {
        let channel = try makeChannel(maximumFrameSize: 3)

        do {
            try write("abc\n", to: channel)
            XCTFail("Expected an oversized frame to be rejected")
        } catch let error as QMPError {
            guard case .frameTooLarge(let limit) = error else {
                return XCTFail("Expected .frameTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 3)
        }
        _ = try? channel.finish()
    }

    /// A peer that keeps writing and never terminates is refused once what it has
    /// written passes the cap — waiting for its newline is waiting forever.
    func testUnterminatedFrameOverTheLimitIsRejected() throws {
        let channel = try makeChannel(maximumFrameSize: 8)

        try write("1234", to: channel)
        XCTAssertNil(try readFrame(from: channel))

        do {
            try write("567890", to: channel)
            XCTFail("Expected an unterminated over-limit frame to be rejected")
        } catch let error as QMPError {
            guard case .frameTooLarge(let limit) = error else {
                return XCTFail("Expected .frameTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 8)
        }
        _ = try? channel.finish()
    }

    /// The cap applies per frame, not to a read that happens to carry several
    /// small ones. A cap on the aggregate would reject perfectly ordinary traffic
    /// whenever the socket handed us a busy read.
    func testManySmallFramesInOneReadDoNotTripTheLimit() throws {
        let channel = try makeChannel(maximumFrameSize: 8)
        try write("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", to: channel)

        XCTAssertEqual(try readFrame(from: channel), "{\"a\":1}")
        XCTAssertEqual(try readFrame(from: channel), "{\"b\":2}")
        XCTAssertEqual(try readFrame(from: channel), "{\"c\":3}")
        XCTAssertTrue(try channel.finish().isClean)
    }
}
