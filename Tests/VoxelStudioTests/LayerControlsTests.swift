import AppKit
import ImageIO
import XCTest
@testable import VoxelStudio

final class LayerControlsTests: XCTestCase {
    private let red = Ink(hex: "DD5533"), blue = Ink(hex: "316BAA")
    private let a = Cell(0, 0, 0), b = Cell(0, 2, 0)

    private func place(_ cell: Cell, _ ink: Ink, in model: EditorModel) {
        model.tool = .add
        model.ink = ink
        model.apply(hit: nil, adjacent: cell)
    }

    func testLockFinishesEditingAndProtectsTheLayerUntilUndone() throws {
        let model = EditorModel()
        model.newProject()
        model.addLayer()
        let id = model.activeLayerID
        place(a, red, in: model)
        model.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(model.selectionFragment())
        XCTAssertTrue(model.beginPaste(fragment))
        model.toggleLayerLock(id)
        XCTAssertNil(model.pendingPaste)
        XCTAssertTrue(model.selection.isEmpty)
        let revision = model.revision
        place(b, blue, in: model)
        for tool: EditTool in [.paint, .erase] {
            model.tool = tool
            model.apply(hit: a, adjacent: b)
        }
        XCTAssertFalse(model.addShape(tool: .box, from: b, to: b))
        XCTAssertFalse(model.floodFill(at: a))
        XCTAssertFalse(model.extrude([a], normal: Cell(0, 1, 0), depth: 1))
        XCTAssertFalse(model.beginPaste(fragment))
        model.selectAllOnActiveLayer()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.recolorSelection())
        model.renameLayer(id, to: "Renamed")
        model.removeActiveLayer()
        XCTAssertEqual(model.layers.count, 2)
        XCTAssertEqual(model.layers[1].name, "Layer 2")
        XCTAssertEqual(model.layers[1].cells, [a: red])
        XCTAssertEqual(model.revision, revision)

        model.tool = .pick
        model.apply(hit: a, adjacent: b)
        XCTAssertEqual(model.ink, red)
        model.undo()
        XCTAssertFalse(model.layers[1].isLocked)
        model.redo()
        XCTAssertTrue(model.layers[1].isLocked)
    }

    func testSoloRestoresVisibilityAndEditsTheVisibleOwnerThroughOverlap() throws {
        let model = EditorModel()
        model.newProject()
        let lower = model.activeLayerID
        place(a, red, in: model)
        place(b, red, in: model)
        model.toggleLayer(lower)
        model.addLayer()
        let upper = model.activeLayerID
        place(a, blue, in: model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)

        model.toggleIsolation(lower)
        XCTAssertEqual(model.activeLayerID, lower)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.visibleCells, [a: blue])
        XCTAssertEqual(model.viewportCells, [a: red, b: red])
        model.sliceEnabled = true
        XCTAssertEqual(model.viewportCells, [a: red])
        model.selectAllOnActiveLayer()
        XCTAssertEqual(model.selection, [a])
        model.tool = .pick
        model.apply(hit: a, adjacent: nil)
        XCTAssertEqual(model.ink, red)
        model.tool = .paint
        model.ink = blue
        model.apply(hit: a, adjacent: nil)
        XCTAssertEqual(model.layers[0].cells[a], blue)
        model.undo()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.viewportCells, [a: red])
        model.toggleIsolation(lower)
        XCTAssertEqual(model.layers.map(\.isVisible), [false, true])
        XCTAssertEqual(model.viewportCells, [a: blue])
        model.toggleIsolation(lower)
        model.activeLayerID = upper
        XCTAssertNil(model.isolatedLayerID)
        XCTAssertEqual(model.viewportCells, [a: blue])
    }

    func testNativeLockRoundTripAndExportsKeepWholeSceneDuringSolo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel()
        model.newProject()
        let lower = model.activeLayerID
        place(a, red, in: model)
        model.toggleLayerLock(lower)
        model.addLayer()
        place(b, blue, in: model)
        model.toggleIsolation(lower)

        let file = folder.appendingPathComponent("Solo.vxl")
        try model.saveProject(to: file)
        let restored = EditorModel()
        try restored.loadProject(from: file)
        XCTAssertEqual(restored.layers.map(\.isLocked), [true, false])
        XCTAssertNil(restored.isolatedLayerID)
        XCTAssertEqual(restored.viewportCells, [a: red, b: blue])
        let vox = folder.appendingPathComponent("Solo.vox")
        try model.exportVOX(to: vox)
        let decoded = try MagicaVoxel.decode(Data(contentsOf: vox))
        XCTAssertEqual(decoded.layers.map(\.isVisible), [true, true])
        XCTAssertEqual(decoded.layers.map { $0.cells.count }, [1, 1])
        let obj = folder.appendingPathComponent("Solo.obj")
        try model.exportOBJ(to: obj)
        let mesh = try String(contentsOf: obj)
        XCTAssertTrue(mesh.contains("usemtl cDD5533"))
        XCTAssertTrue(mesh.contains("usemtl c316BAA"))
    }

    @MainActor
    func testPNGReflectsSoloImmediatelyAndRestoresTheFullView() async throws {
        let model = EditorModel()
        model.newProject()
        let id = model.activeLayerID
        place(a, red, in: model)
        model.addLayer()
        place(b, blue, in: model)
        let camera = OrbitCamera()
        let surface = StudioViewportSurface(model: model, camera: camera)
        defer { withExtendedLifetime(surface) {} }
        surface.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        camera.reset()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        func pixels() throws -> Data {
            try camera.exportPNG(to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let original = try pixels()
        model.toggleIsolation(id)
        XCTAssertNotEqual(try pixels(), original)
        model.toggleIsolation(id)
        XCTAssertEqual(try pixels(), original)
    }
}
