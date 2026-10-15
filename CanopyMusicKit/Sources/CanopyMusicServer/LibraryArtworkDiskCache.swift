import CryptoKit
import Foundation

/// The relay's art on disk (`LibraryArtworkRelay`), so a relaunch doesn't download it again: one
/// JPEG per image at the largest size served, in Caches (the system may clear it), named by a hash
/// of the image's key (its URL template, or the song's library id). Within `budgetBytes`, the least
/// recently used going first; a file's modification date is when it was last used.
public actor LibraryArtworkDiskCache {
    public static let shared = LibraryArtworkDiskCache(directory: URL.cachesDirectory.appending(path: "library-artwork"))
    public static let defaultBudget = 100 * 1024 * 1024

    private let directory: URL
    private let budgetBytes: Int
    /// File name → size and last use, read from the directory on first use.
    private var files: [String: (bytes: Int, used: Date)]?
    private var bytes = 0

    public init(directory: URL, budgetBytes: Int = LibraryArtworkDiskCache.defaultBudget) {
        self.directory = directory
        self.budgetBytes = budgetBytes
    }

    static func fileName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    func data(for key: String) -> Data? {
        let name = Self.fileName(key)
        guard loadIndex()[name] != nil else { return nil }
        let url = directory.appending(path: name)
        guard let data = try? Data(contentsOf: url) else {
            forget(name)
            return nil
        }
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        files?[name]?.used = now
        return data
    }

    func store(_ data: Data, for key: String) {
        guard data.count <= budgetBytes else { return }
        _ = loadIndex()
        let name = Self.fileName(key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name), options: .atomic)
        } catch {
            return
        }
        forget(name)
        files?[name] = (data.count, Date())
        bytes += data.count
        evict()
    }

    /// What's on disk now (tests).
    var totalBytes: Int {
        _ = loadIndex()
        return bytes
    }

    private func forget(_ name: String) {
        guard let old = files?.removeValue(forKey: name) else { return }
        bytes -= old.bytes
    }

    private func evict() {
        guard bytes > budgetBytes, let index = files else { return }
        for (name, _) in index.sorted(by: { $0.value.used < $1.value.used }) {
            guard bytes > budgetBytes else { break }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
            forget(name)
        }
    }

    private func loadIndex() -> [String: (bytes: Int, used: Date)] {
        if let files { return files }
        var index: [String: (bytes: Int, used: Date)] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        for url in urls where url.pathExtension == "jpg" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            index[url.lastPathComponent] = (values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        files = index
        bytes = index.values.reduce(0) { $0 + $1.bytes }
        evict()
        return files ?? [:]
    }
}
