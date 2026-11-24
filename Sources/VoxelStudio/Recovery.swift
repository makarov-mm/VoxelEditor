import Combine
import Darwin
import Foundation

/// Each live editor holds an advisory lock on its own draft slot.
final class RecoveryStore: Sendable {
    let draftURL: URL
    private let lockFD: Int32

    init(directory: URL, includeExisting: Bool = true) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        func url(for slot: Int) -> URL { directory.appendingPathComponent("Draft-\(slot).vxl") }

        if includeExisting {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            let drafts = entries.compactMap { entry -> (URL, Date)? in
                let name = entry.deletingPathExtension().lastPathComponent
                guard entry.pathExtension == "vxl", name.hasPrefix("Draft-"),
                      let slot = Int(name.dropFirst(6)), slot >= 0,
                      entry.lastPathComponent == url(for: slot).lastPathComponent else { return nil }
                // A live writer may remove its draft after directory enumeration.
                guard let values = try? entry.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                return (url(for: slot), values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            for (entry, _) in drafts {
                if let fd = try Self.claim(entry, existing: true) {
                    draftURL = entry
                    lockFD = fd
                    return
                }
            }
        }

        var slot = 0
        while true {
            let entry = url(for: slot)
            if let fd = try Self.claim(entry, existing: false) {
                draftURL = entry
                lockFD = fd
                return
            }
            slot += 1
        }
    }

    private static func claim(_ draft: URL, existing: Bool) throws -> Int32? {
        // Keep the lock inode across atomic draft replacements and ordinary clean exits.
        let lock = draft.deletingPathExtension().appendingPathExtension("lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard FileManager.default.fileExists(atPath: draft.path) == existing else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    deinit { Darwin.close(lockFD) }

    var savedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: draftURL.path))?[.modificationDate] as? Date
    }

    func discard() throws {
        do { try FileManager.default.removeItem(at: draftURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
}

@MainActor
final class RecoveryController {
    private let model: EditorModel
    private let store: RecoveryStore
    private let interval: TimeInterval
    private let reportError: (String?) -> Void
    private let writer = DispatchQueue(label: "studio.forma.recovery", qos: .utility)
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var wasDirty = false
    private var needsWrite = false
    private var writing = false
    private var stopped = false
    private var generation = 0
    private var lastError: String?

    init(model: EditorModel, store: RecoveryStore, interval: TimeInterval = 3,
         reportError: @escaping (String?) -> Void) {
        self.model = model
        self.store = store
        self.interval = interval
        self.reportError = reportError
        observation = model.$isDirty.sink { [weak self] dirty in self?.changed(dirty: dirty) }
    }

    private func changed(dirty: Bool) {
        if dirty {
            wasDirty = true
            needsWrite = true
            schedule()
        } else if wasDirty {
            wasDirty = false
            needsWrite = false
            generation += 1
            timer?.invalidate()
            timer = nil
            discardOnQueue()
        }
    }

    private func schedule() {
        guard timer == nil, !writing, !stopped else { return }
        // A one-shot timer stays scheduled while successive brush events arrive.
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                if self.needsWrite { self.writeLatest() }
                else if !self.wasDirty { self.discardOnQueue() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func writeLatest() {
        needsWrite = false
        writing = true
        let snapshot = model.snapshot(), ticket = generation
        writer.async { [weak self, store] in
            let result = Result { try snapshot.write(to: store.draftURL) }
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.writing = false
                if self.generation == ticket {
                    self.report(result)
                    if case .failure = result { self.needsWrite = true }
                }
                if self.needsWrite { self.schedule() }
            }
        }
    }

    private func discardOnQueue() {
        let ticket = generation
        writer.async { [weak self, store] in
            let result = Result { try store.discard() }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == ticket, !self.wasDirty else { return }
                self.report(result)
                if case .failure = result { self.schedule() }
            }
        }
    }

    private func report(_ result: Result<Void, Error>) {
        let message: String?
        switch result {
        case .success: message = nil
        case .failure(let error): message = error.localizedDescription
        }
        if message != lastError {
            lastError = message
            reportError(message)
        }
    }

    func stop(discard: Bool) {
        guard !stopped else { return }
        stopped = true
        observation?.cancel()
        observation = nil
        timer?.invalidate()
        timer = nil
        let final = !discard && model.isDirty && needsWrite ? model.snapshot() : nil
        let result = writer.sync {
            Result {
                if discard { try store.discard() }
                else if let final { try final.write(to: store.draftURL) }
            }
        }
        report(result)
    }
}
