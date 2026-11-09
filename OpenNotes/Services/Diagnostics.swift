import QuartzCore
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

/// Frames longer than 1.5× the display interval while one gesture runs, logged as one event when it ends.
/// Main thread only; one gesture at a time (a new `begin` closes the previous one).
final class FrameMonitor {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var name = ""
    private var started: CFTimeInterval = 0, last: CFTimeInterval = 0, worst: CFTimeInterval = 0
    private var frames = 0, hitches = 0
    func begin(_ name: String) {
        end()
        guard Diagnostics.shared.enabled, AppPreferences.measureFrames else { return }   // a display link per gesture costs battery; only for diagnostics
        self.name = name; started = CACurrentMediaTime(); last = 0; worst = 0; frames = 0; hitches = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func end(_ fields: [String: String] = [:]) {
        guard let link else { return }
        link.invalidate(); self.link = nil
        var report = fields
        report["ms"] = String(Int((CACurrentMediaTime() - started) * 1000))
        report["frames"] = String(frames); report["hitches"] = String(hitches)
        report["worstFrameMs"] = String(Int(worst * 1000))
        Diagnostics.shared.record("frames.\(name)", report)
    }
    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let gap = link.timestamp - last
            frames += 1; worst = max(worst, gap)
            if gap > (link.targetTimestamp - link.timestamp) * 1.5 { hitches += 1 }
        }
        last = link.timestamp
    }
}
func elapsedMilliseconds(since start: CFTimeInterval) -> String { String(Int((CACurrentMediaTime() - start) * 1000)) }

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
