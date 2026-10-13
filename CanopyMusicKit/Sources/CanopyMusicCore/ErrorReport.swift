import Foundation

/// Everything an error says about itself: its type, case, NSError domain/code/user info, and any
/// underlying errors, for debug logs. (`String(reflecting:)` alone can be as little as ".unknown".)
public enum ErrorReport {
    public static func describe(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines = ["\(indent)\(type(of: error)) \(String(reflecting: error)) — \(ns.domain) \(ns.code)"]
        for (key, value) in ns.userInfo where key != NSUnderlyingErrorKey && key != NSMultipleUnderlyingErrorsKey {
            lines.append("\(indent)  \(key): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, depth < 5 {
            lines.append(describe(underlying, depth: depth + 1))
        }
        for underlying in (ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] ?? []) where depth < 5 {
            lines.append(describe(underlying, depth: depth + 1))
        }
        return lines.joined(separator: "\n")
    }

    /// Appends a report to Library/Caches/music-errors.log (debug builds), newest last.
    public static func log(_ error: Error, context: String) {
        #if DEBUG
        let text = "\(Date()) \(context)\n\(describe(error))\n\n"
        let url = URL.cachesDirectory.appending(path: "music-errors.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
        #endif
    }
}
