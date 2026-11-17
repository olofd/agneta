// Newline-delimited JSON framing for ACP over stdio: one message per line.
// Lines are bounded so a misbehaving engine can't grow memory without limit.
import Foundation

public enum LineStreamError: Error, Equatable {
    case lineTooLong(limit: Int)
}

/// Splits a byte stream into lines without the trailing newline. Each push looks only at the bytes it brought
/// and drops what it consumed once, so a long line arriving in small chunks costs time linear in its length.
public struct LineSplitter: Sendable {
    /// The most bytes a line may have, complete or still arriving.
    public let limit: Int
    private var buffer = Data()
    /// How much of `buffer` is known to hold no newline.
    private var scanned = 0

    public init(limit: Int) { self.limit = limit }

    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        let base = buffer.startIndex
        var lines: [Data] = []
        var start = base
        var from = base + scanned
        while let newline = buffer[from...].firstIndex(of: 0x0A) {
            if newline - start > limit { throw LineStreamError.lineTooLong(limit: limit) }
            let end = newline > start && buffer[newline - 1] == 0x0D ? newline - 1 : newline
            if end > start { lines.append(buffer.subdata(in: start..<end)) }
            start = newline + 1
            from = start
        }
        if start > base { buffer.removeSubrange(base..<start) }
        scanned = buffer.count
        if buffer.count > limit { throw LineStreamError.lineTooLong(limit: limit) }
        return lines
    }

    /// Whatever is left when the stream ends, if it is a complete line.
    public mutating func finish() -> Data? {
        defer {
            buffer.removeAll()
            scanned = 0
        }
        return buffer.isEmpty ? nil : buffer
    }
}

public enum LineStream {
    /// Reads `handle` on a background queue and yields complete lines.
    /// `limit`: 128 MB, so an engine's long lines (a session export or replay with inline images) fit.
    public static func lines(from handle: FileHandle, limit: Int = 128 << 20) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let thread = Thread {
                var splitter = LineSplitter(limit: limit)
                let descriptor = handle.fileDescriptor
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    do {
                        for line in try splitter.push(Data(chunk[0..<count])) { continuation.yield(line) }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                if let rest = splitter.finish() { continuation.yield(rest) }
                continuation.finish()
            }
            thread.name = "agneta.line-reader"
            thread.start()
        }
    }
}
