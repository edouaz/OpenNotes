import SwiftUI
import UIKit

struct CloudScreen: View {
    @ObservedObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss
    @State private var creatingAccount = false
    @State private var passwordConfirmation = ""
    @State private var confirmSignOut = false
    @State private var copiedEndpoint = false
    @State private var confirmReset = false
    @ObservedObject private var store: LibraryStore

    private let assistantEndpoint = "https://opennotes-mcp-edouazs-projects.vercel.app/mcp"

    init(store: LibraryStore) { self.cloud = store.cloud; self.store = store }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        if cloud.phase == .syncing { ProgressView() }
                        else { Image(systemName: cloud.phase.icon) }
                        Text(cloud.phase.label)
                    }
                    .accessibilityElement(children: .combine)
                    Text(cloud.status).foregroundStyle(.secondary)
                    LabeledContent("Local copies", value: "On this device")
                    LabeledContent("Account backup", value: cloud.libraryLinked ? "Linked" : "Not linked")
                    LabeledContent("Automatic sync", value: cloud.needsSignIn ? "Sign in required" : cloud.configured && cloud.libraryLinked && cloud.enabled ? "On" : "Off")
                    if let date = cloud.lastSuccessfulSync {
                        LabeledContent("Last successful sync") { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    } else {
                        LabeledContent("Last successful sync", value: "Never")
                    }

                    if !cloud.configured {
                        Text("Cloud sync is not configured. Your notebooks remain available on this device.")
                            .foregroundStyle(.secondary)
                    } else if cloud.signedIn && !cloud.needsSignIn {
                        if let email = cloud.accountEmail {
                            LabeledContent("Signed in as", value: email)
                        } else {
                            Text("Signed in")
                        }
                        if !cloud.syncStateAvailable {
                            Text("Sync cannot start because this library’s cloud state could not be opened. Your notebooks remain on this device.")
                                .foregroundStyle(.secondary)
                        } else if cloud.accountMismatch {
                            Text("This library is linked to a different account. Sign in with that account to sync it.")
                                .foregroundStyle(.secondary)
                        } else if !cloud.libraryLinked {
                            Text("Linking uploads and syncs this library with your account.")
                                .foregroundStyle(.secondary)
                            Button("Link and sync this library") { Task { await cloud.bindAndSync() } }
                                .frame(minHeight: 44, alignment: .leading)
                        } else if cloud.enabled {
                            Button(cloud.phase == .failed || cloud.phase == .offline ? "Retry sync" : "Sync now") { Task { await cloud.sync() } }
                                .frame(minHeight: 44, alignment: .leading)
                            Button("Pause sync") { cloud.pauseSync() }
                                .frame(minHeight: 44, alignment: .leading)
                        } else {
                            Text("Sync is paused.").foregroundStyle(.secondary)
                            Button("Resume sync") { Task { await cloud.bindAndSync() } }
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        Button("Sign out", role: .destructive) { confirmSignOut = true }
                            .frame(minHeight: 44, alignment: .leading)
                    } else {
                        if cloud.needsSignIn {
                            Text("Sign in again to continue syncing.").foregroundStyle(.secondary)
                            Button("Sign out on this device", role: .destructive) { confirmSignOut = true }
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        Picker("Account action", selection: $creatingAccount) {
                            Text("Sign in").tag(false)
                            Text("Create account").tag(true)
                        }
                        .pickerStyle(.segmented)
                        TextField("Email", text: $cloud.email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minHeight: 44)
                        SecureField("Password", text: $cloud.password)
                            .textContentType(creatingAccount ? .newPassword : .password)
                            .frame(minHeight: 44)
                        if creatingAccount {
                            SecureField("Confirm password", text: $passwordConfirmation)
                                .textContentType(.newPassword)
                                .frame(minHeight: 44)
                            if !passwordConfirmation.isEmpty && passwordConfirmation != cloud.password {
                                Text("Passwords do not match.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(creatingAccount ? "Create account" : "Sign in") {
                            Task {
                                await cloud.authenticate(signup: creatingAccount)
                                passwordConfirmation = ""
                            }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .disabled(cloud.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloud.password.isEmpty || (creatingAccount && cloud.password != passwordConfirmation))
                    }
                } header: {
                    Text("Account and sync")
                } footer: {
                    Text("Your notebooks stay on this device. When sync is on, changes sync while the app is open.")
                }
                .disabled(cloud.running)

                Section("Save and sync progress") { SyncProgressView(store: store, cloud: cloud) }

                if !cloud.notebookFailures.isEmpty {
                    Section("Notebooks that could not sync") {
                        ForEach(cloud.notebookFailures.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { id, message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.library.note(id: id)?.title ?? "Notebook \(id.uuidString.prefix(8))").font(.headline)
                                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let conflict = cloud.folderConflict {
                    Section("Folder conflict") {
                        Text("‘\(conflict.name)’ changed on this device and in the cloud.")
                        Button("Keep this device’s folder") { Task { await cloud.resolveFolderConflict(keepLocal: true) } }
                        Button("Use the cloud folder") { Task { await cloud.resolveFolderConflict(keepLocal: false) } }
                    }.disabled(cloud.running)
                }
                if !cloud.conflicts.isEmpty {
                    Section("Preserved conflicts") {
                        ForEach(cloud.conflicts) { conflict in
                            VStack(alignment: .leading) {
                                Text("Local revision and remote copy preserved")
                                Button("Keep both") { cloud.resolve(conflict, keep: 0) }
                                Button("Keep local") { cloud.resolve(conflict, keep: 1) }
                                Button("Keep remote") { cloud.resolve(conflict, keep: 2) }
                            }
                        }
                    }.disabled(cloud.running)
                }

                if cloud.signedIn && cloud.libraryLinked && !cloud.needsSignIn {
                    Section {
                        Button("Clean reset (delete everything)", role: .destructive) { confirmReset = true }
                            .frame(minHeight: 44, alignment: .leading)
                    } header: { Text("Testing") } footer: {
                        Text("Deletes every notebook on this device and all of this account’s cloud data. Reset your other devices too, or they will upload their notebooks again.")
                    }.disabled(cloud.running)
                }
                Section {
                    Text("Connect an assistant")
                        .font(.headline)
                    Text("1. Create an account or sign in above, then link and sync this library.")
                    Text("2. Copy the server address and add it to your chatbot as an MCP server.")
                    Button {
                        UIPasteboard.general.string = assistantEndpoint
                        copiedEndpoint = true
                    } label: {
                        Label(copiedEndpoint ? "Copied server address" : "Copy server address", systemImage: copiedEndpoint ? "checkmark" : "doc.on.doc")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    Text(assistantEndpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("3. In the chatbot, sign in with the same account and choose Allow when asked to authorize access.")
                    Link("Open server welcome page", destination: URL(string: "https://opennotes-mcp-edouazs-projects.vercel.app")!)
                        .frame(minHeight: 44, alignment: .leading)
                } header: {
                    Text("Assistants")
                } footer: {
                    Text("Your app account and each chatbot authorization are separate. Signing out here does not revoke a chatbot’s access.")
                }
            }
            .navigationTitle("Account and connections")
            .toolbar { Button("Close") { dismiss() } }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { cloud.signOut() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your notebooks remain on this device. Chatbot access is not revoked.")
            }
            .confirmationDialog("Delete all notebooks everywhere?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { Task { await cloud.cleanReset() } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone. All notebooks on this device and in your cloud account are permanently deleted.")
            }
            .onDisappear { cloud.password = ""; passwordConfirmation = "" }
        }
    }
}

extension CloudSyncPhase {
    var label: String {
        switch self {
        case .local: return "On this device"
        case .paused: return "Sync paused"
        case .pending: return "Sync pending"
        case .syncing: return "Syncing"
        case .synced: return "Synced"
        case .offline: return "Offline"
        case .failed: return "Sync failed"
        case .needsSignIn: return "Sign in required"
        case .conflict: return "Action required"
        }
    }

    var icon: String {
        switch self {
        case .local: return "internaldrive"
        case .paused: return "pause.circle"
        case .pending, .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud"
        case .offline: return "wifi.slash"
        case .failed, .needsSignIn, .conflict: return "exclamationmark.icloud"
        }
    }
}

/// Small per-notebook sync indicator; hidden until the library is linked to an account.
struct NotebookSyncBadge: View {
    @ObservedObject var cloud: CloudSync
    let note: NoteDocument
    var body: some View {
        if cloud.libraryLinked {
            let state = cloud.notebookState(note)
            Image(systemName: state.icon).foregroundStyle(state.color).font(.caption)
                .accessibilityLabel(state.label)
        }
    }
}
extension CloudSync.NotebookSyncState {
    var icon: String {
        switch self {
        case .synced: return "checkmark.icloud"
        case .pending: return "arrow.triangle.2.circlepath.icloud"
        case .failed, .conflict: return "exclamationmark.icloud"
        }
    }
    var color: Color {
        switch self {
        case .synced: return .green
        case .pending: return .secondary
        case .failed, .conflict: return .red
        }
    }
    var label: String {
        switch self {
        case .synced: return "Synced"
        case .pending: return "Waiting to sync"
        case .failed: return "Sync failed"
        case .conflict: return "Sync conflict"
        }
    }
}

/// Save and sync progress, shared by the library toolbar popover and Account and connections.
struct SyncProgressView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var cloud: CloudSync
    var body: some View {
        let progress = cloud.progress
        let pending = cloud.libraryLinked && cloud.enabled ? store.library.notes.filter { cloud.notebookState($0) == .pending } : []
        VStack(alignment: .leading, spacing: 10) {
            Label(store.saving ? "Saving to this device…" : "All changes saved on this device", systemImage: store.saving ? "internaldrive" : "checkmark.circle")
            if progress.step != .idle {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total)) {
                        Text("\(progress.step.rawValue) \(progress.completed + 1) of \(progress.total)")
                    } currentValueLabel: {
                        Text([progress.currentTitle, "\(progress.total - progress.completed) notebook(s) remaining"].compactMap { $0 }.joined(separator: " · "))
                    }
                } else { ProgressView { Text(progress.step.rawValue) } }
            } else if cloud.libraryLinked && cloud.enabled {
                Label(pending.isEmpty ? "Nothing waiting to upload" : "\(pending.count) notebook(s) waiting to upload", systemImage: pending.isEmpty ? "checkmark.icloud" : "icloud.and.arrow.up")
                ForEach(Array(pending.prefix(5))) { Text($0.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if pending.count > 5 { Text("and \(pending.count - 5) more").font(.caption).foregroundStyle(.secondary) }
            } else { Label("Cloud sync off · notebooks stay on this device", systemImage: "icloud.slash") }
        }
    }
}
