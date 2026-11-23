import Foundation
import XCTest
@testable import VoxelStudio

final class EditingTests: XCTestCase {
    private let red = Ink(hex: "D04030"), blue = Ink(hex: "376DB5")

    private func emptyProject() -> EditorModel {
        let model = EditorModel()
        model.newProject()
        return model
    }

    private func add(_ cell: Cell, color: Ink, to model: EditorModel) {
        model.tool = .add
        model.ink = color
        model.apply(hit: nil, adjacent: cell)
    }

    func testMirrorBoxesCombineTouchingAndOverlappingRegions() {
        let model = emptyProject()
        model.mirrorX = true
        model.mirrorZ = true
        let center = Cell(5, 0, 7)
        let four = [Cell(-6, 0, -8), Cell(-6, 0, 7), Cell(5, 0, -8), center]
        XCTAssertEqual(model.brushBoxes(hit: nil, adjacent: center), four.map { BrushBox(min: $0, max: $0) })
        XCTAssertEqual(model.brushBoxes(hit: nil, adjacent: Cell(0, 0, 0)),
                       [BrushBox(min: Cell(-1, 0, -1), max: Cell(0, 0, 0))])

        model.brushSize = 4
        XCTAssertEqual(model.brushBoxes(hit: Cell(-3, 10, 0), adjacent: Cell(-2, 10, 0)),
                       [BrushBox(min: Cell(-2, 9, -3), max: Cell(1, 12, 2))])
        model.tool = .pick
        XCTAssertEqual(model.brushBoxes(hit: center, adjacent: nil), [BrushBox(min: center, max: center)])
        model.tool = .select
        XCTAssertTrue(model.brushBoxes(hit: center, adjacent: center).isEmpty)
        model.apply(hit: center, adjacent: center)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.voxelCount, 0)
    }

    func testMirroredBrushFitsGridAndCreatesOneUndoStepPerStroke() {
        let model = emptyProject()
        model.mirrorX = true
        model.mirrorZ = true
        model.brushSize = 3
        model.beginStroke()
        model.apply(hit: nil, adjacent: Cell(127, 255, 127))
        model.apply(hit: nil, adjacent: Cell(127, 255, 127))
        model.apply(hit: nil, adjacent: Cell(127, 254, 127))
        model.endStroke()
        XCTAssertEqual(model.voxelCount, 32)
        XCTAssertTrue(model.visibleCells.keys.allSatisfy(\.inBounds))
        XCTAssertEqual(model.visibleCells[Cell(-128, 254, -128)], model.ink)
        model.undo()
        XCTAssertEqual(model.voxelCount, 0)
        XCTAssertFalse(model.isDirty)
        model.redo()
        XCTAssertEqual(model.voxelCount, 32)
    }

    func testMirroredPaintAndEraseRespectLayerOwnershipAndOcclusion() {
        let model = emptyProject()
        let base = model.activeLayerID, p = Cell(2, 0, 1), mirrored = Cell(-3, 0, 1)
        model.mirrorX = true
        add(p, color: red, to: model)
        model.mirrorX = false
        model.toggleLayer(base)
        model.addLayer()
        add(mirrored, color: red, to: model)
        model.toggleLayer(base)
        model.activeLayerID = base
        model.mirrorX = true
        model.tool = .paint
        model.ink = blue
        model.apply(hit: p, adjacent: nil)
        XCTAssertEqual(model.layers[0].cells, [p: blue, mirrored: red])
        model.tool = .erase
        model.apply(hit: p, adjacent: nil)
        XCTAssertEqual(model.layers[0].cells, [mirrored: red])
        XCTAssertEqual(model.layers[1].cells, [mirrored: red])
        model.undo()
        model.undo()
        XCTAssertEqual(model.layers[0].cells, [p: red, mirrored: red])
    }

    func testOverlappingMoveCarriesMaterialAndRestoresSelectionInHistory() {
        let model = emptyProject()
        let p = Cell(0, 0, 0), q = Cell(1, 0, 0), r = Cell(2, 0, 0)
        var glass = red
        glass.surface = VoxSurface(alpha: 109, properties: ["_type": "_glass"])
        add(p, color: red, to: model)
        add(q, color: glass, to: model)
        model.tool = .select
        model.select([p, q])
        model.mirrorX = true
        let delta = Cell(1, 0, 0)
        XCTAssertTrue(model.canMoveSelection(by: delta))
        XCTAssertTrue(model.moveSelection(by: delta))
        XCTAssertEqual(model.layers[0].cells, [q: red, r: glass])
        XCTAssertEqual(model.selection, [q, r])
        model.clearSelection()
        model.undo()
        XCTAssertEqual(model.layers[0].cells, [p: red, q: glass])
        XCTAssertEqual(model.selection, [p, q])
        model.redo()
        XCTAssertEqual(model.layers[0].cells, [q: red, r: glass])
        XCTAssertEqual(model.selection, [q, r])
        model.tool = .paint
        model.undo()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.layers[0].cells, [p: red, q: glass])
    }

    func testInvalidMovesRejectWholeSelectionAndPreserveHistory() throws {
        let model = emptyProject()
        let p = Cell(124, 0, 0), q = Cell(125, 0, 0), obstruction = Cell(126, 0, 0)
        for c in [p, q, obstruction] { add(c, color: red, to: model) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("vxl")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        model.tool = .select
        model.select([p, q])
        let original = model.layers[0].cells, revision = model.revision
        for delta in [Cell(1, 0, 0), Cell(0, -1, 0), Cell(3, 0, 0), Cell(Int.min, 0, 0), Cell(Int.max, 0, 0), Cell(0, 0, 0)] {
            XCTAssertFalse(model.canMoveSelection(by: delta))
            XCTAssertFalse(model.moveSelection(by: delta))
        }
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.layers[0].cells, original)
        XCTAssertEqual(model.selection, [p, q])
        XCTAssertFalse(model.isDirty)
        model.undo()
        XCTAssertNil(model.layers[0].cells[obstruction])
    }

    func testMoveChecksVisibleLayersAndAllowsHiddenOverlap() {
        let model = emptyProject()
        let bottom = model.activeLayerID
        let p = Cell(0, 0, 0), destination = Cell(0, 1, 0)
        add(destination, color: blue, to: model)
        model.addLayer()
        add(p, color: red, to: model)
        model.selectAllOnActiveLayer()
        let delta = Cell(0, 1, 0)
        XCTAssertFalse(model.moveSelection(by: delta))
        model.toggleLayer(bottom)
        XCTAssertTrue(model.moveSelection(by: delta))
        XCTAssertEqual(model.layers[0].cells[destination], blue)
        XCTAssertEqual(model.layers[1].cells[destination], red)
        model.toggleLayer(bottom)
        XCTAssertEqual(model.visibleCells[destination], red)
    }

    func testSelectionModesOwnershipAndStateChanges() {
        let model = emptyProject()
        let bottom = model.activeLayerID, p = Cell(2, 0, 0), q = Cell(3, 0, 0)
        add(p, color: red, to: model)
        add(q, color: red, to: model)
        model.toggleLayer(bottom)
        model.addLayer()
        let top = model.activeLayerID
        add(q, color: red, to: model)
        model.toggleLayer(bottom)
        model.activeLayerID = bottom
        model.selectAllOnActiveLayer()
        XCTAssertEqual(model.tool, .select)
        XCTAssertEqual(model.selection, [p])
        model.select([q], mode: .add)
        XCTAssertEqual(model.selection, [p])
        model.toggleLayer(top)
        model.select([q], mode: .add)
        XCTAssertEqual(model.selection, [p, q])
        model.select([p], mode: .toggle)
        XCTAssertEqual(model.selection, [q])
        model.toggleLayer(top)
        XCTAssertTrue(model.selection.isEmpty)
        model.select([p])
        model.toggleLayer(bottom)
        XCTAssertTrue(model.selection.isEmpty)
        model.selectAllOnActiveLayer()
        XCTAssertTrue(model.selection.isEmpty)
        model.activeLayerID = top
        model.selectAllOnActiveLayer()
        XCTAssertEqual(model.selection, [q])
        model.removeActiveLayer()
        XCTAssertTrue(model.selection.isEmpty)
        model.undo()
        XCTAssertTrue(model.selection.isEmpty)
        model.select([q])
        model.activeLayerID = bottom
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testTransientControlsDoNotInvalidateGeometryOrPersist() throws {
        let model = emptyProject(), p = Cell(3, 3, 3)
        add(p, color: blue, to: model)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("vxl")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        let revision = model.revision
        model.mirrorX = true
        model.mirrorZ = true
        model.selectAllOnActiveLayer()
        XCTAssertTrue(model.canMoveSelection(by: Cell(1, 0, 0)))
        XCTAssertEqual(model.revision, revision)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.moveSelection(by: Cell(1, 0, 0)))
        model.undo()
        XCTAssertFalse(model.isDirty)
        try model.saveProject(to: url)
        try model.loadProject(from: url)
        XCTAssertEqual(model.visibleCells[p], blue)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertFalse(model.mirrorX)
        XCTAssertFalse(model.mirrorZ)
    }
}
