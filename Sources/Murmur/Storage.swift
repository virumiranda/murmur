import Foundation

/// Small JSON files in ~/.config/murmur that only you can read (history, notes, dictionary...).
/// Writes are atomic and happen on a background queue, in order.
enum PrivateFile {
    private static let queue = DispatchQueue(label: "local.murmur.storage")

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// nil when the file doesn't exist yet. A file that can't be read is moved aside (never overwritten)
    /// and also gives nil.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Log.error("\(url.lastPathComponent) is unreadable: \(error.localizedDescription)")
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            do {
                let data = try encoder.encode(value)
                let dir = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // Written private from the start, then swapped in whole.
                let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
                guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]),
                      rename(tmp.path, url.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } catch {
                Log.error("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Waits for pending writes (on quit).
    static func flush() { queue.sync {} }
}
