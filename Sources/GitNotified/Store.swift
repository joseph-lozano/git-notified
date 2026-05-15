import Foundation

final class Store {
    private let stateURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.git-notified.store")

    init(directory: URL? = nil) throws {
        let dir = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stateURL = dir.appendingPathComponent("state.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("git-notified", isDirectory: true)
    }

    func load() -> AppState {
        queue.sync {
            guard FileManager.default.fileExists(atPath: stateURL.path),
                  let data = try? Data(contentsOf: stateURL),
                  let state = try? decoder.decode(AppState.self, from: data) else {
                return AppState()
            }
            return state
        }
    }

    /// Atomic write: encode → write to temp file in same directory → fsync → rename.
    /// Guarantees that a crash mid-write cannot leave the persisted file partially updated.
    func save(_ state: AppState) throws {
        try queue.sync {
            let data = try encoder.encode(state)
            let dir = stateURL.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".state.\(UUID().uuidString).tmp")

            let handle = try FileHandle(forWritingTo: createEmpty(at: tempURL))
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            // Atomic replace via rename. On the same volume this is atomic on macOS/APFS.
            _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tempURL)
        }
    }

    private func createEmpty(at url: URL) throws -> URL {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    var path: String { stateURL.path }
}
