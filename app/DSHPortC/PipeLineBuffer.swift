import Foundation

/// Frame bytes before decoding so a read boundary cannot split a UTF-8 scalar.
struct PipeLineBuffer {
    private let maxLineBytes: Int
    private var pending = Data()
    private var discarding = false

    init(maxLineBytes: Int = 1024 * 1024) {
        precondition(maxLineBytes > 0)
        self.maxLineBytes = maxLineBytes
    }

    mutating func append(_ data: Data, onDiscard: (Int) -> Void = { _ in }, handler: (String) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            if !discarding {
                if data.distance(from: start, to: end) > maxLineBytes - pending.count {
                    // Drop the whole oversized line, never parse its tail as a new one.
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                    onDiscard(maxLineBytes)
                } else {
                    pending.append(contentsOf: data[start..<end])
                }
            }
            guard let newline else { break }
            if !discarding {
                handler(String(decoding: pending, as: UTF8.self))
            }
            pending.removeAll(keepingCapacity: true)
            discarding = false
            start = data.index(after: newline)
        }
    }

    mutating func finish(handler: (String) -> Void) {
        if !discarding && !pending.isEmpty {
            handler(String(decoding: pending, as: UTF8.self))
        }
        pending.removeAll(keepingCapacity: true)
        discarding = false
    }
}
