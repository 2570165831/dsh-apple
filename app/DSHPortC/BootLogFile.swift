import Foundation

enum BootLogFile {
    static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            // Exclusive creation also preserves a file that appeared after the check.
            try data.write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try append(data, to: handle)
    }

    static func append(_ data: Data, to handle: FileHandle) throws {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
