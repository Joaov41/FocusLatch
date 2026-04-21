import Foundation

enum DebugLog {
    private static let url = URL(fileURLWithPath: "/tmp/focuslatch.log")

    static func write(_ message: String) {
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
            return
        }

        try? data.write(to: url)
    }

    static func reset() {
        try? FileManager.default.removeItem(at: url)
        write("log reset")
    }
}
