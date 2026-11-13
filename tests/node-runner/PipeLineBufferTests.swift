import Darwin
import Foundation
import XCTest

final class PipeLineBufferTests: XCTestCase {
    private func decode(_ chunks: [Data], maxLineBytes: Int = 1024 * 1024) -> [String] {
        var buffer = PipeLineBuffer(maxLineBytes: maxLineBytes)
        var lines: [String] = []
        for chunk in chunks { buffer.append(chunk) { lines.append($0) } }
        buffer.finish { lines.append($0) }
        return lines
    }

    func testEveryUTF8Split() {
        let expected = [
            "DSHPORTC_NOTIFY {\"body\":\"中文🙂\"}",
            "DSHPORTC_BUSY {\"busy\":false}",
            "dsh web: http://127.0.0.1:1234/?token=test",
        ]
        let bytes = Data((expected.joined(separator: "\n") + "\n").utf8)
        for split in 0...bytes.count {
            XCTAssertEqual(decode([Data(bytes.prefix(split)), Data(bytes.dropFirst(split))]),
                           expected, "split at byte \(split)")
        }
        XCTAssertEqual(decode(bytes.map { Data([$0]) }), expected)
    }

    func testReadSizedBurst() {
        let log = String(repeating: "汉", count: 20_000)
        let busy = "DSHPORTC_BUSY {\"busy\":false}"
        let bytes = Data((log + "\n" + busy + "\n").utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 16 * 1024).map { start in
            Data(bytes[start..<min(start + 16 * 1024, bytes.count)])
        }
        XCTAssertEqual(decode(chunks), [log, busy])
    }

    func testInvalidBytesDoNotLoseFollowingControlLines() {
        var bytes = Data([0xFF, 0x0A])
        bytes.append(contentsOf: "DSHPORTC_BUSY {\"busy\":false}\n".utf8)
        bytes.append(contentsOf: [0xE4, 0xB8])
        XCTAssertEqual(decode([bytes]), [
            "\u{FFFD}", "DSHPORTC_BUSY {\"busy\":false}", "\u{FFFD}",
        ])
    }

    func testOversizedLineIsDiscardedUntilNewline() {
        let busy = "DSHPORTC_BUSY {}"
        let chunks = [
            Data(String(repeating: "x", count: 32).utf8),
            Data("overflow".utf8),
            Data("DSHPORTC_FATAL injected\n\(busy)\n".utf8),
        ]
        XCTAssertEqual(decode(chunks, maxLineBytes: 32), [busy])
        let exact = String(repeating: "x", count: 32)
        XCTAssertEqual(decode([Data((exact + "\n").utf8)], maxLineBytes: 32), [exact])
        XCTAssertEqual(decode([Data(String(repeating: "x", count: 33).utf8)],
                              maxLineBytes: 32), [])
    }

    func testDiscardReportsOncePerOversizedLine() {
        var buffer = PipeLineBuffer(maxLineBytes: 4)
        var limits: [Int] = []
        var lines: [String] = []
        for chunk in ["1234", "5", "tail", "\nok\n12345"] {
            buffer.append(Data(chunk.utf8), onDiscard: { limits.append($0) }) { lines.append($0) }
        }
        buffer.finish { lines.append($0) }
        XCTAssertEqual(limits, [4, 4])
        XCTAssertEqual(lines, ["ok"])
    }

    func testFinishOnlyFlushesTailOnce() {
        var buffer = PipeLineBuffer()
        var lines: [String] = []
        buffer.append(Data("one\n\ntail".utf8)) { lines.append($0) }
        XCTAssertEqual(lines, ["one", ""])
        buffer.finish { lines.append($0) }
        buffer.finish { lines.append($0) }
        XCTAssertEqual(lines, ["one", "", "tail"])
    }
}

@main
enum PipeLineBufferTestMain {
    static func main() {
        let suite = PipeLineBufferTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.totalFailureCount == 0 ? 0 : 1)
    }
}
