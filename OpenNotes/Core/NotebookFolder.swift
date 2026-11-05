// Derived from Signotes, copyright (c) 2026 Diego Signorastri. MIT; see docs/Signotes-LICENSE.
import Foundation

struct NotebookFolder: Identifiable, Codable, Equatable, Sendable {
    /// Home folder of every NEW library. Shared across devices so synced notebooks land in the home folder on all of them
    /// (the library UI treats `folders.first` as home; a per-device random ID made the other device's home unreachable).
    static let homeID = UUID(uuidString: "0F0F0F0F-0000-4000-8000-000000000001")!
    let id: UUID
    var name: String
    var colorHex: String?
    var noteIDs: [UUID]
    var childFolderIDs: [UUID]
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        noteIDs: [UUID] = [],
        childFolderIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.noteIDs = noteIDs
        self.childFolderIDs = childFolderIDs
    }
}
