import Foundation

struct CloudFolderLink: Codable {
    var fingerprint: String
    var updatedAt: String
}

struct CloudFolderConflict {
    let id: UUID
    let name: String
    let remoteFingerprint: String
    let remoteUpdatedAt: String
    var hierarchy: [RemoteFolder]? = nil
}

struct RemoteFolder: Codable {
    let owner_id: UUID
    let id: UUID
    var name: String
    var parent_id: UUID?
    var deleted_at: String?
    var updated_at: String

    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw CocoaError(.fileReadCorruptFile) }
        return date
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    func fingerprint() throws -> String {
        try Self.fingerprint(name: name, parentID: parent_id, deletedAt: deleted_at.map(Self.date))
    }
    static func fingerprint(name: String, parentID: UUID?, deletedAt: Date?) throws -> String {
        let values: [String: Any] = ["name": name, "parent": parentID?.uuidString.lowercased() as Any? ?? NSNull(),
                                    "deleted": deletedAt.map(timestamp) as Any? ?? NSNull()]
        return CloudSync.checksum(try JSONSerialization.data(withJSONObject: values, options: .sortedKeys))
    }
}

extension CloudSync {
    func syncFolders() async throws {
        guard let store, let owner = session?.user.id else { throw URLError(.userAuthenticationRequired) }
        var remote: [RemoteFolder] = [], offset = 0
        while true {
            let data = try await request("rest/v1/cloud_folders?select=owner_id,id,name,parent_id,deleted_at,updated_at&order=id&limit=500&offset=\(offset)")
            let batch = try JSONDecoder().decode([RemoteFolder].self, from: data)
            remote += batch
            if batch.count < 500 { break }
            offset += batch.count
        }
        guard Set(remote.map(\.id)).count == remote.count else { throw CocoaError(.fileReadCorruptFile) }
        var rows = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        for row in remote {
            guard row.owner_id == owner, !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.name.count <= 255 else { throw CocoaError(.fileReadCorruptFile) }
            _ = try RemoteFolder.date(row.updated_at)
            _ = try row.fingerprint()
            var parent = row.parent_id, visited: Set<UUID> = [row.id]
            while let id = parent {
                guard visited.insert(id).inserted, let ancestor = rows[id] else { throw CocoaError(.fileReadCorruptFile) }
                parent = ancestor.parent_id
            }
        }
        let initial = store.library
        var snapshot = initial, links = state.folderLinks ?? [:]
        for row in remote {
            let key = row.id.uuidString, remoteFingerprint = try row.fingerprint(), link = links[key]
            let local = initial.folder(id: row.id)
            let localFingerprint = try local.map { try RemoteFolder.fingerprint(name: $0.name, parentID: initial.parentFolder(of: $0.id)?.id, deletedAt: $0.deletedAt) }
            if let localFingerprint, localFingerprint != remoteFingerprint {
                if let link {
                    if localFingerprint != link.fingerprint && row.updated_at != link.updatedAt {
                        folderConflict = CloudFolderConflict(id: row.id, name: row.name, remoteFingerprint: remoteFingerprint, remoteUpdatedAt: row.updated_at)
                        throw folderConflictError(row.name)
                    }
                    if localFingerprint != link.fingerprint { continue }
                } else {
                    folderConflict = CloudFolderConflict(id: row.id, name: row.name, remoteFingerprint: remoteFingerprint, remoteUpdatedAt: row.updated_at)
                    throw folderConflictError(row.name)
                }
            }
            if let index = snapshot.folders.firstIndex(where: { $0.id == row.id }) {
                snapshot.folders[index].name = row.name
                snapshot.folders[index].deletedAt = try row.deleted_at.map(RemoteFolder.date)
            } else {
                var folder = NotebookFolder(id: row.id, name: row.name)
                folder.deletedAt = try row.deleted_at.map(RemoteFolder.date)
                snapshot.folders.append(folder)
            }
            for index in snapshot.folders.indices { snapshot.folders[index].childFolderIDs.removeAll { $0 == row.id } }
            if let parent = row.parent_id {
                // All rows exist before relationships are rebuilt below.
                if let index = snapshot.folders.firstIndex(where: { $0.id == parent }) { snapshot.folders[index].childFolderIDs.append(row.id) }
            }
            links[key] = CloudFolderLink(fingerprint: remoteFingerprint, updatedAt: row.updated_at)
        }
        // A child can sort before its newly downloaded parent.
        for row in remote where initial.folder(id: row.id) == nil {
            if let parent = row.parent_id, let index = snapshot.folders.firstIndex(where: { $0.id == parent }), !snapshot.folders[index].childFolderIDs.contains(row.id) {
                snapshot.folders[index].childFolderIDs.append(row.id)
            }
        }
        // A remote row can bring back the other device's legacy home as the first folder; keep one shared home.
        if snapshot.adoptSharedHomeFolder() { Diagnostics.shared.record("sync.home.adopted") }
        if snapshot.containsFolderCycle() {
            guard let row = remote.first else { throw CocoaError(.fileReadCorruptFile) }
            folderConflict = CloudFolderConflict(id: row.id, name: "Folder hierarchy", remoteFingerprint: try row.fingerprint(), remoteUpdatedAt: row.updated_at, hierarchy: remote)
            throw folderConflictError("Folder hierarchy")
        }
        if snapshot != initial {
            store.library = snapshot; store.persist()
            guard await store.flush() else { throw CocoaError(.fileWriteUnknown) }
        }
        state.folderLinks = links; try persistState()
        var pending = store.library.folders
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: { folder in
                guard let parent = store.library.parentFolder(of: folder.id)?.id else { return true }
                return rows[parent] != nil && !pending.contains(where: { $0.id == parent })
            }) else { throw CocoaError(.fileReadCorruptFile) }
            let folder = pending.remove(at: index), parent = store.library.parentFolder(of: folder.id)?.id
            let fingerprint = try RemoteFolder.fingerprint(name: folder.name, parentID: parent, deletedAt: folder.deletedAt)
            let link = state.folderLinks?[folder.id.uuidString]
            if rows[folder.id] != nil && link?.fingerprint == fingerprint { continue }
            let body: [String: Any] = ["owner_id": owner.uuidString.lowercased(), "id": folder.id.uuidString.lowercased(), "name": folder.name,
                "parent_id": parent?.uuidString.lowercased() as Any? ?? NSNull(), "deleted_at": folder.deletedAt.map(RemoteFolder.timestamp) as Any? ?? NSNull()]
            let path: String, method: String
            if let row = rows[folder.id] {
                let timestamp = row.updated_at.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                path = "rest/v1/cloud_folders?id=eq.\(folder.id.uuidString.lowercased())&updated_at=eq.\(timestamp)"; method = "PATCH"
            } else { path = "rest/v1/cloud_folders"; method = "POST" }
            let data = try await request(path, method: method, body: JSONSerialization.data(withJSONObject: body), prefer: "return=representation")
            let accepted = try JSONDecoder().decode([RemoteFolder].self, from: data)
            guard accepted.count == 1, let row = accepted.first, row.id == folder.id, row.owner_id == owner,
                  try row.fingerprint() == fingerprint else { throw folderConflictError(folder.name) }
            rows[folder.id] = row
            state.folderLinks?[folder.id.uuidString] = CloudFolderLink(fingerprint: fingerprint, updatedAt: row.updated_at)
            try persistState()
        }
    }
    func resolveFolderConflict(keepLocal: Bool) async {
        guard let conflict = folderConflict, let store, let local = store.library.folder(id: conflict.id), !running else { return }
        do {
            let fingerprint = keepLocal ? conflict.remoteFingerprint : try RemoteFolder.fingerprint(name: local.name, parentID: store.library.parentFolder(of: local.id)?.id, deletedAt: local.deletedAt)
            if state.folderLinks == nil { state.folderLinks = [:] }
            if let hierarchy = conflict.hierarchy {
                for row in hierarchy {
                    let local = store.library.folder(id: row.id)
                    let baseline = keepLocal ? try row.fingerprint() : try local.map { try RemoteFolder.fingerprint(name: $0.name, parentID: store.library.parentFolder(of: $0.id)?.id, deletedAt: $0.deletedAt) }
                    if let baseline { state.folderLinks?[row.id.uuidString] = CloudFolderLink(fingerprint: baseline, updatedAt: row.updated_at) }
                }
            } else {
                state.folderLinks?[local.id.uuidString] = CloudFolderLink(fingerprint: fingerprint, updatedAt: conflict.remoteUpdatedAt)
            }
            try persistState()
            folderConflict = nil
            await sync()
        } catch { status = error.localizedDescription }
    }
    private func folderConflictError(_ name: String) -> NSError {
        NSError(domain: "OpenNotes.Cloud", code: 409, userInfo: [NSLocalizedDescriptionKey: "Folder ‘\(name)’ changed both here and in the cloud. Both versions are preserved; resolve the folder change before retrying."])
    }
}
