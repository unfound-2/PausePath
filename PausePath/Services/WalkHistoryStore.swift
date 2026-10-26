import Foundation
import Observation

/// Recorded PausePath walks, kept in a protected file instead of UserDefaults.
///
/// Views read `walks` from this one shared model, so the history is decoded once
/// per launch rather than on every render. Writes are encoded and saved off the
/// main actor, newest wins. An in-progress walk is checkpointed separately and
/// recovered on the next launch if the app was closed before the walk ended.
@MainActor @Observable final class WalkHistoryStore {
    static let shared = WalkHistoryStore()

    private(set) var walks: [TrackedWalk] = []
    /// Set when a walk interrupted by a crash or force-quit was recovered at launch.
    private(set) var recoveredWalk: TrackedWalk?

    static let legacyDefaultsKey = "pausepath.trackedWalks"
    private let writer: WalkFileWriter
    private var generation = 0

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PausePath", isDirectory: true)
        writer = WalkFileWriter(folder: folder)
        var loaded = WalkFileWriter.read([TrackedWalk].self, from: writer.historyURL)
        var needsSave = false
        // One-time migration from the old UserDefaults blob.
        if let legacy = defaults.data(forKey: Self.legacyDefaultsKey) {
            if let decoded = try? JSONDecoder().decode([TrackedWalk].self, from: legacy) {
                let known = Set((loaded ?? []).map(\.id))
                loaded = (loaded ?? []) + decoded.filter { !known.contains($0.id) }
                needsSave = true
            }
            if needsSave || legacy.isEmpty { defaults.removeObject(forKey: Self.legacyDefaultsKey) }
        }
        var history = loaded ?? []
        if let checkpoint = WalkFileWriter.read(TrackedWalk.self, from: writer.checkpointURL) {
            if !history.contains(where: { $0.id == checkpoint.id }) {
                history.append(checkpoint)
                recoveredWalk = checkpoint
                needsSave = true
            }
        }
        walks = Self.sorted(history)
        if needsSave {
            // Save synchronously so the legacy key and checkpoint can go safely.
            writer.writeNow(walks, to: writer.historyURL)
        }
        writer.removeNow(writer.checkpointURL)
    }

    /// Inserts or replaces a walk with the same id, then saves.
    func record(_ walk: TrackedWalk) {
        walks.removeAll { $0.id == walk.id }
        walks = Self.sorted(walks + [walk])
        clearCheckpoint()
        save()
    }

    func delete(id: UUID) {
        let before = walks.count
        walks.removeAll { $0.id == id }
        if walks.count != before { save() }
    }

    func acknowledgeRecovery() { recoveredWalk = nil }

    /// Saves the in-progress walk so a crash or force-quit cannot lose it.
    func checkpoint(_ walk: TrackedWalk) {
        generation += 1
        let order = generation
        Task { await writer.write(walk, to: writer.checkpointURL, order: order) }
    }

    func clearCheckpoint() {
        generation += 1
        let order = generation
        Task { await writer.remove(writer.checkpointURL, order: order) }
    }

    private func save() {
        generation += 1
        let order = generation
        let snapshot = walks
        Task { await writer.write(snapshot, to: writer.historyURL, order: order) }
    }

    private static func sorted(_ walks: [TrackedWalk]) -> [TrackedWalk] {
        walks.sorted { $0.date > $1.date }
    }
}

/// Serializes file access. A write that arrives after a newer one for the same
/// file is dropped, so history never rolls back to an older snapshot.
private actor WalkFileWriter {
    let historyURL: URL
    let checkpointURL: URL
    private var latest: [URL: Int] = [:]

    init(folder: URL) {
        historyURL = folder.appendingPathComponent("walk-history-v1.json")
        checkpointURL = folder.appendingPathComponent("active-walk-v1.json")
    }

    func write<T: Encodable & Sendable>(_ value: T, to url: URL, order: Int) {
        guard order > latest[url, default: 0] else { return }
        latest[url] = order
        Self.store(value, to: url)
    }

    func remove(_ url: URL, order: Int) {
        guard order > latest[url, default: 0] else { return }
        latest[url] = order
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated func writeNow<T: Encodable>(_ value: T, to url: URL) { Self.store(value, to: url) }
    nonisolated func removeNow(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func store<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Readable after first unlock so a walk can be checkpointed while the phone is locked.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            #if DEBUG
            print("PausePath walk history save failed: \(error.localizedDescription)")
            #endif
        }
    }
}
