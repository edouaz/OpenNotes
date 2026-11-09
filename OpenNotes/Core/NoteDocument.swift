// Derived from Signotes, copyright (c) 2026 Diego Signorastri. MIT; see docs/Signotes-LICENSE.
import Foundation

struct NoteDocument: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var folderID: UUID
    var title: String
    var favorite: Bool?
    var deletedAt: Date?
    var purgedAt: Date?
    var colorHex: String?
    var pageIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        folderID: UUID,
        title: String,
        colorHex: String? = nil,
        pageIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.colorHex = colorHex
        self.pageIDs = pageIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
