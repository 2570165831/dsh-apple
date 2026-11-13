import Darwin
import Foundation
import XCTest

final class LockedValueTests: XCTestCase {
    private struct Report {
        var count = 0
        var detail = String(repeating: "0", count: 64)
        var capabilities = [String(repeating: "0", count: 64)]
    }

    func testSnapshotsStayIndependentAfterUpdates() {
        let store = LockedValue(Report())
        let before = store.snapshot
        let updated = store.update {
            $0.count = 1
            $0.detail = String(repeating: "1", count: 64)
            $0.capabilities.append($0.detail)
        }
        _ = store.update {
            $0.detail = String(repeating: "2", count: 64)
            $0.capabilities.removeAll()
        }
        XCTAssertEqual(before.count, 0)
        XCTAssertEqual(before.detail, String(repeating: "0", count: 64))
        XCTAssertEqual(before.capabilities, [before.detail])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.capabilities, [before.detail, updated.detail])
        XCTAssertEqual(store.snapshot.capabilities, [])
    }

    func testConcurrentSnapshotsAndUpdatesAreConsistent() {
        let store = LockedValue(Report())
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<500 {
                let updated = store.update { report in
                    report.count += 1
                    report.detail = String(repeating: String(report.count), count: 64)
                    report.capabilities = [report.detail]
                }
                XCTAssertEqual(updated.capabilities, [updated.detail])
                let snapshot = store.snapshot
                XCTAssertEqual(snapshot.detail, String(repeating: String(snapshot.count), count: 64))
                XCTAssertEqual(snapshot.capabilities, [snapshot.detail])
            }
        }
        XCTAssertEqual(store.snapshot.count, 4 * 500)
    }
}

@main
enum LockedValueTestMain {
    static func main() {
        let suite = LockedValueTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.totalFailureCount == 0 ? 0 : 1)
    }
}
