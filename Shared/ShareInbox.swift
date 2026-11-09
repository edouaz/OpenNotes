import Foundation

// Both signed targets must use the same App Group entitlement.
enum ShareInbox {
    static let group = "group.fr.catnotes.app"
    static func directory() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw CocoaError(.fileReadNoPermission) }
        let url = container.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func enqueue(_ source: URL) throws { try stage(source, in: directory()) }
    static func stage(_ source: URL, in folder: URL) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard source.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let size = values.fileSize ?? 0
        guard size > 0, size <= 150_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let ext = source.pathExtension.lowercased()
        guard ["pdf", "opennote", "catnote", "png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(ext) else { throw CocoaError(.fileReadUnknown) }
        let identifier = UUID().uuidString
        let temporary = folder.appendingPathComponent(".pending-" + identifier, isDirectory: true)
        let destination = folder.appendingPathComponent(identifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent(source.lastPathComponent))
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    static func pending() throws -> [URL] { try staged(in: directory()) }
    static func staged(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles).sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
        }
    }
    static func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
