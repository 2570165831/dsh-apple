import Darwin
import Foundation
import XCTest

final class BootLogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-boot-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCreatesThenAppendsWithoutTruncating() throws {
        let url = directory.appendingPathComponent("boot.log")
        try BootLogFile.append(Data("first\n".utf8), to: url)
        try BootLogFile.append(Data("中文\n".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("first\n中文\n".utf8))
    }

    func testOpenFailurePreservesHistory() throws {
        let url = directory.appendingPathComponent("boot.log")
        let original = Data("history\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard !FileManager.default.isWritableFile(atPath: url.path) else {
            throw XCTSkip("The test user can write read-only files.")
        }
        XCTAssertThrowsError(try BootLogFile.append(Data("new\n".utf8), to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testClosedHandleThrowsSwiftError() throws {
        let url = directory.appendingPathComponent("boot.log")
        try Data("history\n".utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.close()
        XCTAssertThrowsError(try BootLogFile.append(Data("new\n".utf8), to: handle))
    }

    func testWriteFailureThrowsSwiftError() throws {
        let url = directory.appendingPathComponent("boot.log")
        let original = Data("history\n".utf8)
        try original.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertThrowsError(try BootLogFile.append(Data("new\n".utf8), to: handle))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMissingParentThrowsWithoutCreatingAnything() {
        let parent = directory.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try BootLogFile.append(Data("new\n".utf8),
                                                   to: parent.appendingPathComponent("boot.log")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }
}

@main
enum BootLogFileTestMain {
    static func main() {
        let suite = BootLogFileTests.defaultTestSuite
        suite.run()
        guard let result = suite.testRun, result.executionCount > 0 else { exit(1) }
        exit(result.totalFailureCount == 0 ? 0 : 1)
    }
}
