import NIOCore

/// Splits the inbound byte stream into newline-delimited QMP frames.
///
/// Framing used to live in the channel handler by hand: append every read to one
/// long-lived `ByteBuffer`, scan it for a newline, slice a frame out, and
/// remember to `discardReadBytes()` so consumed frames did not grow the buffer
/// for the lifetime of the connection. `ByteToMessageHandler` owns all of that —
/// the buffer, the partial-frame carry-over, the reclaiming, and the re-entrancy
/// — leaving only the parts that are actually about QMP: where a frame ends, and
/// how large one may be.
///
/// The size cap is enforced here rather than through
/// `ByteToMessageHandler(_:maximumBufferSize:)`, because that cap is checked only
/// on bytes the decoder *refused* to consume. A complete frame is decoded and
/// delivered before the check ever runs, so `maximumBufferSize` bounds an
/// unterminated frame but cannot reject an over-limit complete one. Both are
/// rejected here, which is the behaviour `QMPClient.maximumFrameSize` documents.
struct QMPFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    /// Largest frame this connection will accept, terminating newline included.
    let maximumFrameSize: Int

    mutating func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
            // Nothing buffered is a frame yet, which does not make it small. A
            // peer that keeps writing and never terminates is exactly the case
            // the cap exists for, and waiting for its newline is waiting
            // forever.
            guard buffer.readableBytes <= maximumFrameSize else {
                throw QMPError.frameTooLarge(limit: maximumFrameSize)
            }
            return .needMoreData
        }

        let frameLength = buffer.readableBytesView.startIndex.distance(to: newlineIndex) + 1
        guard frameLength <= maximumFrameSize else {
            throw QMPError.frameTooLarge(limit: maximumFrameSize)
        }

        // Both reads are in-bounds: the newline was found within the readable
        // bytes, so there are at least `frameLength` of them.
        let payload = buffer.readSlice(length: frameLength - 1)!
        buffer.moveReaderIndex(forwardBy: 1) // drop the terminator
        context.fireChannelRead(wrapInboundOut(payload))
        return .continue
    }
}
