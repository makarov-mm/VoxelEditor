import Foundation
import XCTest
@testable import VoxelStudio

final class SceneObjectWorkflowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    func testThreeShelfLanternsStayEditableAfterNativeAndVOXRoundTrips() throws {
        let library = PartsLibrary(directory: folder.appendingPathComponent("Shelf"))
        let brass = Ink(hex: "AF8159"), warm = Ink(hex: "EA985B"), white = Ink(hex: "FCF3C8")
        var glass = Ink(hex: "72BDCA")
        glass.surface = VoxSurface(alpha: 105, properties: ["_type": "_glass", "_ior": "1.52"])
        let pane = Cell(1, 1, 0)
        let fragment = try XCTUnwrap(VoxelFragment(origin: Cell(0, 0, 0),
            cells: [Cell(0, 0, 0): brass, Cell(0, 1, 0): brass, pane: glass, Cell(0, 2, 0): brass]))
        let part = try library.save(fragment, name: "Lantern")
        let model = EditorModel()
        model.newProject()
        let anchors = [Cell(-8, 1, 1), Cell(6, 2, -5), Cell(17, 1, 12)]
        XCTAssertTrue(model.beginLinkedStamp(try library.fragment(for: part), partID: part.id, name: part.name))
        for anchor in anchors {
            model.updatePasteAnchor(anchor)
            XCTAssertTrue(model.commitPaste())
        }
        model.cancelPaste()
        let originals = model.sceneLayout.objects
        guard originals.count == 3 else { return XCTFail("Expected three placed lanterns.") }
        XCTAssertEqual(Set(originals.map(\.definitionID)).count, 1)
        XCTAssertTrue(originals.allSatisfy { $0.libraryPartID == part.id })
        let tower = try XCTUnwrap(model.createGroup(name: "Tower"))
        let gallery = try XCTUnwrap(model.createGroup(name: "Gallery", parentID: tower))
        for item in originals { XCTAssertTrue(model.setObjectGroup(item.id, to: gallery)) }
        XCTAssertTrue(model.rotateObject(originals[1].id, around: .y, pivot: anchors[1]))
        let points = [anchors[0].offset(1, 1, 0), anchors[1].offset(0, 1, -1), anchors[2].offset(1, 1, 0)]
        func inks(in editor: EditorModel) -> [Ink?] { points.map { editor.visibleCells[$0] } }
        XCTAssertEqual(inks(in: model), [glass, glass, glass])
        XCTAssertTrue(model.makeObjectUnique(originals[2].id))
        let detached = try XCTUnwrap(model.sceneLayout.objects.last)
        XCTAssertNotEqual(detached.definitionID, originals[0].definitionID)
        XCTAssertNil(detached.libraryPartID)
        model.undo()
        XCTAssertEqual(model.sceneLayout.objects.last?.definitionID, originals[0].definitionID)
        model.redo()
        XCTAssertEqual(model.sceneLayout.objects.last?.definitionID, detached.definitionID)

        // Paint the rotated instance, then the independent lantern.
        model.selectObject(originals[1].id)
        model.tool = .paint
        model.ink = warm
        model.apply(hit: points[1], adjacent: nil)
        XCTAssertEqual(inks(in: model), [warm, warm, glass])
        model.selectObject(detached.id)
        model.ink = white
        model.apply(hit: points[2], adjacent: nil)
        XCTAssertEqual(inks(in: model), [warm, warm, white])
        model.undo()
        XCTAssertEqual(inks(in: model), [warm, warm, glass])
        model.undo()
        XCTAssertEqual(inks(in: model), [glass, glass, glass])
        model.redo()
        model.redo()
        XCTAssertEqual(inks(in: model), [warm, warm, white])

        // A material on the linked pair and a separate paint on the third must survive both file formats.
        model.selectObject(originals[0].id)
        model.ink = glass
        model.apply(hit: points[0], adjacent: nil)
        let native = folder.appendingPathComponent("Gallery.vxl")
        try model.saveProject(to: native)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: native)) as? [String: Any])
        XCTAssertEqual((json["definitions"] as? [[String: Any]])?.count, 2)
        try library.remove(part)
        let reopened = EditorModel()
        try reopened.loadProject(from: native)
        assertSameScene(model, reopened)
        let vox = folder.appendingPathComponent("Gallery.vox")
        try reopened.exportVOX(to: vox)
        let imported = EditorModel()
        try imported.importVOX(from: vox)
        assertSameScene(reopened, imported)
        XCTAssertEqual(inks(in: imported), [glass, glass, white])
        imported.selectObject(originals[1].id)
        imported.tool = .paint
        imported.ink = brass
        imported.apply(hit: points[1], adjacent: nil)
        XCTAssertEqual(inks(in: imported), [brass, brass, white])
    }

    @MainActor
    func testLegacyCapeCutterConvertsWithoutMovingCellsAndRecoversWithItsGroup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Media/Cape-Meridian.vxl")
        let bytes = try Data(contentsOf: fixture)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(legacy["version"] as? Int, 1)

        let model = EditorModel()
        try model.loadProject(from: fixture)
        let baseline = model.visibleCells
        XCTAssertTrue(model.sceneLayout.objects.isEmpty)
        let dock = try XCTUnwrap(model.layers.first { $0.name == "Jetty and cutter" })
        model.activeLayerID = dock.id
        model.tool = .select
        // The wooden jetty ends at z=12. The hull, mast and sail occupy z=13...15.
        let boat = dock.cells.filter { (13...15).contains($0.key.z) }
        XCTAssertEqual(boat.count, 79)
        model.select(Set(boat.keys))
        XCTAssertTrue(model.createObjectFromSelection(name: "Cape cutter"))
        let cutter = try XCTUnwrap(model.activeSceneObject)
        XCTAssertEqual(model.visibleCells, baseline)
        XCTAssertEqual(model.layers.first { $0.id == cutter.layerIDs.first }?.cells, boat)
        XCTAssertEqual(model.layers.first { $0.id == dock.id }?.cells.count, dock.cells.count - boat.count)

        let converted = folder.appendingPathComponent("Converted.vxl")
        try model.saveProject(to: converted)
        let copy = EditorModel()
        try copy.loadProject(from: converted)
        assertSameScene(model, copy)
        let harbor = try XCTUnwrap(copy.createGroup(name: "Harbor"))
        XCTAssertTrue(copy.setObjectGroup(cutter.id, to: harbor))
        XCTAssertTrue(copy.moveObject(cutter.id, by: Cell(32, 0, 0)))
        let moved = Dictionary(uniqueKeysWithValues: boat.map { ($0.key.offset(32, 0, 0), $0.value) })
        XCTAssertEqual(copy.layers.first { $0.id == cutter.layerIDs.first }?.cells, moved)
        let store = try RecoveryStore(directory: folder.appendingPathComponent("Recovery"), includeExisting: false)
        let controller = RecoveryController(model: copy, store: store, interval: 60) {
            if let error = $0 { XCTFail(error) }
        }
        controller.stop(discard: false)
        let recovered = EditorModel()
        try recovered.restoreDraft(from: store.draftURL)
        XCTAssertTrue(recovered.isDirty)
        assertSameScene(copy, recovered)
        let untouched = EditorModel()
        try untouched.loadProject(from: converted)
        XCTAssertEqual(untouched.visibleCells, baseline)
        XCTAssertEqual(try Data(contentsOf: fixture), bytes)
    }

    private func assertSameScene(_ lhs: EditorModel, _ rhs: EditorModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.sceneLayout, rhs.sceneLayout, file: file, line: line)
        XCTAssertEqual(lhs.layers.map(\.id), rhs.layers.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.layers.map(\.name), rhs.layers.map(\.name), file: file, line: line)
        XCTAssertEqual(lhs.layers.map(\.isVisible), rhs.layers.map(\.isVisible), file: file, line: line)
        XCTAssertEqual(lhs.layers.map(\.isLocked), rhs.layers.map(\.isLocked), file: file, line: line)
        XCTAssertEqual(lhs.layers.map(\.cells), rhs.layers.map(\.cells), file: file, line: line)
    }
}
