import XCTest
import UIKit
@testable import OpenNotes

@MainActor
final class CloudSyncTests: XCTestCase {
    private func store() async -> LibraryStore {
        let store = LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await store.load()
        return store
    }
    private func cloud(_ store: LibraryStore, owner: UUID, handler: @escaping (URLRequest) throws -> Data) -> CloudSync {
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        let auth = AuthSession(access_token: "test", refresh_token: "test", expires_in: 3600, user: .init(id: owner))
        let cloud = CloudSync(store: store, configuration: config, auth: auth, transport: { request in
            let data: Data
            if request.url!.path == "/rest/v1/cloud_folders", request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                var row = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                row["updated_at"] = "2026-10-31T12:00:00.000Z"
                data = try JSONSerialization.data(withJSONObject: [row])
            } else { data = try handler(request) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        cloud.state = SyncState(); cloud.state.owner = owner; cloud.enabled = true; cloud.minUploadInterval = 0
        return cloud
    }
    func testAccountResponsesAndValidation() async throws {
        let store = await store(), owner = UUID()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        var response = Data("{}".utf8), requests = 0, saved: Data?
        let cloud = CloudSync(store: store, configuration: config, transport: { request in
            requests += 1
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { saved = $0 }, deleteSession: {})
        cloud.email = "  person@example.com  "; cloud.password = "short"
        await cloud.authenticate(signup: true)
        XCTAssertEqual(requests, 0); XCTAssertTrue(cloud.password.isEmpty)
        cloud.password = "password"
        await cloud.authenticate(signup: false)
        XCTAssertTrue(cloud.status.contains("invalid account response")); XCTAssertFalse(cloud.signedIn)
        response = try JSONSerialization.data(withJSONObject: ["id": owner.uuidString])
        cloud.password = "password"; await cloud.authenticate(signup: true)
        XCTAssertTrue(cloud.status.contains("verification")); XCTAssertNil(saved)
        response = try JSONSerialization.data(withJSONObject: ["user": ["id": owner.uuidString]])
        cloud.password = "password"; await cloud.authenticate(signup: true)
        XCTAssertTrue(cloud.status.contains("verification")); XCTAssertNil(saved)
        response = try JSONEncoder().encode(AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner, email: "person@example.com")))
        cloud.password = "password"; await cloud.authenticate(signup: false)
        XCTAssertTrue(cloud.signedIn); XCTAssertEqual(cloud.accountEmail, "person@example.com"); XCTAssertNotNil(saved)
        cloud.state.owner = owner; XCTAssertTrue(cloud.libraryLinked)
        cloud.state.owner = UUID(); XCTAssertTrue(cloud.accountMismatch)
        let created = await store.create(title: "Kept")
        let noteID = try XCTUnwrap(created)
        let linkedOwner = cloud.state.owner
        cloud.pauseSync(); cloud.signOut()
        XCTAssertNil(cloud.accountEmail); XCTAssertEqual(cloud.state.owner, linkedOwner)
        XCTAssertEqual(store.library.note(id: noteID)?.title, "Kept")
    }

    func testUnreadableCloudStateRemainsVisibleAfterSignInAndBlocksLinking() async throws {
        let store = await store(), owner = UUID()
        try Data("invalid".utf8).write(to: store.root.appendingPathComponent("cloud-state.json"))
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        let auth = AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner))
        var calls = 0
        let cloud = CloudSync(store: store, configuration: config, transport: { request in
            calls += 1
            return (try JSONEncoder().encode(auth), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        cloud.email = "person@example.com"; cloud.password = "password"
        await cloud.authenticate(signup: false)
        XCTAssertTrue(cloud.signedIn)
        XCTAssertFalse(cloud.syncStateAvailable)
        XCTAssertTrue(cloud.status.contains("No data will be sent"))
        await cloud.bindAndSync()
        XCTAssertNil(cloud.state.owner)
        XCTAssertEqual(calls, 1)
    }

    func testExpiredSessionStopsRetryAndPausePreservesLink() async throws {
        let store = await store(), owner = UUID()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        var auth = AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner))
        auth.savedAt = .distantPast
        var calls = 0
        let cloud = CloudSync(store: store, configuration: config, auth: auth, transport: { request in
            calls += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        cloud.state.owner = owner; cloud.enabled = true
        await cloud.sync(); await cloud.sync()
        XCTAssertEqual(calls, 1); XCTAssertTrue(cloud.needsSignIn); XCTAssertEqual(cloud.state.owner, owner)
        cloud.localChangesWillSave(); cloud.localChangesDidSave()
        XCTAssertEqual(cloud.phase, .needsSignIn)
        cloud.pauseSync(); XCTAssertFalse(cloud.enabled); XCTAssertEqual(cloud.state.owner, owner)
    }

    func testOfflineRefreshRemainsRetryable() async {
        let store = await store(), owner = UUID()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        var auth = AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner))
        auth.savedAt = .distantPast
        var calls = 0
        let cloud = CloudSync(store: store, configuration: config, auth: auth, transport: { _ in
            calls += 1; throw URLError(.notConnectedToInternet)
        }, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        cloud.state.owner = owner; cloud.enabled = true
        await cloud.sync(); await cloud.sync()
        XCTAssertEqual(calls, 2); XCTAssertFalse(cloud.needsSignIn)
    }

    func testLegacySessionDecodesWithoutEmail() throws {
        let owner = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["access_token": "token", "refresh_token": "refresh", "expires_in": 3600, "user": ["id": owner.uuidString]])
        let auth = try JSONDecoder().decode(AuthSession.self, from: data)
        XCTAssertEqual(auth.user.id, owner); XCTAssertNil(auth.user.email)
    }

    func testRefreshUsesNewBearerAndPreservesIdentity() async throws {
        let store = await store(), owner = UUID()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        var auth = AuthSession(access_token: "old", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner, email: "person@example.com"))
        auth.savedAt = .distantPast
        let renewed = AuthSession(access_token: "new", refresh_token: "next", expires_in: 3600, user: .init(id: owner, email: "person@example.com"))
        var bearer: String?, saved: Data?
        let cloud = CloudSync(store: store, configuration: config, auth: auth, transport: { request in
            if request.url!.path == "/auth/v1/token" {
                return (try JSONEncoder().encode(renewed), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            bearer = request.value(forHTTPHeaderField: "Authorization")
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { saved = $0 }, deleteSession: {})
        cloud.state.owner = owner; cloud.enabled = true
        await cloud.sync()
        XCTAssertEqual(bearer, "Bearer new"); XCTAssertEqual(cloud.accountEmail, "person@example.com")
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: XCTUnwrap(saved)).user.id, owner)
        XCTAssertTrue(cloud.libraryLinked); XCTAssertFalse(cloud.needsSignIn)
    }

    func testUnauthorizedDataRequestStopsRetries() async {
        let store = await store(), owner = UUID()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        let auth = AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner))
        var calls = 0
        let cloud = CloudSync(store: store, configuration: config, auth: auth, transport: { request in
            calls += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        cloud.state.owner = owner; cloud.enabled = true
        await cloud.sync(); await cloud.sync()
        XCTAssertEqual(calls, 1); XCTAssertTrue(cloud.needsSignIn); XCTAssertEqual(cloud.state.owner, owner)
    }

    func testUploadUsesAtomicHeadCommitAndPersistsAcceptedRevision() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Local")
        let id = try XCTUnwrap(created)
        var calls: [String] = []
        var commit: [String: Any]?
        let cloud = cloud(store, owner: owner) { request in
            let path = request.url!.path; calls.append(path)
            if path.contains("commit_notebook_revision") { commit = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any] }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertEqual(commit?["p_notebook_id"] as? String, id.uuidString.lowercased())
        XCTAssertTrue(commit?["p_expected_revision"] is NSNull)
        XCTAssertFalse(calls.contains("/rest/v1/notebook_revisions"))
        let saved = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: store.root.appendingPathComponent("cloud-state.json")))
        XCTAssertNotNil(saved.links[id.uuidString]?.revision)
        let archive = try await store.archive(id)
        XCTAssertEqual(saved.links[id.uuidString]?.checksum, CloudSync.checksum(try CloudSync.encode(archive)))
    }
    func testUnchangedLocalNotebookReceivesRemoteHeadWithoutDuplicate() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Before")
        let id = try XCTUnwrap(created)
        let baseline = try await store.archive(id)
        var remote = baseline; remote.note.title = "From MCP"; remote.note.updatedAt = Date().addingTimeInterval(10)
        let revision = UUID(), oldRevision = UUID(), bytes = try CloudSync.encode(remote)
        let path = "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\(revision.uuidString.lowercased()).catnote"
        let cloud = cloud(store, owner: owner) { request in
            switch request.url!.path {
            case "/rest/v1/notebook_heads":
                return try JSONSerialization.data(withJSONObject: [["notebook_id": id.uuidString, "revision_id": revision.uuidString]])
            case "/rest/v1/notebook_revisions":
                return try JSONEncoder().encode([RemoteRevision(id: revision, owner_id: owner, notebook_id: id, parent_id: oldRevision, checksum: CloudSync.checksum(bytes), object_path: path)])
            case let value where value.hasPrefix("/storage/v1/object/authenticated/"): return bytes
            default: return Data("[]".utf8)
            }
        }
        cloud.state.links[id.uuidString] = CloudLink(modifiedAt: baseline.note.updatedAt, remoteID: id, revision: oldRevision, checksum: CloudSync.checksum(try CloudSync.encode(baseline)))
        await cloud.sync()
        XCTAssertEqual(store.library.note(id: id)?.title, "From MCP")
        XCTAssertEqual(store.library.notes.count, 1)
        XCTAssertTrue(cloud.conflicts.isEmpty)
        XCTAssertEqual(cloud.state.links[id.uuidString]?.revision, revision)
    }
    func testConcurrentEditsKeepBothAndBlockOriginalUploadUntilResolution() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Before")
        let id = try XCTUnwrap(created)
        let baseline = try await store.archive(id)
        store.update(id) { $0.title = "Local edit" }
        var remote = baseline; remote.note.title = "Remote edit"
        let revision = UUID(), oldRevision = UUID(), bytes = try CloudSync.encode(remote)
        let path = "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\(revision.uuidString.lowercased()).catnote"
        var uploads = 0
        let cloud = cloud(store, owner: owner) { request in
            switch request.url!.path {
            case "/rest/v1/notebook_heads": return try JSONSerialization.data(withJSONObject: [["notebook_id": id.uuidString, "revision_id": revision.uuidString]])
            case "/rest/v1/notebook_revisions": return try JSONEncoder().encode([RemoteRevision(id: revision, owner_id: owner, notebook_id: id, parent_id: oldRevision, checksum: CloudSync.checksum(bytes), object_path: path)])
            case let value where value.hasPrefix("/storage/v1/object/authenticated/"): return bytes
            case "/rest/v1/rpc/commit_notebook_revision": uploads += 1; return Data("[]".utf8)
            default: return Data("[]".utf8)
            }
        }
        cloud.state.links[id.uuidString] = CloudLink(modifiedAt: baseline.note.updatedAt, remoteID: id, revision: oldRevision, checksum: CloudSync.checksum(try CloudSync.encode(baseline)))
        await cloud.sync(); await cloud.sync()
        XCTAssertEqual(store.library.note(id: id)?.title, "Local edit")
        XCTAssertEqual(store.library.notes.count, 2)
        XCTAssertEqual(cloud.conflicts.count, 1)
        XCTAssertEqual(uploads, 0)
        cloud.resolve(try XCTUnwrap(cloud.conflicts.first), keep: 1)
        XCTAssertEqual(cloud.state.links[id.uuidString]?.revision, revision)
        XCTAssertTrue(cloud.conflicts.isEmpty)
    }
    func testFolderRemoteRenameAndParentMoveMergeWithoutLosingLocalNotes() async throws {
        let store = await store(), owner = UUID()
        let parent = try XCTUnwrap(store.library.folders.first)
        let child = UUID()
        let rows = [RemoteFolder(owner_id: owner, id: parent.id, name: "Remote parent", parent_id: nil, deleted_at: nil, updated_at: "2026-10-31T12:00:00Z"),
                    RemoteFolder(owner_id: owner, id: child, name: "Exercises", parent_id: parent.id, deleted_at: nil, updated_at: "2026-10-31T12:00:00Z")]
        let cloud = cloud(store, owner: owner) { request in
            request.url!.path == "/rest/v1/cloud_folders" ? try JSONEncoder().encode(Array(rows.reversed())) : Data("[]".utf8)
        }
        cloud.state.folderLinks = [parent.id.uuidString: CloudFolderLink(fingerprint: try RemoteFolder.fingerprint(name: parent.name, parentID: nil, deletedAt: nil), updatedAt: "2026-10-30T12:00:00Z")]
        await cloud.sync()
        XCTAssertEqual(store.library.folder(id: parent.id)?.name, "Remote parent")
        XCTAssertEqual(store.library.parentFolder(of: child)?.id, parent.id)
        XCTAssertEqual(store.library.folders.count, 2)
    }
    func testFolderConflictRetainsBothVersionsUntilExplicitRemoteChoice() async throws {
        let store = await store(), owner = UUID()
        let folder = try XCTUnwrap(store.library.folders.first)
        store.library.folders[0].name = "Local rename"
        let remote = RemoteFolder(owner_id: owner, id: folder.id, name: "Remote rename", parent_id: nil, deleted_at: nil, updated_at: "2026-10-31T12:00:00Z")
        let cloud = cloud(store, owner: owner) { request in
            request.url!.path == "/rest/v1/cloud_folders" ? try JSONEncoder().encode([remote]) : Data("[]".utf8)
        }
        cloud.state.folderLinks = [folder.id.uuidString: CloudFolderLink(fingerprint: try RemoteFolder.fingerprint(name: folder.name, parentID: nil, deletedAt: nil), updatedAt: "2026-10-30T12:00:00Z")]
        await cloud.sync()
        XCTAssertEqual(store.library.folder(id: folder.id)?.name, "Local rename")
        XCTAssertNotNil(cloud.folderConflict)
        await cloud.resolveFolderConflict(keepLocal: false)
        XCTAssertNil(cloud.folderConflict)
        XCTAssertEqual(store.library.folder(id: folder.id)?.name, "Remote rename")
    }

    func testRejectedHeadCommitDoesNotAdvanceBaselineOrLoseLocalChanges() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Must survive")
        let id = try XCTUnwrap(created)
        let cloud = cloud(store, owner: owner) { request in
            if request.url!.path.contains("commit_notebook_revision") { throw NSError(domain: "Supabase", code: 409) }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertNil(cloud.state.links[id.uuidString])
        XCTAssertEqual(store.library.note(id: id)?.title, "Must survive")
        XCTAssertTrue(cloud.status.hasPrefix("Waiting to retry:"))
    }
    func testIndividuallyValidFolderTreesCannotMergeIntoCycle() async throws {
        let store = await store(), owner = UUID()
        let a = try XCTUnwrap(store.library.folders.first)
        let b = NotebookFolder(name: "B", childFolderIDs: [a.id])
        store.library.folders.append(b)
        let rows = [RemoteFolder(owner_id: owner, id: a.id, name: a.name, parent_id: nil, deleted_at: nil, updated_at: "2026-10-31T12:00:00Z"),
                    RemoteFolder(owner_id: owner, id: b.id, name: b.name, parent_id: a.id, deleted_at: nil, updated_at: "2026-10-31T12:00:00Z")]
        let cloud = cloud(store, owner: owner) { request in
            request.url!.path == "/rest/v1/cloud_folders" ? try JSONEncoder().encode(rows) : Data("[]".utf8)
        }
        cloud.state.folderLinks = try Dictionary(uniqueKeysWithValues: [a,b].map { folder in
            (folder.id.uuidString, CloudFolderLink(fingerprint: try RemoteFolder.fingerprint(name: folder.name, parentID: nil, deletedAt: nil), updatedAt: "2026-10-30T12:00:00Z"))
        })
        await cloud.sync()
        XCTAssertFalse(store.library.containsFolderCycle())
        XCTAssertEqual(store.library.parentFolder(of: a.id)?.id, b.id)
        XCTAssertNotNil(cloud.folderConflict)
        await cloud.resolveFolderConflict(keepLocal: false)
        XCTAssertNil(cloud.folderConflict)
        XCTAssertFalse(store.library.containsFolderCycle())
        XCTAssertEqual(store.library.parentFolder(of: b.id)?.id, a.id)
        XCTAssertNil(store.library.parentFolder(of: a.id))
    }

    func testUncommittedStickyTextBlocksRemoteReplacement() async throws {
        let store = await store()
        let created = await store.create(title: "Note")
        let id = try XCTUnwrap(created)
        let editor = EditorSession(store: store, noteID: id)
        await editor.open()
        let note = PageElement(kind: .stickyNote, text: "Original")
        let applied = await editor.apply(.init(pageID: try XCTUnwrap(editor.page?.id), kind: .upsertElement, element: note))
        XCTAssertTrue(applied)
        let flushed = await editor.flush()
        XCTAssertTrue(flushed)
        let remote = try await store.archive(id), expected = store.library.note(id: id)
        var draft = note; draft.text = "Unsaved typing"
        editor.stageStickyEdit(draft)
        XCTAssertTrue(editor.cloudHasUnsavedEdits)
        do { _ = try await store.applyCloudArchive(remote, expected: expected); XCTFail("Draft was overwritten") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.userCancelled.rawValue) }
        XCTAssertEqual(editor.pageIncludingDrafts?.elements?.first?.text, "Unsaved typing")
        _ = await editor.flush()
    }
    func testCloudGuardsFindNestedAndZoomCanvasSurfaces() async throws {
        let store = await store()
        let editor = EditorSession(store: store, noteID: UUID())
        let scroll = PageScrollView(canvas: editor.canvas)
        let wrapper = UIView(); wrapper.addSubview(editor.canvas); scroll.addSubview(wrapper)
        let zoom = InkCanvasView(), zoomScroll = PageScrollView(canvas: InkCanvasView())
        zoomScroll.addSubview(zoom); editor.registerCanvas(zoom)
        XCTAssertTrue(editor.cloudInputViews.contains { $0 === scroll })
        XCTAssertTrue(editor.cloudInputViews.contains { $0 === zoomScroll })
        editor.cloudDocumentEditorPresented = true
        XCTAssertTrue(editor.cloudInteractionActive)
    }

    func testSuccessfulSyncIsPersistedAndFailureDoesNotAdvanceIt() async throws {
        let store = await store(), owner = UUID()
        var offline = false
        let cloud = cloud(store, owner: owner) { _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
        let success = try XCTUnwrap(cloud.lastSuccessfulSync)
        let reopened = CloudSync(store: store, configuration: nil, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        XCTAssertEqual(reopened.lastSuccessfulSync, success)
        offline = true
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .offline)
        XCTAssertEqual(cloud.lastSuccessfulSync, success)
        offline = false
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
    }

    func testNewLocalSaveDuringSyncRemainsPending() async throws {
        let store = await store(), owner = UUID()
        var cloud: CloudSync!
        var changed = false
        cloud = self.cloud(store, owner: owner) { request in
            if request.url!.path == "/rest/v1/notebook_heads", !changed {
                changed = true
                cloud.localChangesWillSave()
                cloud.localChangesDidSave()
            }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .pending)
        XCTAssertNil(cloud.lastSuccessfulSync)
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
        XCTAssertNotNil(cloud.lastSuccessfulSync)
    }

    func testStateWriteFailureRollsBackInMemoryBaseline() async throws {
        let store = await store(), owner = UUID(), id = UUID()
        let cloud = cloud(store, owner: owner) { _ in Data("[]".utf8) }
        try cloud.persistState()
        let url = store.root.appendingPathComponent("cloud-state.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        cloud.state.links[id.uuidString] = CloudLink(remoteID: id, revision: UUID(), checksum: "advanced")
        XCTAssertThrowsError(try cloud.persistState())
        XCTAssertNil(cloud.state.links[id.uuidString])
        XCTAssertEqual(cloud.state.owner, owner)
    }

    func testStoreSaveSchedulesTheLinkedCloud() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Before")
        let id = try XCTUnwrap(created)
        let initialFlush = await store.flush()
        XCTAssertTrue(initialFlush)
        let cloud = self.cloud(store, owner: owner) { _ in Data("[]".utf8) }
        store.cloud = cloud
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
        store.update(id) { $0.title = "After" }
        XCTAssertEqual(cloud.phase, .pending)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
        let archive = try await store.archive(id)
        XCTAssertEqual(cloud.state.links[id.uuidString]?.checksum, CloudSync.checksum(try CloudSync.encode(archive)))
    }

    func testSyncRetriesFailedLocalSave() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Before")
        let id = try XCTUnwrap(created)
        _ = await store.flush()
        let cloud = self.cloud(store, owner: owner) { _ in Data("[]".utf8) }
        store.cloud = cloud
        let journal = store.root.appendingPathComponent("library.pending.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        store.update(id) { $0.title = "Retained" }
        let failed = await store.flush()
        XCTAssertFalse(failed)
        XCTAssertEqual(cloud.phase, .failed)
        try FileManager.default.removeItem(at: journal)
        await cloud.sync()
        await cloud.sync()
        XCTAssertEqual(cloud.phase, .synced)
        XCTAssertEqual(store.library.note(id: id)?.title, "Retained")
        let saved = try JSONDecoder().decode(NoteLibrarySnapshot.self, from: Data(contentsOf: store.root.appendingPathComponent("library.json")))
        XCTAssertEqual(saved.note(id: id)?.title, "Retained")
    }

    func testSavedChangeAutomaticallyStartsSync() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Before")
        let id = try XCTUnwrap(created)
        _ = await store.flush()
        let cloud = self.cloud(store, owner: owner) { _ in Data("[]".utf8) }
        store.cloud = cloud
        await cloud.sync()
        store.update(id) { $0.title = "Automatic" }
        _ = await store.flush()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(cloud.phase, .synced)
        let archive = try await store.archive(id)
        XCTAssertEqual(cloud.state.links[id.uuidString]?.checksum, CloudSync.checksum(try CloudSync.encode(archive)))
    }

    func testSignInResumesLinkedAccountUnlessPausedAndRejectsOtherAccount() async throws {
        let oldEnabled = UserDefaults.standard.object(forKey: "cloud-enabled")
        defer {
            if let oldEnabled { UserDefaults.standard.set(oldEnabled, forKey: "cloud-enabled") }
            else { UserDefaults.standard.removeObject(forKey: "cloud-enabled") }
        }
        let store = await store(), owner = UUID(), other = UUID()
        _ = await store.flush()
        let config = CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test")
        let first = AuthSession(access_token: "token", refresh_token: "refresh", expires_in: 3600, user: .init(id: owner))
        var next = first, dataCalls = 0
        let cloud = CloudSync(store: store, configuration: config, auth: first, transport: { request in
            let data: Data
            if request.url!.path == "/auth/v1/token" { data = try JSONEncoder().encode(next) }
            else if request.url!.path == "/rest/v1/cloud_folders", request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                dataCalls += 1
                var row = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                row["updated_at"] = "2026-10-31T12:00:00.000Z"
                data = try JSONSerialization.data(withJSONObject: [row])
            } else { dataCalls += 1; data = Data("[]".utf8) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, readSession: { nil }, writeSession: { _ in }, deleteSession: {})
        store.cloud = cloud
        cloud.state.owner = owner; cloud.enabled = true
        cloud.signOut()
        cloud.email = "person@example.com"; cloud.password = "password"
        await cloud.authenticate(signup: false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertGreaterThan(dataCalls, 0)
        cloud.pauseSync(); cloud.signOut()
        let before = dataCalls
        cloud.password = "password"; await cloud.authenticate(signup: false)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(dataCalls, before)
        XCTAssertEqual(cloud.phase, .paused)
        cloud.signOut(); cloud.enabled = true
        next = AuthSession(access_token: "other", refresh_token: "refresh", expires_in: 3600, user: .init(id: other))
        cloud.password = "password"; await cloud.authenticate(signup: false)
        await cloud.bindAndSync(); await cloud.sync()
        XCTAssertTrue(cloud.accountMismatch)
        XCTAssertEqual(cloud.phase, .conflict)
        XCTAssertEqual(dataCalls, before)
        XCTAssertEqual(cloud.state.owner, owner)
    }

    func testRemoteNotebookRestoresOnFreshInstallationAndAfterRestart() async throws {
        let source = await store(), destination = await store(), owner = UUID()
        let created = await source.create(title: "Restore me")
        let id = try XCTUnwrap(created)
        let original = try await source.archive(id)
        let bytes = try CloudSync.encode(original), revision = UUID()
        let path = "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\(revision.uuidString.lowercased()).catnote"
        let cloud = self.cloud(destination, owner: owner) { request in
            switch request.url!.path {
            case "/rest/v1/notebook_heads":
                return try JSONSerialization.data(withJSONObject: [["notebook_id": id.uuidString, "revision_id": revision.uuidString]])
            case "/rest/v1/notebook_revisions":
                return try JSONEncoder().encode([RemoteRevision(id: revision, owner_id: owner, notebook_id: id, parent_id: nil, checksum: CloudSync.checksum(bytes), object_path: path)])
            case let value where value.hasPrefix("/storage/v1/object/authenticated/"): return bytes
            default: return Data("[]".utf8)
            }
        }
        destination.cloud = cloud
        await cloud.sync(); await cloud.sync()
        XCTAssertEqual(destination.library.notes.count, 1)
        let restored = try await destination.archive(id)
        XCTAssertEqual(restored.note.title, "Restore me")
        XCTAssertEqual(restored.resources[try XCTUnwrap(restored.pages.first?.drawingResourceID)], original.resources[try XCTUnwrap(original.pages.first?.drawingResourceID)])
        let reopened = LibraryStore(root: destination.root)
        await reopened.load()
        XCTAssertEqual(reopened.library.notes.count, 1)
        let afterRestart = try await reopened.archive(id)
        XCTAssertEqual(afterRestart.note.title, "Restore me")
        XCTAssertEqual(afterRestart.resources[try XCTUnwrap(afterRestart.pages.first?.drawingResourceID)], original.resources[try XCTUnwrap(original.pages.first?.drawingResourceID)])
        let savedState = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: destination.root.appendingPathComponent("cloud-state.json")))
        XCTAssertEqual(savedState.links[id.uuidString]?.revision, revision)
    }

    func testUnreadableRemoteNotebookDoesNotBlockOtherDownloadsOrOverwriteIt() async throws {
        let source = await store(), destination = await store(), owner = UUID()
        let created = await source.create(title: "Readable")
        let goodID = try XCTUnwrap(created), badID = UUID(), goodRevision = UUID(), badRevision = UUID()
        let bytes = try CloudSync.encode(try await source.archive(goodID))
        let invalid = Data("{}".utf8)
        var uploadedIDs: [String] = []
        let cloud = self.cloud(destination, owner: owner) { request in
            switch request.url!.path {
            case "/rest/v1/notebook_heads":
                return try JSONSerialization.data(withJSONObject: [["notebook_id": badID.uuidString, "revision_id": badRevision.uuidString], ["notebook_id": goodID.uuidString, "revision_id": goodRevision.uuidString]])
            case "/rest/v1/notebook_revisions":
                let bad = request.url!.query!.contains(badRevision.uuidString.lowercased())
                let id = bad ? badID : goodID, revision = bad ? badRevision : goodRevision
                let path = "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\(revision.uuidString.lowercased()).catnote"
                return try JSONEncoder().encode([RemoteRevision(id: revision, owner_id: owner, notebook_id: id, parent_id: nil, checksum: CloudSync.checksum(bad ? invalid : bytes), object_path: path)])
            case let path where path.hasPrefix("/storage/v1/object/authenticated/"):
                return path.contains(badID.uuidString.lowercased()) ? invalid : bytes
            case let path where path.hasPrefix("/storage/v1/object/notebooks/"):
                uploadedIDs.append(path); return Data("{}".utf8)
            default: return Data("[]".utf8)
            }
        }
        destination.cloud = cloud
        await cloud.sync()
        XCTAssertEqual(destination.library.note(id: goodID)?.title, "Readable")
        XCTAssertNil(destination.library.note(id: badID))
        XCTAssertNil(cloud.state.links[badID.uuidString])
        XCTAssertFalse(uploadedIDs.contains { $0.contains(badID.uuidString.lowercased()) })
        XCTAssertEqual(cloud.phase, .failed)
        XCTAssertNil(cloud.lastSuccessfulSync)
        XCTAssertTrue(cloud.status.contains("Missing field"))
    }
    func testOneNotebookUploadFailureDoesNotBlockOtherUploads() async throws {
        let store = await store(), owner = UUID()
        let first = await store.create(title: "Too large"), second = await store.create(title: "Fine")
        let badID = try XCTUnwrap(first), goodID = try XCTUnwrap(second)
        var committed: [String] = []
        let cloud = cloud(store, owner: owner) { request in
            let path = request.url!.path
            if path.hasPrefix("/storage/v1/object/notebooks/"), path.contains(badID.uuidString.lowercased()) {
                throw NSError(domain: "Supabase", code: 413)
            }
            if path.contains("commit_notebook_revision") {
                committed.append((try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["p_notebook_id"] as! String)
            }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertEqual(committed, [goodID.uuidString.lowercased()])
        XCTAssertNil(cloud.state.links[badID.uuidString])
        XCTAssertNotNil(cloud.state.links[goodID.uuidString]?.revision)
        XCTAssertEqual(cloud.phase, .failed)
        XCTAssertNil(cloud.lastSuccessfulSync)
    }
    func testNotebookStateAndSenderRejectsUndecodableInk() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Bad ink")
        let id = try XCTUnwrap(created)
        let cloud = cloud(store, owner: owner) { _ in Data("[]".utf8) }
        XCTAssertEqual(cloud.notebookState(try XCTUnwrap(store.library.note(id: id))), .pending)
        // Corrupt the page's ink on disk: the sending device must refuse to publish it.
        let page = try XCTUnwrap(store.library.firstPage(in: id))
        try await store.disk.write(Data("not json".utf8), name: page.drawingResourceID)
        await cloud.sync()
        guard case .failed(let message) = cloud.notebookState(try XCTUnwrap(store.library.note(id: id))) else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Invalid encoded data"), message)
        XCTAssertNil(cloud.state.links[id.uuidString])
    }
    func testCleanResetClearsCloudThenLocalAndKeepsLink() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Doomed")
        let id = try XCTUnwrap(created)
        var calls: [String] = []
        let cloud = cloud(store, owner: owner) { request in
            calls.append(request.httpMethod! + " " + request.url!.path)
            if request.url!.path == "/rest/v1/notebook_revisions" { return Data(#"[{"object_path":"a/b/c.catnote"}]"#.utf8) }
            return Data("[]".utf8)
        }
        store.cloud = cloud
        await cloud.cleanReset()
        XCTAssertEqual(calls, ["GET /rest/v1/notebook_revisions", "POST /rest/v1/rpc/reset_my_notebook_data", "DELETE /storage/v1/object/notebooks"])
        XCTAssertNil(store.library.note(id: id))
        XCTAssertTrue(store.library.notes.isEmpty)
        XCTAssertEqual(cloud.state.owner, owner)
        XCTAssertTrue(cloud.state.links.isEmpty)
        XCTAssertEqual(cloud.phase, .synced)
    }
    func testCleanResetFailureKeepsLocalNotebooks() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Safe")
        let id = try XCTUnwrap(created)
        let cloud = CloudSync(store: store, configuration: CloudConfiguration(url: URL(string: "https://example.invalid")!, publishableKey: "sb_publishable_test"),
            auth: AuthSession(access_token: "t", refresh_token: "t", expires_in: 3600, user: .init(id: owner)), transport: { request in
                let code = request.url!.path.contains("reset_my_notebook_data") ? 404 : 200
                return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            })
        cloud.state = SyncState(); cloud.state.owner = owner; cloud.enabled = true
        store.cloud = cloud
        await cloud.cleanReset()
        XCTAssertNotNil(store.library.note(id: id))
        XCTAssertEqual(cloud.phase, .failed)
        XCTAssertTrue(cloud.status.contains("20261105000001_clean_reset"))
    }
    func testFreshLibrariesShareTheSameHomeFolder() async {
        let first = await store(), second = await store()
        XCTAssertEqual(first.library.folders.first?.id, NotebookFolder.homeID)
        XCTAssertEqual(first.library.folders.first?.id, second.library.folders.first?.id)
    }
    func testRapidEditsAreThrottledButBackgroundFlushUploads() async throws {
        let store = await store(), owner = UUID()
        let created = await store.create(title: "Throttled")
        let id = try XCTUnwrap(created)
        var commits = 0
        let cloud = cloud(store, owner: owner) { request in
            if request.url!.path.contains("commit_notebook_revision") { commits += 1 }
            return Data("[]".utf8)
        }
        cloud.minUploadInterval = 3600
        await cloud.sync()
        XCTAssertEqual(commits, 1)
        store.update(id) { $0.title = "Edited" }
        _ = await store.flush()
        await cloud.sync()
        XCTAssertEqual(commits, 1, "second revision within the interval must wait")
        XCTAssertEqual(cloud.phase, .pending)
        cloud.flushBeforeBackground()
        for _ in 0..<50 where commits < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(commits, 2, "leaving the app uploads immediately")
    }
    func testOldRevisionsArePrunedOncePerDayAfterSuccessfulSync() async throws {
        let store = await store(), owner = UUID()
        _ = await store.create(title: "Pruned")
        var deleted: [String] = [], prunes = 0
        let cloud = cloud(store, owner: owner) { request in
            let path = request.url!.path
            if path.contains("prune_my_revisions") { prunes += 1; return Data(#"[{"removed_path":"a/b/old.catnote"}]"#.utf8) }
            if request.httpMethod == "DELETE" { deleted.append(String(data: request.httpBody!, encoding: .utf8)!) }
            return Data("[]".utf8)
        }
        await cloud.sync()
        XCTAssertEqual(prunes, 1)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertTrue(deleted[0].contains("old.catnote"))
        XCTAssertNotNil(cloud.state.lastPrune)
        await cloud.sync()
        XCTAssertEqual(prunes, 1, "no second prune within a day")
    }
    func testOlderInkStyleDefaultsAndMalformedStyleRejection() throws {
        let style = try JSONDecoder().decode(InkStyle.self, from: Data(#"{"width":4,"pattern":"dashed"}"#.utf8))
        XCTAssertEqual(style.width, 4)
        XCTAssertEqual(style.pattern, .dashed)
        XCTAssertEqual(style.pressureResponse, 0.5)
        XCTAssertEqual(style.inkAlgorithmVersion, 1)
        XCTAssertThrowsError(try JSONDecoder().decode(InkStyle.self, from: Data(#"{"width":"bad"}"#.utf8)))
        let roundtrip = try JSONDecoder().decode(InkStyle.self, from: JSONEncoder().encode(style))
        XCTAssertEqual(style, roundtrip)
    }
    func testDecodingFailureExplainsMissingFieldWithoutDumpingData() {
        let error = DecodingError.keyNotFound(AnyCodingKey("width"), .init(codingPath: [], debugDescription: "private content"))
        let message = CloudSync.failureMessage(error, stage: "Decoding notebook")
        XCTAssertTrue(message.contains("Missing field width"))
        XCTAssertFalse(message.contains("private content"))
    }
    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    func testFolderTrashIncludesDescendantsAndEmptyTrashSurvivesRestart() async throws {
        let store = await store()
        let root = try XCTUnwrap(store.library.folders.first?.id)
        let folder = try store.library.addFolder(name: "Delete", parentID: root)
        let child = try store.library.addFolder(name: "Child", parentID: folder.id)
        let a = await store.create(title: "A", folderID: folder.id)
        let b = await store.create(title: "B", folderID: child.id)
        let kept = await store.create(title: "Keep", folderID: root)
        let aID = try XCTUnwrap(a), bID = try XCTUnwrap(b), keptID = try XCTUnwrap(kept)
        store.trashFolder(folder.id)
        XCTAssertEqual(Set(store.matchingNotes("", trash: true).map(\.id)), [aID, bID])
        XCTAssertNotNil(store.library.folder(id: child.id)?.deletedAt)
        store.restoreNote(aID)
        XCTAssertEqual(store.library.note(id: aID)?.folderID, root)
        store.emptyTrash()
        XCTAssertTrue(store.matchingNotes("", trash: true).isEmpty)
        XCTAssertEqual(Set(store.matchingNotes("").map(\.id)), [aID, keptID])
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let reopened = LibraryStore(root: store.root)
        await reopened.load()
        XCTAssertTrue(reopened.matchingNotes("", trash: true).isEmpty)
        XCTAssertNotNil(reopened.library.note(id: bID)?.purgedAt)
    }

}
