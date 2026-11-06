import Foundation
import os

// Signposts for Instruments (os_signpost track "fr.opennotes / perf") and XCTOSSignpostMetric.
// Use `let end = Perf.begin("name"); defer { end() }`; names are StaticString, so they cost nothing when not profiling.
enum Perf {
    static let signposter = OSSignposter(subsystem: "fr.opennotes", category: "perf")
    static func begin(_ name: StaticString) -> () -> Void {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return { signposter.endInterval(name, state) }
    }
    @discardableResult static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let end = begin(name); defer { end() }
        return try body()
    }
}

final class Diagnostics {
    static let shared = Diagnostics(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenNotesDiagnostics"))
    private let queue = DispatchQueue(label: "fr.opennotes.diagnostics", qos: .utility)
    private let root: URL
    private let preferences: UserDefaults
    private let limit: Int
    private var writeFailure: String?
    private let session = UUID().uuidString
    init(root: URL, preferences: UserDefaults = .standard, limit: Int = 512_000) {
        self.root = root; self.preferences = preferences; self.limit = limit
    }
    var enabled: Bool { preferences.object(forKey: "debugLogging") as? Bool ?? true }
    func setEnabled(_ value: Bool) {
        preferences.set(value, forKey: "debugLogging")
        if value { record("diagnostics.enabled") }
    }
    func record(_ event: String, _ fields: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        guard enabled else { return }
        let entry: [String: Any] = ["time": Date().timeIntervalSince1970, "session": session, "event": event, "source": "\(file):\(line)", "fields": fields]
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
                let current = self.root.appendingPathComponent("current.jsonl")
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); data.append(10)
                guard data.count <= self.limit else { return }
                let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > self.limit {
                    let previous = self.root.appendingPathComponent("previous.jsonl")
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: current, to: previous)
                }
                if !FileManager.default.fileExists(atPath: current.path) { try Data().write(to: current, options: .atomic) }
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { self.writeFailure = Self.code(error) }
        }
    }
    func failure(_ event: String, error: Error, file: String = #fileID, line: Int = #line) {
        record(event, ["error": Self.code(error)], file: file, line: line)
    }
    private static func code(_ error: Error) -> String { let error = error as NSError; return "\(error.domain):\(error.code)" }
    func export(metadata: [String: String]) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var events: [Any] = []
                    for name in ["previous.jsonl", "current.jsonl"] {
                        let path = self.root.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: path.path) {
                            let data = try Data(contentsOf: path)
                            for line in data.split(separator: 10) {
                                if let event = try? JSONSerialization.jsonObject(with: Data(line)) { events.append(event) }
                            }
                        }
                    }
                    let report: [String: Any] = ["formatVersion": 1, "metadata": metadata, "events": events, "loggingEnabled": self.enabled, "logWriteError": self.writeFailure ?? "none", "note": "No document contents or titles. Abrupt termination can omit final events; an iOS .ips report is needed for native crash stacks."]
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent("OpenNotes-diagnostic-\(UUID().uuidString).json")
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
                    continuation.resume(returning: output)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func clear() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    for name in ["previous.jsonl", "current.jsonl"] {
                        let url = self.root.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    }
                    self.writeFailure = nil; continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
