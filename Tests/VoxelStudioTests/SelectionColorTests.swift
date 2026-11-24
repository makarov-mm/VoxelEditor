import Foundation
import XCTest
@testable import VoxelStudio

final class SelectionColorTests: XCTestCase {
    private let red = Ink(hex: "D05147")
    private let blue = Ink(hex: "3282AC")
    private let glass = VoxSurface(alpha: 91, properties: ["_type": "_glass", "_ior": "1.46"])
    private let metal = VoxSurface(alpha: 255, properties: ["_type": "_metal", "_rough": "0.21"])

    private func withSurface(_ ink: Ink, _ surface: VoxSurface) -> Ink {
        var result = ink
        result.surface = surface
        return result
    }

    private func place(_ cells: [Cell: Ink], in model: EditorModel) {
        model.tool = .add
        for (cell, ink) in cells {
            model.ink = ink
            model.apply(hit: nil, adjacent: cell)
        }
    }

    private func temporaryProject() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
    }

    func testSelectByColorFindsEditableMatchesByDisplayedRGB() throws {
        let model = EditorModel()
        model.newProject()
        let lower = model.activeLayerID
        let near = Cell(0, 0, 0), far = Cell(-12, 2, 20), covered = Cell(1, 0, 0)
        let aboveCut = Cell(0, 3, 0), unrelated = Cell(2, 0, 0), upperOnly = Cell(3, 0, 0)
        var roundedRed = withSurface(red, glass)
        roundedRed.g += 0.0004
        XCTAssertEqual(roundedRed.hex, red.hex)
        place([near: red, far: roundedRed, covered: red, aboveCut: red, unrelated: blue], in: model)

        model.toggleLayer(lower)
        model.addLayer()
        let upper = model.activeLayerID
        place([covered: red, upperOnly: red], in: model)
        model.toggleLayer(lower)
        model.activeLayerID = lower
        model.sliceLevel = 2
        model.sliceEnabled = true
        model.ink = withSurface(red, metal)
        let url = temporaryProject()
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)

        XCTAssertTrue(model.selectByColor())
        XCTAssertEqual(model.tool, .select)
        XCTAssertEqual(model.selection, [near, far])
        XCTAssertFalse(model.isDirty)
        model.ink = blue
        XCTAssertTrue(model.selectByColor())
        XCTAssertEqual(model.selection, [unrelated])
        model.ink = Ink(hex: "012345")
        XCTAssertFalse(model.selectByColor())
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.isDirty)

        model.toggleLayer(upper)
        model.ink = red
        XCTAssertTrue(model.selectByColor())
        XCTAssertEqual(model.selection, [near, far, covered])
        model.sliceEnabled = false
        XCTAssertTrue(model.selectByColor())
        XCTAssertEqual(model.selection, [near, far, covered, aboveCut])
    }

    func testRecolorKeepsIndividualMaterialsAndSkipsEquivalentRGBThroughUndoAndSave() throws {
        let model = EditorModel()
        model.newProject()
        let pane = Cell(0, 0, 0), wall = Cell(1, 0, 0), trim = Cell(2, 0, 0), untouched = Cell(3, 0, 0)
        var nearBlue = withSurface(blue, glass)
        nearBlue.b -= 0.0004
        XCTAssertEqual(nearBlue.hex, blue.hex)
        let original = [pane: withSurface(red, glass), wall: red, trim: nearBlue, untouched: red]
        place(original, in: model)
        model.tool = .select
        let selected: Set<Cell> = [pane, wall, trim]
        model.select(selected)
        model.ink = withSurface(blue, metal)

        XCTAssertTrue(model.recolorSelection())
        let painted = [pane: withSurface(blue, glass), wall: blue, trim: nearBlue, untouched: red]
        XCTAssertEqual(model.visibleCells, painted)
        XCTAssertEqual(model.selection, selected)
        model.undo()
        XCTAssertEqual(model.visibleCells, original)
        XCTAssertEqual(model.selection, selected)
        model.redo()
        XCTAssertEqual(model.visibleCells, painted)
        XCTAssertEqual(model.selection, selected)

        let url = temporaryProject()
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        let reopened = EditorModel()
        try reopened.loadProject(from: url)
        XCTAssertEqual(reopened.visibleCells, painted)
    }

    func testRecolorNoOpLeavesSavedDocumentAndRedoIntact() throws {
        let model = EditorModel()
        model.newProject()
        let cell = Cell(4, 1, 2)
        place([cell: withSurface(red, glass)], in: model)
        let url = temporaryProject()
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        model.selectAllOnActiveLayer()
        model.ink = blue
        XCTAssertTrue(model.recolorSelection())
        model.undo()
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.canRedo)
        let revision = model.revision
        var equivalent = withSurface(red, metal)
        equivalent.r -= 0.0005
        model.ink = equivalent
        XCTAssertTrue(model.selectByColor())
        XCTAssertFalse(model.recolorSelection())
        XCTAssertEqual(model.revision, revision)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.visibleCells[cell], withSurface(blue, glass))
        XCTAssertEqual(model.selection, [cell])
    }

    func testColorActionsRespectPastePreviewAndHiddenLayer() throws {
        let model = EditorModel()
        model.newProject()
        let cell = Cell(2, 0, 2), destination = Cell(3, 0, 3)
        place([cell: red], in: model)
        model.ink = blue
        model.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(model.selectionFragment())
        XCTAssertTrue(model.beginPaste(fragment))
        model.updatePasteAnchor(destination)
        XCTAssertFalse(model.selectByColor())
        XCTAssertFalse(model.recolorSelection())
        XCTAssertTrue(model.pendingPaste === fragment)
        XCTAssertTrue(model.pasteAllowed)
        XCTAssertEqual(model.pasteAnchor, destination)
        XCTAssertEqual(model.selection, [cell])
        XCTAssertEqual(model.visibleCells, [cell: red])

        model.cancelPaste()
        model.toggleLayer(model.activeLayerID)
        model.tool = .paint
        model.ink = red
        XCTAssertFalse(model.selectByColor())
        XCTAssertEqual(model.tool, .paint)
        XCTAssertFalse(model.recolorSelection())
        XCTAssertEqual(model.layers.first?.cells, [cell: red])
    }
}
