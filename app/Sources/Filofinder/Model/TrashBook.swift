import Foundation

/// Remembers where items moved to the Trash by Filofinder came from, so
/// "Put Back" can restore them. (Finder keeps its own record privately;
/// items trashed elsewhere can only be put back from Finder.)
enum TrashBook {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filofinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trash-origins.json")
    }

    private static var map: [String: String] = {
        guard let data = try? Data(contentsOf: file),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }()

    private static func save() {
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file, options: .atomic) }
    }

    static func record(trashed: String, original: String) {
        guard !trashed.isEmpty else { return }
        map[trashed] = original
        save()
    }

    static func original(for trashed: String) -> String? { map[trashed] }

    static func forget(_ trashed: String) {
        if map.removeValue(forKey: trashed) != nil { save() }
    }

    static func forgetAll() {
        map.removeAll()
        save()
    }
}
