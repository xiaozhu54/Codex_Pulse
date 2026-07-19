import Foundation

enum CodexDatabaseDiscovery {
    static func latest(prefix: String, in codexHome: URL) -> URL? {
        candidates(prefix: prefix, in: codexHome).first
    }

    static func candidates(prefix: String, in codexHome: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileResourceIdentifierKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "sqlite" }
            .sorted {
                modificationDate($0) > modificationDate($1)
            }
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
