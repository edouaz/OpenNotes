import SwiftUI
import CryptoKit
import Security
import Network

struct CloudConfiguration: Decodable {
    let url: URL
    let publishableKey: String
    static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") { return true }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return payload["role"] as? String == "anon"
    }
    static func load() -> CloudConfiguration? {
        guard let file = Bundle.main.url(forResource: "Supabase", withExtension: "plist"),
              let data = try? Data(contentsOf: file), let config = try? PropertyListDecoder().decode(Self.self, from: data),
              config.url.scheme == "https", !config.publishableKey.isEmpty,
              Self.isPublicKey(config.publishableKey) else { return nil }
        return config
    }
}
extension CloudConfiguration {
    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case url, publishableKey }
        let values = try decoder.container(keyedBy: Keys.self)
        let address = try values.decode(String.self, forKey: .url)
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: values, debugDescription: "Expected an HTTPS server address.")
        }
        self.url = url
        publishableKey = try values.decode(String.self, forKey: .publishableKey)
    }
}
struct AuthSession: Codable {
    struct User: Codable { let id: UUID; var email: String? = nil }
    let access_token: String
    let refresh_token: String
    let expires_in: Int
    let user: User
    var savedAt: Date? = Date()
    var expired: Bool { Date().timeIntervalSince(savedAt ?? .distantPast) > Double(expires_in - 60) }
}
struct RemoteRevision: Codable {
    let id: UUID
    let owner_id: UUID
    let notebook_id: UUID
    let parent_id: UUID?
    let checksum: String
    let object_path: String
}
struct CloudLink: Codable {
    var modifiedAt: Date?
    var remoteID: UUID
    var revision: UUID?
    var checksum: String
}
struct SyncConflict: Codable, Identifiable {
    var id = UUID()
    let localID: UUID
    let remoteCopyID: UUID
    var remoteRevision: UUID? = nil
}
struct SyncState: Codable {
    var conflicts: [SyncConflict]?
    var owner: UUID?
    var folderLinks: [String: CloudFolderLink]?
    var links: [String: CloudLink] = [:]
    var seen: Set<UUID> = []
    var lastSuccessfulSync: Date?
    var lastPrune: Date?
    /// Storage files of revisions already deleted from the database whose removal Storage has not confirmed yet; retried later.
    var pendingStorageDeletes: [String]?
    /// True once the server-side metadata index has been filled for notebooks committed before it existed.
    var metaBackfilled: Bool?
}

enum CloudSyncPhase { case local, paused, pending, syncing, synced, offline, failed, needsSignIn, conflict }

@MainActor
final class CloudSync: ObservableObject {
    @Published var phase: CloudSyncPhase = .local
    @Published var status = "Local · no account required"
    @Published var signedIn = false
    @Published var running = false
    @Published var email = ""
    @Published var password = ""
    @Published var enabled = false
    @Published var needsSignIn = false
    @Published var folderConflict: CloudFolderConflict?
    @Published var notebookFailures: [UUID: String] = [:]
    private let config: CloudConfiguration?
    private let transport: ((URLRequest) async throws -> (Data, URLResponse))?
    private let stateURL: URL
    private let writeSession: (Data) throws -> Void
    private let deleteSession: () throws -> Void
    private var stateError: Error?
    weak var store: LibraryStore?
    var session: AuthSession?
    var state = SyncState()
    private var loop: Task<Void, Never>?
    private var scheduledSync: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var persistedState = SyncState()
    private var generation = 0
    private var pendingSaves = 0
    private var saveFailed = false
    private var syncRequested = false
    /// Minimum time between two cloud revisions of the same notebook while it is being edited (storage is limited; every revision is a full copy).
    var minUploadInterval: TimeInterval = 60
    private var lastUpload: [UUID: Date] = [:]
    private var bypassThrottle = false
    private var lastPruneAttempt = Date.distantPast
    var lastSuccessfulSync: Date? { state.lastSuccessfulSync }
    var conflicts: [SyncConflict] { state.conflicts ?? [] }
    var configured: Bool { config != nil }
    var syncStateAvailable: Bool { stateError == nil }
    var accountEmail: String? { session?.user.email }
    var libraryLinked: Bool { session != nil && state.owner == session?.user.id }
    var accountMismatch: Bool { session != nil && state.owner != nil && !libraryLinked }
    init(store: LibraryStore, configuration: CloudConfiguration? = CloudConfiguration.load(), auth: AuthSession? = nil,
         transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil,
         readSession: () throws -> Data? = Keychain.read, writeSession: @escaping (Data) throws -> Void = Keychain.write,
         deleteSession: @escaping () throws -> Void = Keychain.delete) {
        self.store = store; self.config = configuration; self.transport = transport
        self.writeSession = writeSession; self.deleteSession = deleteSession
        stateURL = store.root.appendingPathComponent("cloud-state.json")
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL))
            } else if let data = UserDefaults.standard.data(forKey: "cloud-state") {
                state = try JSONDecoder().decode(SyncState.self, from: data)
                try persistState()
            }
        } catch { stateError = error; status = "Cloud state could not be opened. No data will be sent." }
        persistedState = state
        if let auth { session = auth; signedIn = true }
        else if let data = try? readSession(), let saved = try? JSONDecoder().decode(AuthSession.self, from: data) { session = saved; signedIn = true }
        enabled = UserDefaults.standard.bool(forKey: "cloud-enabled")
        if stateError == nil, signedIn { status = enabled ? "Signed in · waiting to sync" : "Signed in · sync paused" }
        if !configured { status = "Supabase not configured · local storage" }
        if stateError != nil { phase = .failed }
        else if configured, accountMismatch { phase = .conflict; status = "This library is linked to another account. No data was sent." }
        else if configured, libraryLinked { phase = enabled ? .pending : .paused }
    }
    deinit { loop?.cancel(); scheduledSync?.cancel(); monitor?.cancel() }
    func start() {
        guard loop == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.syncSoon() }
        }
        monitor.start(queue: DispatchQueue(label: "cloud-sync-network"))
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active { await self?.sync() }
                // Exponential backoff on repeated failures: 30s, 60s, ... capped at 10 min. Network return and saves still sync immediately.
                if let phase = self?.phase { failures = (phase == .failed || phase == .offline) ? min(failures + 1, 5) : 0 }
                do { try await Task.sleep(nanoseconds: UInt64(min(30 << max(failures - 1, 0), 600)) * 1_000_000_000) } catch { break }
            }
        }
    }
    func localChangesWillSave() {
        generation += 1; pendingSaves += 1
        if configured && enabled && libraryLinked && !needsSignIn { phase = .pending; status = "Changes waiting to sync" }
    }
    func localChangesDidSave() {
        pendingSaves = max(0, pendingSaves - 1); saveFailed = false
        syncSoon()
    }
    func localSaveFailed() {
        pendingSaves = max(0, pendingSaves - 1); saveFailed = true
        if configured && enabled && libraryLinked { phase = .failed; status = "Could not save local changes" }
    }
    func syncSoon() {
        guard configured, enabled, libraryLinked, !needsSignIn, stateError == nil else { return }
        syncRequested = true
        if !running && !saveFailed { phase = .pending; status = "Changes waiting to sync" }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            guard let self else { return }
            self.scheduledSync = nil
            await self.sync()
        }
    }
    /// Called when the app goes to the background: upload pending edits now, ignoring the throttle, before iOS suspends us.
    func flushBeforeBackground() {
        guard configured, enabled, libraryLinked, !needsSignIn else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        bypassThrottle = true
        Task {
            await sync()
            bypassThrottle = false
            UIApplication.shared.endBackgroundTask(task)
        }
    }
    /// Deletes storage files and returns the paths Storage did NOT confirm (Storage answers 200 with only the files it actually removed,
    /// so a missing delete policy would otherwise look like success).
    func resetPruneThrottleForTesting() { lastPruneAttempt = .distantPast; lastBackfillAttempt = .distantPast }
    private var lastBackfillAttempt = Date.distantPast
    /// Searchable summary stored next to each revision so agents can list and filter notebooks without downloading them.
    nonisolated static func metadata(_ note: NoteDocument, pageCount: Int) -> [String: Any] {
        ["title": note.title, "folder_id": note.folderID.uuidString.lowercased(), "page_count": pageCount,
         "updated_at": RemoteFolder.timestamp(note.updatedAt), "trashed": note.deletedAt != nil, "purged": note.purgedAt != nil, "favorite": note.favorite == true]
    }
    /// One-time: notebooks committed before the metadata index existed get their summary from the local copy. Retried hourly until it succeeds.
    private func backfillMetadata() async {
        guard state.metaBackfilled != true, let store, Date().timeIntervalSince(lastBackfillAttempt) > 3_600 else { return }
        lastBackfillAttempt = Date()
        do {
            for (key, link) in state.links {
                guard let id = UUID(uuidString: key), let note = store.library.note(id: id) else { continue }
                let body = try JSONSerialization.data(withJSONObject: ["p_notebook_id": link.remoteID.uuidString.lowercased(), "p_meta": Self.metadata(note, pageCount: note.pageIDs.count)])
                _ = try await request("rest/v1/rpc/set_notebook_meta", method: "POST", body: body)
            }
            state.metaBackfilled = true; try persistState()
            Diagnostics.shared.record("sync.meta.backfilled", ["notebooks": String(state.links.count)])
        } catch { Diagnostics.shared.failure("sync.meta.skipped", error: error) }
    }
    private func deleteStorageObjects(_ paths: [String]) async throws -> [String] {
        struct Deleted: Decodable { let name: String }
        var remaining: [String] = []
        for start in stride(from: 0, to: paths.count, by: 100) {
            let batch = Array(paths[start..<min(start + 100, paths.count)])
            do {
                let data = try await request("storage/v1/object/notebooks", method: "DELETE", body: JSONSerialization.data(withJSONObject: ["prefixes": batch]))
                // An unreadable success body is treated as confirmed; an empty or partial list is not.
                guard let confirmed = try? JSONDecoder().decode([Deleted].self, from: data) else { continue }
                let names = Set(confirmed.map(\.name))
                remaining += batch.filter { !names.contains($0) }
            } catch {
                if (error as NSError).domain == "Supabase" && (error as NSError).code == 401 { throw error }
                remaining += batch
            }
        }
        return remaining
    }
    /// Keeps only the newest 10 revisions per notebook (the server never deletes the head) and removes their files. At most hourly;
    /// the database prune runs daily, unconfirmed file deletions are retried on every attempt. Failures are harmless.
    private func pruneOldRevisions() async {
        let due = Date().timeIntervalSince(state.lastPrune ?? .distantPast) > 86_400
        guard due || !(state.pendingStorageDeletes ?? []).isEmpty, Date().timeIntervalSince(lastPruneAttempt) > 3_600 else { return }
        lastPruneAttempt = Date()
        do {
            var pruned = 0
            if due {
                struct Removed: Decodable { let removed_path: String }
                let data = try await request("rest/v1/rpc/prune_my_revisions", method: "POST", body: Data(#"{"p_keep":10}"#.utf8))
                let paths = try JSONDecoder().decode([Removed].self, from: data).map(\.removed_path)
                pruned = paths.count
                // Rows are already gone: remember the files before trying to delete them so a crash or error cannot orphan them forever.
                state.pendingStorageDeletes = (state.pendingStorageDeletes ?? []) + paths
                state.lastPrune = Date(); try persistState()
            }
            let remaining = try await deleteStorageObjects(state.pendingStorageDeletes ?? [])
            state.pendingStorageDeletes = remaining.isEmpty ? nil : remaining; try persistState()
            Diagnostics.shared.record("sync.pruned", ["revisions": String(pruned), "filesPending": String(remaining.count)])
        } catch { Diagnostics.shared.failure("sync.prune.skipped", error: error) }
    }
    func foregrounded() {
        guard configured, enabled, libraryLinked, !needsSignIn else { return }
        syncRequested = true
        Task { await sync() }
    }
    func authenticate(signup: Bool) async {
        guard !running else { password = ""; return }
        running = true; defer {
            running = false; password = ""
            if signedIn && enabled && libraryLinked && !needsSignIn { syncSoon() }
        }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.contains("@"), !password.isEmpty else { status = "Enter your email and password."; return }
        guard !signup || password.count >= 6 else { status = "Use a password of at least 6 characters."; return }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["email": address, "password": password])
            let data = try await request(signup ? "auth/v1/signup" : "auth/v1/token?grant_type=password", method: "POST", body: body, authenticated: false)
            guard var auth = try? JSONDecoder().decode(AuthSession.self, from: data), !auth.access_token.isEmpty, !auth.refresh_token.isEmpty else {
                if signup, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = ((object["user"] as? [String: Any]) ?? object)["id"] as? String, UUID(uuidString: id) != nil,
                   object["access_token"] == nil || object["access_token"] is NSNull {
                    status = "Check your email for a verification link, then sign in."
                } else { status = "The server returned an invalid account response. Please try again." }
                return
            }
            auth.savedAt = Date(); try writeSession(JSONEncoder().encode(auth))
            session = auth; signedIn = true; needsSignIn = false
            phase = stateError != nil ? .failed : libraryLinked ? (enabled ? .pending : .paused) : .local
            status = stateError != nil ? "Cloud state could not be opened. No data will be sent." : libraryLinked ? (enabled ? "Signed in · waiting to sync" : "Signed in · sync paused") : "Signed in · link the library to sync"
            if stateError == nil, accountMismatch { phase = .conflict; status = "This library is linked to another account. No data was sent." }
        } catch { status = Self.authMessage(error, signup: signup) }
    }
    private static func authMessage(_ error: Error, signup: Bool) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return "Connection unavailable. Check your internet and try again." }
        if error.domain == "Supabase" {
            switch error.code {
            case 400, 401: return signup ? "Could not create the account. Check your email and password." : "Could not sign in. Check your email, password, and email verification."
            case 422: return "The account details could not be accepted. Check your email and password."
            case 429: return "Too many attempts. Please wait and try again."
            default: return "Account service unavailable. Please try again."
            }
        }
        return "Could not save or open your account. Please try again."
    }
    func pauseSync() {
        enabled = false; UserDefaults.standard.set(false, forKey: "cloud-enabled")
        scheduledSync?.cancel(); scheduledSync = nil; syncRequested = false; phase = .paused
        status = "Sync paused · notebooks kept on this device"
    }
    func signOut() {
        guard !running else { return }
        do { try deleteSession(); session = nil; signedIn = false; needsSignIn = false; scheduledSync?.cancel(); scheduledSync = nil; syncRequested = false; phase = .local; status = "Signed out on this device · notebooks kept here" }
        catch { status = "Could not sign out on this device. Please try again." }
    }
    func bindAndSync() async {
        guard stateError == nil else { status = "Cloud state could not be opened. No data will be sent."; return }
        guard let session, !needsSignIn else { return }
        guard state.owner == nil || state.owner == session.user.id else { status = "This library is linked to another account. No data was sent."; return }
        state.owner = session.user.id
        do { try persistState(); enabled = true; UserDefaults.standard.set(true, forKey: "cloud-enabled"); await sync() }
        catch { status = error.localizedDescription }
    }
    func sync() async {
        guard stateError == nil, configured, enabled, !needsSignIn, let store, store.ready, let auth = session, state.owner == auth.user.id else { return }
        guard !running else { syncRequested = true; return }
        guard pendingSaves == 0 else { phase = saveFailed ? .failed : .pending; return }
        scheduledSync?.cancel(); scheduledSync = nil; syncRequested = false
        let startGeneration = generation
        running = true; defer {
            running = false
            if syncRequested && enabled && !needsSignIn && !saveFailed && phase == .pending { syncSoon() }
        }
        phase = .syncing; status = "Syncing…"
        Diagnostics.shared.record("sync.begin", ["notes": String(store.library.notes.count), "links": String(state.links.count)])
        var refreshing = false, skipped = false
        var stage = "Preparing sync"
        do {
            if saveFailed {
                guard await store.flush() else { throw CocoaError(.fileWriteUnknown) }
            }
            if auth.expired {
                refreshing = true
                let body = try JSONSerialization.data(withJSONObject: ["refresh_token": auth.refresh_token])
                let data = try await request("auth/v1/token?grant_type=refresh_token", method: "POST", body: body, authenticated: false)
                var renewed = try JSONDecoder().decode(AuthSession.self, from: data)
                guard renewed.user.id == auth.user.id, !renewed.access_token.isEmpty, !renewed.refresh_token.isEmpty else { throw NSError(domain: "Supabase", code: 401) }
                renewed.savedAt = Date()
                try writeSession(JSONEncoder().encode(renewed)); session = renewed; refreshing = false
            }
            let owner = session!.user.id
            stage = "Reading cloud folders"
            try await syncFolders()
            struct Head: Decodable { let notebook_id: UUID; let revision_id: UUID }
            stage = "Reading notebook list"
            var heads: [Head] = []
            var offset = 0
            while true {
                let data = try await request("rest/v1/notebook_heads?select=notebook_id,revision_id&order=notebook_id&limit=500&offset=\(offset)")
                let batch = try JSONDecoder().decode([Head].self, from: data)
                heads.append(contentsOf: batch)
                if batch.count < 500 { break }
                offset += batch.count
            }
            Diagnostics.shared.record("sync.heads", ["remote": String(heads.count), "local": String(store.library.notes.count)])
            var downloadFailures: [String] = []
            var newFailures: [UUID: String] = [:]
            var failedNotebooks: Set<UUID> = []
            for head in heads {
                do {
                    stage = "Reading notebook \(head.notebook_id.uuidString.prefix(8))"
                    let localID = (state.links.first(where: { $0.value.remoteID == head.notebook_id })?.key).flatMap { UUID(uuidString: $0) } ?? head.notebook_id
                    let link = state.links[localID.uuidString]
                    if link?.revision == head.revision_id || conflicts.contains(where: { $0.localID == localID }) { continue }
                    guard await store.flushEditors(for: localID) else { skipped = true; continue }
                    let expected = store.library.note(id: localID)
                    let localArchive: NotebookArchive?
                    if expected != nil { localArchive = try await store.archive(localID) } else { localArchive = nil }
                    let localChecksum: String?
                    if let localArchive {
                        localChecksum = try await Task.detached(priority: .utility) { Self.checksum(try Self.encode(localArchive)) }.value
                    } else { localChecksum = nil }
                    let data = try await request("rest/v1/notebook_revisions?select=id,owner_id,notebook_id,parent_id,checksum,object_path&id=eq.\(head.revision_id.uuidString.lowercased())")
                    let revisions = try JSONDecoder().decode([RemoteRevision].self, from: data)
                    guard let revision = revisions.first, revisions.count == 1, revision.owner_id == owner,
                          revision.notebook_id == head.notebook_id,
                          revision.object_path == "\(owner.uuidString.lowercased())/\(head.notebook_id.uuidString.lowercased())/\(head.revision_id.uuidString.lowercased()).catnote" else { throw CocoaError(.fileReadCorruptFile) }
                    stage = "Downloading notebook \(head.notebook_id.uuidString.prefix(8))"
                    let archiveData = try await request("storage/v1/object/authenticated/notebooks/" + revision.object_path)
                    stage = "Decoding notebook \(head.notebook_id.uuidString.prefix(8))"
                    let archive = try await Task.detached(priority: .utility) {
                        guard Self.checksum(archiveData) == revision.checksum else { throw CocoaError(.fileReadCorruptFile) }
                        let archive = try JSONDecoder().decode(NotebookArchive.self, from: archiveData)
                        try archive.validate()
                        return archive
                    }.value
                    guard archive.note.id == head.notebook_id else { throw CocoaError(.fileReadCorruptFile) }
                    // A lost commit response is safe to retry without manufacturing a conflict.
                    if localChecksum == revision.checksum {
                        state.links[localID.uuidString] = CloudLink(modifiedAt: expected?.updatedAt, remoteID: head.notebook_id, revision: head.revision_id, checksum: localChecksum!)
                    } else if expected != nil && (link == nil || link?.checksum != localChecksum) {
                        var remoteCopy = archive; remoteCopy.note.title += " · remote revision"
                        let copyID = try await store.importArchive(remoteCopy)
                        guard await store.flush() else { throw CocoaError(.fileWriteUnknown) }
                        state.conflicts = conflicts + [SyncConflict(localID: localID, remoteCopyID: copyID, remoteRevision: head.revision_id)]
                    } else {
                        guard await store.flushEditors(for: localID), store.library.note(id: localID) == expected else { skipped = true; continue }
                        stage = "Installing notebook \(head.notebook_id.uuidString.prefix(8))"
                        _ = try await store.applyCloudArchive(archive, expected: expected)
                        Diagnostics.shared.record("sync.installed", ["note": String(head.notebook_id.uuidString.prefix(8)), "folder": String(archive.note.folderID.uuidString.prefix(8))])
                        let installed = try await store.archive(head.notebook_id)
                        state.links[head.notebook_id.uuidString] = CloudLink(modifiedAt: installed.note.updatedAt, remoteID: head.notebook_id, revision: head.revision_id, checksum: installed.note == archive.note ? try await Task.detached(priority: .utility) { Self.checksum(try Self.encode(installed)) }.value : "")
                    }
                    state.seen.insert(head.revision_id); try persistState()
                } catch {
                    let failure = error as NSError
                    if failure.domain == "Supabase" && failure.code == 401 { throw error }
                    failedNotebooks.insert(head.notebook_id)
                    let message = Self.failureMessage(error, stage: stage)
                    downloadFailures.append(message); newFailures[head.notebook_id] = message
                }
            }
            var uploadFailures: [String] = []
            for note in store.library.notes {
                if failedNotebooks.contains(state.links[note.id.uuidString]?.remoteID ?? note.id) { continue }
                stage = "Uploading notebook \(note.id.uuidString.prefix(8))"
                if conflicts.contains(where: { $0.localID == note.id || $0.remoteCopyID == note.id }) { continue }
                // One failing notebook (too large, stale head, bad archive) must not block the others.
                do {
                    guard await store.flushEditors(for: note.id) else { skipped = true; continue }
                    let archive = try await store.archive(note.id)
                    let (data, checksum) = try await Task.detached(priority: .utility) {
                        // Never publish ink another device cannot decode: fail here, on the device that owns the data.
                        for page in archive.pages { _ = try InkDrawing(data: archive.resources[page.drawingResourceID]!) }
                        let data = try Self.encode(archive)
                        return (data, Self.checksum(data))
                    }.value
                    let link = state.links[note.id.uuidString] ?? CloudLink(remoteID: note.id, revision: nil, checksum: "")
                    if link.checksum == checksum { continue }
                    if !bypassThrottle, let last = lastUpload[note.id], Date().timeIntervalSince(last) < minUploadInterval { skipped = true; continue }
                    let revisionID = UUID()
                    let path = "\(owner.uuidString.lowercased())/\(link.remoteID.uuidString.lowercased())/\(revisionID.uuidString.lowercased()).catnote"
                    _ = try await request("storage/v1/object/notebooks/" + path, method: "POST", body: data, contentType: "application/octet-stream")
                    let commit: [String: Any] = ["p_notebook_id": link.remoteID.uuidString.lowercased(), "p_revision_id": revisionID.uuidString.lowercased(),
                        "p_expected_revision": link.revision.map { $0.uuidString.lowercased() } as Any? ?? NSNull(), "p_checksum": checksum, "p_object_path": path,
                        "p_meta": Self.metadata(archive.note, pageCount: archive.pages.count)]
                    _ = try await request("rest/v1/rpc/commit_notebook_revision", method: "POST", body: JSONSerialization.data(withJSONObject: commit))
                    state.links[note.id.uuidString] = CloudLink(modifiedAt: archive.note.updatedAt, remoteID: link.remoteID, revision: revisionID, checksum: checksum)
                    lastUpload[note.id] = Date()
                    Diagnostics.shared.record("sync.uploaded", ["note": String(note.id.uuidString.prefix(8)), "bytes": String(data.count)])
                    state.seen.insert(revisionID); try persistState()
                } catch {
                    let failure = error as NSError
                    // Auth loss and network loss affect every notebook; stop and let the outer handler classify them.
                    if (failure.domain == "Supabase" && failure.code == 401) || failure.domain == NSURLErrorDomain || error is CancellationError { throw error }
                    let message = Self.failureMessage(error, stage: stage)
                    uploadFailures.append(message); newFailures[note.id] = message
                }
            }
            // Recheck editors after network awaits so newly staged work is never reported as synced.
            for note in store.library.notes where !conflicts.contains(where: { $0.localID == note.id || $0.remoteCopyID == note.id }) {
                guard await store.flushEditors(for: note.id) else { skipped = true; continue }
                let archive = try await store.archive(note.id)
                let checksum = try await Task.detached(priority: .utility) { Self.checksum(try Self.encode(archive)) }.value
                if state.links[note.id.uuidString]?.checksum != checksum { skipped = true }
            }
            notebookFailures = newFailures
            Diagnostics.shared.record("sync.end", ["failures": String(newFailures.count), "conflicts": String(conflicts.count)])
            if !downloadFailures.isEmpty {
                throw NSError(domain: "OpenNotes.Cloud", code: 422, userInfo: [NSLocalizedDescriptionKey: "\(downloadFailures.count) notebook(s) could not be imported. \(downloadFailures[0])"])
            }
            if !uploadFailures.isEmpty {
                throw NSError(domain: "OpenNotes.Cloud", code: 422, userInfo: [NSLocalizedDescriptionKey: "\(uploadFailures.count) notebook(s) could not be uploaded. \(uploadFailures[0])"])
            }
            if !enabled { phase = .paused; status = "Sync paused · notebooks kept on this device" }
            else if !conflicts.isEmpty || folderConflict != nil {
                phase = .conflict
                status = "\(conflicts.count) conflict(s) · choose revisions in Account and connections"
            } else if saveFailed {
                phase = .failed; status = "Could not save local changes"
            } else if skipped || generation != startGeneration || pendingSaves > 0 || syncRequested {
                phase = .pending; status = "Changes waiting to sync"
                // Busy editors are retried by the regular poll or their next saved edit.
                if !skipped { syncRequested = true }
            } else {
                let now = Date(); state.lastSuccessfulSync = now; try persistState()
                phase = .synced; status = "Synced · \(now.formatted(date: .omitted, time: .shortened))"
                await pruneOldRevisions()
                await backfillMetadata()
            }
        } catch {
            if !enabled { phase = .paused; status = "Sync paused · notebooks kept on this device"; return }
            let failure = error as NSError
            if failure.domain == "Supabase" && (failure.code == 401 || (refreshing && [400, 403].contains(failure.code))) {
                needsSignIn = true; signedIn = false; phase = .needsSignIn; status = "Session expired · sign in again to resume sync"
            } else {
                phase = folderConflict != nil ? .conflict : failure.domain == NSURLErrorDomain ? .offline : .failed
                status = "Waiting to retry: \(Self.failureMessage(error, stage: stage))"
            }
        }
    }
    nonisolated static func failureMessage(_ error: Error, stage: String) -> String {
        let context: DecodingError.Context
        let detail: String
        switch error {
        case DecodingError.keyNotFound(let key, let value): context = value; detail = "Missing field \(key.stringValue)"
        case DecodingError.typeMismatch(_, let value): context = value; detail = "Unexpected field type"
        case DecodingError.valueNotFound(_, let value): context = value; detail = "Missing value"
        case DecodingError.dataCorrupted(let value): context = value; detail = "Invalid encoded data (\(value.debugDescription.prefix(160)))"
        default: return "\(stage): \(error.localizedDescription)"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return "\(stage): \(detail)\(path.isEmpty ? "" : " at " + path). Update OpenNotes on both devices and retry."
    }
    enum NotebookSyncState: Equatable { case synced, pending, failed(String), conflict }
    func notebookState(_ note: NoteDocument) -> NotebookSyncState {
        if conflicts.contains(where: { $0.localID == note.id || $0.remoteCopyID == note.id }) { return .conflict }
        if let message = notebookFailures[note.id] { return .failed(message) }
        return state.links[note.id.uuidString]?.modifiedAt == note.updatedAt ? .synced : .pending
    }
    /// Test-phase wipe: deletes this account's cloud data first (so a failure leaves local notebooks untouched), then local notebooks.
    func cleanReset() async {
        guard stateError == nil, configured, let store, store.ready, let auth = session, state.owner == auth.user.id, !needsSignIn, !running else { return }
        guard !auth.expired else { status = "Session is stale. Tap Sync now once, then retry the reset."; return }
        running = true; defer { running = false }
        let wasEnabled = enabled; enabled = true; defer { enabled = wasEnabled }
        phase = .syncing; status = "Resetting cloud data…"
        do {
            struct Path: Decodable { let object_path: String }
            var paths: [String] = [], offset = 0
            while true {
                let batch = try JSONDecoder().decode([Path].self, from: try await request("rest/v1/notebook_revisions?select=object_path&order=id&limit=500&offset=\(offset)"))
                paths += batch.map(\.object_path)
                if batch.count < 500 { break }
                offset += batch.count
            }
            // Rows first: if the RPC is missing or fails nothing has been destroyed. Orphaned files are only wasted space.
            _ = try await request("rest/v1/rpc/reset_my_notebook_data", method: "POST", body: Data("{}".utf8))
            let orphaned = try await deleteStorageObjects(paths)
            status = "Resetting this device…"
            try await store.resetLocal()
            state = SyncState(); state.owner = auth.user.id; notebookFailures = [:]
            if !orphaned.isEmpty { state.pendingStorageDeletes = orphaned }
            try persistState()
            phase = .synced; status = orphaned.isEmpty ? "Reset complete · this device and your cloud account are empty" : "Reset complete · \(orphaned.count) old cloud file(s) not removed yet; they will be retried (wasted space only)"
        } catch {
            phase = .failed
            let hint = (error as NSError).domain == "Supabase" && (error as NSError).code == 404 ? " Apply migration 20261105000001_clean_reset.sql to Supabase first." : ""
            status = "Reset failed, nothing on this device was deleted: \(Self.failureMessage(error, stage: "Cloud reset"))\(hint)"
        }
    }
    func resolve(_ conflict: SyncConflict, keep: Int) {
        guard let store else { return }
        if keep == 1 { store.update(conflict.remoteCopyID) { $0.deletedAt = Date() } }
        if keep == 2 { store.update(conflict.localID) { $0.deletedAt = Date() } }
        if let revision = conflict.remoteRevision {
            let old = state.links[conflict.localID.uuidString]
            state.links[conflict.localID.uuidString] = CloudLink(modifiedAt: nil, remoteID: old?.remoteID ?? conflict.localID, revision: revision, checksum: "")
        }
        state.links.removeValue(forKey: conflict.remoteCopyID.uuidString)
        state.conflicts?.removeAll { $0.id == conflict.id }
        do { try persistState(); status = "Choice saved · discarded revisions remain in Trash"; syncSoon() }
        catch { status = error.localizedDescription }
        objectWillChange.send()
    }
    func persistState() throws {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            persistedState = state
        } catch {
            state = persistedState
            throw error
        }
    }
    nonisolated static func encode(_ archive: NotebookArchive) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(archive) }
    nonisolated static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", authenticated: Bool = true, prefer: String? = nil) async throws -> Data {
        guard let config, let url = URL(string: path, relativeTo: config.url.absoluteString.hasSuffix("/") ? config.url : config.url.appendingPathComponent("/")) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if authenticated {
            guard enabled else { throw CancellationError() }
            guard let session else { throw URLError(.userAuthenticationRequired) }
            request.setValue("Bearer " + session.access_token, forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await URLSession.shared.data(for: request) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Supabase", code: code, userInfo: [NSLocalizedDescriptionKey: "Supabase HTTP \(code). Retry or sign in again."])
        }
        return data
    }
}

enum Keychain {
    // Retain the service identifier to preserve sessions across the product rename.
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "fr.catnotes.auth", kSecAttrAccount as String: "supabase"]
    static func read() throws -> Data? {
        var query = query; query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }
    static func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = query; query[kSecValueData as String] = data; query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func delete() throws { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) } }
}
