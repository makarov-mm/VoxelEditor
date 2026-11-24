import Foundation
import XCTest
@testable import VoxelStudio

final class RecoveryStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testNewestAvailableDraftIsClaimedExclusivelyAndKeepForLaterIsPreserved() throws {
        func writeDraft(_ byte: UInt8, at seconds: TimeInterval) throws -> URL {
            let store = try RecoveryStore(directory: folder, includeExisting: false)
            try Data([byte]).write(to: store.draftURL)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)],
                                                  ofItemAtPath: store.draftURL.path)
            return store.draftURL
        }
        let first = try writeDraft(1, at: 100), second = try writeDraft(2, at: 200)
        XCTAssertNotEqual(first, second)
        let newest = try RecoveryStore(directory: folder)
        defer { withExtendedLifetime(newest) {} }
        XCTAssertEqual(newest.draftURL, second)
        XCTAssertEqual(newest.savedAt, Date(timeIntervalSince1970: 200))
        let older = try RecoveryStore(directory: folder)
        defer { withExtendedLifetime(older) {} }
        XCTAssertEqual(older.draftURL, first)
        let fresh = try RecoveryStore(directory: folder, includeExisting: false)
        defer { withExtendedLifetime(fresh) {} }
        XCTAssertFalse([first, second].contains(fresh.draftURL))
        XCTAssertNil(fresh.savedAt)
        let other = try RecoveryStore(directory: folder)
        XCTAssertNotEqual(other.draftURL, fresh.draftURL)
        try other.discard()
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testRestoredDraftKeepsHiddenLockedGeometryAndOriginalFile() throws {
        let model = EditorModel()
        model.newProject()
        let original = folder.appendingPathComponent("Lighthouse.vxl")
        try model.saveProject(to: original)
        let originalBytes = try Data(contentsOf: original)
        model.addLayer()
        let id = model.activeLayerID, cell = Cell(3, 1, 8)
        var glass = Ink(hex: "158695")
        glass.surface = VoxSurface(alpha: 93, properties: ["_type": "_glass"])
        model.addPaletteColor(glass)
        model.apply(hit: nil, adjacent: cell)
        model.toggleLayerLock(id)
        model.toggleLayer(id)
        let draft = folder.appendingPathComponent("Draft.vxl")
        try model.snapshot().write(to: draft)

        let reopened = EditorModel()
        try reopened.restoreDraft(from: draft)
        XCTAssertTrue(reopened.isDirty)
        XCTAssertFalse(reopened.canUndo)
        XCTAssertEqual(reopened.title, "Lighthouse")
        XCTAssertEqual(reopened.activeLayerID, id)
        let layer = try XCTUnwrap(reopened.layers.first { $0.id == id })
        XCTAssertTrue(layer.isLocked)
        XCTAssertFalse(layer.isVisible)
        XCTAssertEqual(layer.cells, [cell: glass])
        XCTAssertTrue(reopened.palette.contains(glass))
        try reopened.saveProject(to: folder.appendingPathComponent("Recovered.vxl"))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = Date(timeIntervalSinceNow: 3)
        while !condition() && Date() < limit {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Recovery operation did not finish in time")
    }

    @MainActor
    private func count(in draft: URL) -> Int? {
        let model = EditorModel()
        guard (try? model.restoreDraft(from: draft)) != nil else { return nil }
        return model.voxelCount
    }

    @MainActor
    func testAutosavesDuringContinuousStrokeAndRemovesDraftOnSave() async throws {
        let store = try RecoveryStore(directory: folder)
        let model = EditorModel()
        model.newProject()
        let controller = RecoveryController(model: model, store: store, interval: 0.065) { message in
            if let message { XCTFail(message) }
        }
        defer { controller.stop(discard: true) }
        model.beginStroke()
        var savedDuringStroke = false
        for x in 0..<30 {
            model.apply(hit: nil, adjacent: Cell(x, 0, 0))
            try await Task.sleep(nanoseconds: 8_000_000)
            if store.savedAt != nil { savedDuringStroke = true }
        }
        XCTAssertTrue(savedDuringStroke)
        XCTAssertTrue(model.hasActiveStroke)
        model.endStroke()
        try await waitUntil { self.count(in: store.draftURL) == 30 }
        try model.saveProject(to: folder.appendingPathComponent("Saved.vxl"))
        try await waitUntil { store.savedAt == nil }
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testDiscardCannotBeOvertakenByAnOldWriteAndPreservingShutdownFlushesRecentChanges() async throws {
        let model = EditorModel()
        model.newProject()
        var store: RecoveryStore? = try RecoveryStore(directory: folder)
        var controller: RecoveryController? = RecoveryController(model: model, store: store!, interval: 0.02) { _ in }
        XCTAssertTrue(model.addShape(tool: .box, from: Cell(0, 0, 0), to: Cell(30, 10, 30)))
        try await Task.sleep(nanoseconds: 25_000_000)
        try model.saveProject(to: folder.appendingPathComponent("Scene.vxl"))
        model.undo()
        model.tool = .add
        model.apply(hit: nil, adjacent: Cell(2, 4, 6))
        let draft = store!.draftURL
        controller!.stop(discard: false)
        controller = nil
        store = nil
        XCTAssertEqual(count(in: draft), 1)
        let claimed = try RecoveryStore(directory: folder)
        XCTAssertEqual(claimed.draftURL, draft)
        let cleanController = RecoveryController(model: EditorModel(), store: claimed, interval: 0.02) { _ in }
        XCTAssertNotNil(claimed.savedAt)
        cleanController.stop(discard: true)
        XCTAssertNil(claimed.savedAt)
    }

    @MainActor
    func testFailedSnapshotKeepsLastValidDraftAndCanRecover() async throws {
        let model = EditorModel()
        model.newProject()
        let store = try RecoveryStore(directory: folder)
        var notices = [String?]()
        let controller = RecoveryController(model: model, store: store, interval: 0.025) { notices.append($0) }
        defer { controller.stop(discard: true) }
        model.apply(hit: nil, adjacent: Cell(0, 0, 0))
        try await waitUntil { self.count(in: store.draftURL) == 1 }
        let previous = try Data(contentsOf: store.draftURL)
        model.ink = Ink(.nan, 0, 1)
        model.apply(hit: nil, adjacent: Cell(0, 1, 0))
        try await waitUntil { notices.compactMap { $0 }.count == 1 }
        XCTAssertEqual(try Data(contentsOf: store.draftURL), previous)
        model.tool = .erase
        model.apply(hit: Cell(0, 1, 0), adjacent: nil)
        model.ink = Ink(hex: "005599")
        model.tool = .add
        model.apply(hit: nil, adjacent: Cell(0, 2, 0))
        try await waitUntil { self.count(in: store.draftURL) == 2 && notices.last == .some(nil) }
    }
}
