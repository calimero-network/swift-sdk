import Foundation

/// The lines of an event stream, read from its bytes with a size limit
/// (SEC-08). `URLSession.AsyncBytes.lines` buffers a line however long it
/// grows, so a hostile node, relay or man-in-the-middle could make the app
/// hold an endless one.
///
/// A line ends at `\n`, `\r\n` or `\r`, as the SSE spec has it. A line over
/// `limit` bytes, or an event whose fields (every non-comment line since the
/// last blank one) add up to more, throws ``MeroError/network(_:)``, and the
/// caller drops the connection. Comment lines (`:` keep-alives) never count
/// towards an event.
struct SseLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base
    let limit: Int

    init(_ base: Base, limit: Int) {
        self.base = base
        self.limit = limit
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), limit: limit)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let limit: Int
        private var line: [UInt8] = []
        private var eventBytes = 0
        private var afterCR = false
        private var finished = false

        init(base: Base.AsyncIterator, limit: Int) {
            self.base = base
            self.limit = limit
        }

        mutating func next() async throws -> String? {
            guard !finished else { return nil }
            while let byte = try await base.next() {
                if afterCR {
                    afterCR = false
                    if byte == 0x0a { continue }  // the `\n` of a `\r\n`
                }
                if byte == 0x0a || byte == 0x0d {
                    afterCR = byte == 0x0d
                    return take()
                }
                guard line.count < limit else { throw sseTooLarge("line", limit) }
                line.append(byte)
                if line[0] != 0x3a {  // not a `:` comment
                    eventBytes += 1
                    guard eventBytes <= limit else { throw sseTooLarge("event", limit) }
                }
            }
            finished = true
            return line.isEmpty ? nil : take()
        }

        private mutating func take() -> String {
            // A blank line ends the event.
            if line.isEmpty { eventBytes = 0 }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return text
        }
    }
}

private func sseTooLarge(_ what: String, _ limit: Int) -> MeroError {
    MeroError.network("SSE \(what) exceeds \(limit) bytes")
}
