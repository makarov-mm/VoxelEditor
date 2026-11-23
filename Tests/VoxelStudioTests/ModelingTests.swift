import Foundation
import XCTest
@testable import VoxelStudio

final class ModelingTests: XCTestCase {
    private let red = Ink(hex: "E96555")
    private let blue = Ink(hex: "304455")
    private var glass: Ink {
        var ink = red
        ink.surface = VoxSurface(alpha: 92, properties: ["_type": "_glass"])
        return ink
    }

    private func empty() -> EditorModel {
        let model = EditorModel()
        model.newProject()
        return model
    }

    private func place(_ cell: Cell, _ ink: Ink, in model: EditorModel) {
        model.tool = .add
        model.ink = ink
        model.apply(hit: nil, adjacent: cell)
    }

    func testDuplicateKeepsOriginalMaterialsAndSelectsCopyThroughUndoRedo() {
        let model = empty()
        let a = Cell(2, 4, 6), b = a.offset(1, 0, 0)
        place(a, red, in: model)
        place(b, glass, in: model)
        place(b.offset(1, 0, 0), blue, in: model)
        model.tool = .select
        model.select([a, b])
        let original = model.visibleCells
        XCTAssertTrue(model.duplicateSelection())
        let c = a.offset(-2, 0, 0), d = b.offset(-2, 0, 0)
        XCTAssertEqual(model.selection, [c, d])
        XCTAssertEqual(model.visibleCells[c], red)
        XCTAssertEqual(model.visibleCells[d], glass)
        XCTAssertEqual(model.visibleCells[b], glass)
        model.undo()
        XCTAssertEqual(model.visibleCells, original)
        XCTAssertEqual(model.selection, [a, b])
        model.redo()
        XCTAssertEqual(model.selection, [c, d])
        XCTAssertEqual(model.visibleCells[d], glass)
    }

    func testBlockedDuplicateAndRotationKeepModelAndUndoState() {
        let model = empty(), p = Cell(1, 4, 1)
        place(p, red, in: model)
        for direction in Cell.neighbors { place(p.offset(direction), blue, in: model) }
        model.tool = .select
        model.select([p])
        let original = model.visibleCells, revision = model.revision
        XCTAssertFalse(model.duplicateSelection())
        model.select([p, p.offset(1, 0, 0)])
        XCTAssertFalse(model.rotateSelection(around: .z))
        XCTAssertEqual(model.visibleCells, original)
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.selection, [p, p.offset(1, 0, 0)])
        model.undo()
        XCTAssertEqual(model.voxelCount, original.count - 1)
    }

    func testQuarterTurnsKeepFourTurnIdentityForMixedParityBoundsAndOverlappingCells() {
        let model = empty()
        let a = Cell(-4, 5, -7)
        let initial = [a: red, a.offset(1, 0, 0): blue, a.offset(3, 2, 1): glass]
        for (cell, ink) in initial { place(cell, ink, in: model) }
        model.selectAllOnActiveLayer()
        for axis in VoxelAxis.allCases {
            for _ in 0..<4 { XCTAssertTrue(model.rotateSelection(around: axis)) }
            XCTAssertEqual(model.visibleCells, initial)
            XCTAssertEqual(model.selection, Set(initial.keys))
        }

        let pair = empty()
        place(a, red, in: pair)
        place(a.offset(1, 0, 0), glass, in: pair)
        pair.selectAllOnActiveLayer()
        XCTAssertTrue(pair.rotateSelection(around: .z))
        XCTAssertEqual(pair.visibleCells, [a: red, a.offset(0, 1, 0): glass])
        pair.undo()
        XCTAssertEqual(pair.selection, [a, a.offset(1, 0, 0)])
        pair.redo()
        XCTAssertEqual(pair.selection, [a, a.offset(0, 1, 0)])
    }

    func testShapeGeometryIncludesBothEndsAndTreatsReverseDragsIdentically() throws {
        let a = Cell(-2, 3, -3), b = Cell(3, 5, 0)
        let line = try XCTUnwrap(VoxelShape(tool: .line, from: a, to: b))
        let reverse = try XCTUnwrap(VoxelShape(tool: .line, from: b, to: a))
        XCTAssertEqual(line.lineCells, Array(reverse.lineCells.reversed()))
        XCTAssertEqual(line.lineCells.first, a)
        XCTAssertEqual(line.lineCells.last, b)
        XCTAssertEqual(line.cellCount, 6)
        let model = empty()
        XCTAssertTrue(model.addShape(tool: .line, from: a, to: b))
        XCTAssertEqual(Set(model.visibleCells.keys), Set(line.lineCells))
        XCTAssertNil(VoxelShape(tool: .rectangle, from: a, to: b))
        for (end, count) in [(a.offset(2, 0, 3), 12), (a.offset(0, -2, 3), 12), (a.offset(-3, 1, 0), 8)] {
            let rect = try XCTUnwrap(VoxelShape(tool: .rectangle, from: end, to: a))
            XCTAssertEqual(rect.cellCount, count)
            var actual = Set<Cell>()
            rect.forEachCell { actual.insert($0) }
            XCTAssertEqual(actual.count, count)
            XCTAssertTrue(actual.contains(a))
            XCTAssertTrue(actual.contains(end))
        }
    }

    func testSolidBoxRetainsOccupiedVoxelsAndCommitsOnlyOnce() {
        let model = empty(), a = Cell(-2, 1, -1), b = Cell(0, 2, 2)
        place(a, glass, in: model)
        model.addLayer()
        model.ink = blue
        XCTAssertTrue(model.addShape(tool: .box, from: b, to: a))
        XCTAssertEqual(model.layers[1].cells.count, 23)
        XCTAssertEqual(model.visibleCells[a], glass)
        XCTAssertEqual(model.voxelCount, 24)
        XCTAssertFalse(model.addShape(tool: .box, from: a, to: b))
        XCTAssertFalse(model.addShape(tool: .box, from: Cell(-128, 0, -128), to: Cell(127, 255, 127)))
        model.undo()
        XCTAssertEqual(model.visibleCells, [a: glass])
        model.redo()
        XCTAssertEqual(model.voxelCount, 24)
    }

    func testFillRespectsFaceConnectivityMaterialBoundariesAndOcclusion() {
        let model = empty(), a = Cell(0, 1, 0)
        let b = a.offset(1, 0, 0), c = a.offset(2, 0, 0), behind = a.offset(3, 0, 0)
        let disconnected = a.offset(-1, 1, 0), differentMaterial = a.offset(0, 0, 1)
        for cell in [a, b, c, behind, disconnected] { place(cell, red, in: model) }
        place(differentMaterial, glass, in: model)
        let lower = model.activeLayerID
        model.toggleLayer(lower)
        model.addLayer()
        place(c, red, in: model)
        model.toggleLayer(lower)
        model.activeLayerID = lower
        model.ink = blue
        let original = model.layers[0].cells
        XCTAssertFalse(model.floodFill(at: c))
        XCTAssertTrue(model.floodFill(at: a))
        XCTAssertEqual(model.layers[0].cells, [a: blue, b: blue, c: red, behind: red, disconnected: red, differentMaterial: glass])
        XCTAssertEqual(model.layers[1].cells[c], red)
        XCTAssertFalse(model.floodFill(at: a))
        model.undo()
        XCTAssertEqual(model.layers[0].cells, original)
        model.redo()
        XCTAssertEqual(model.visibleCells[b], blue)
    }

    func testExtrusionCopiesFaceShapeAndMaterialsAndRejectsPartialMoves() {
        let model = empty(), p = Cell(1, 3, -2), up = Cell(0, 1, 0)
        let a = p.offset(1, 0, 0), b = p.offset(0, 0, 1), covered = p.offset(-1, 0, 0)
        for cell in [p, b, covered, covered.offset(up), p.offset(1, 0, 2)] { place(cell, red, in: model) }
        place(a, glass, in: model)
        let face = model.extrusionFace(at: p, normal: up)
        XCTAssertEqual(face, [p, a, b])
        XCTAssertTrue(model.extrusionFace(at: covered, normal: up).isEmpty)
        let original = model.visibleCells
        XCTAssertTrue(model.extrude(face, normal: up, depth: 2))
        for i in 1...2 {
            XCTAssertEqual(model.visibleCells[a.offset(up, by: i)], glass)
            XCTAssertEqual(model.visibleCells[b.offset(up, by: i)], red)
        }
        XCTAssertEqual(model.voxelCount, original.count + 6)
        model.undo()
        XCTAssertEqual(model.visibleCells, original)
        model.addLayer()
        place(a.offset(up, by: 2), blue, in: model)
        model.activeLayerID = model.layers[0].id
        let before = model.visibleCells
        for depth in [2, 256, Int.max, 0, -1] {
            XCTAssertFalse(model.extrude(face, normal: up, depth: depth))
            XCTAssertEqual(model.visibleCells, before)
        }
        XCTAssertTrue(model.canExtrude(face, normal: up, depth: 1))
    }

    func testSliceBoundsBrushFillSelectionTransformsAndGeometry() throws {
        let model = empty(), base = Cell(8, 1, 8), top = base.offset(0, 1, 0)
        place(base, red, in: model)
        place(top, red, in: model)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("vxl")
        defer { try? FileManager.default.removeItem(at: project) }
        try model.saveProject(to: project)
        model.selectAllOnActiveLayer()
        model.sliceLevel = 1
        model.sliceEnabled = true
        XCTAssertEqual(model.selection, [base])
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.viewportCells, [base: red])
        XCTAssertEqual(model.visibleCells.count, 2)
        XCTAssertFalse(model.moveSelection(by: Cell(0, 1, 0)))
        XCTAssertFalse(model.addShape(tool: .box, from: base, to: top))
        XCTAssertFalse(model.extrude([base], normal: Cell(0, 1, 0), depth: 1))
        model.ink = blue
        XCTAssertTrue(model.floodFill(at: base))
        XCTAssertEqual(model.visibleCells[top], red)
        model.undo()
        model.tool = .paint
        model.brushSize = 3
        model.apply(hit: base, adjacent: top)
        XCTAssertEqual(model.visibleCells[top], red)
        model.undo()
        XCTAssertFalse(model.isDirty)
        model.sliceLevel = -999
        XCTAssertEqual(model.sliceLevel, 0)
        XCTAssertTrue(model.viewportCells.isEmpty)
        model.sliceLevel = 999
        XCTAssertEqual(model.sliceLevel, 255)
        XCTAssertEqual(model.viewportCells, model.visibleCells)
        model.sliceLevel = 1
        try model.saveProject(to: project)
        try model.loadProject(from: project)
        XCTAssertFalse(model.sliceEnabled)
        XCTAssertEqual(model.visibleCells, [base: red, top: red])
    }
    func testSliceBlocksTransformDestinationsAndKeepsFullGeometryInVOX() throws {
        let model = empty(), a = Cell(0, 0, 0), b = a.offset(1, 0, 0)
        for cell in [a, b, a.offset(-1, 0, 0), a.offset(0, 0, 1), a.offset(0, 0, -1)] {
            place(cell, red, in: model)
        }
        let roof = a.offset(0, 5, 0)
        place(roof, glass, in: model)
        model.sliceEnabled = true
        model.tool = .select
        model.select([a])
        XCTAssertFalse(model.duplicateSelection())
        model.select([a, b])
        XCTAssertFalse(model.rotateSelection(around: .z))
        XCTAssertEqual(model.selection, [a, b])
        XCTAssertEqual(model.viewportCells.count, 5)

        let vox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("vox")
        defer { try? FileManager.default.removeItem(at: vox) }
        try model.exportVOX(to: vox)
        let scene = try MagicaVoxel.decode(Data(contentsOf: vox))
        XCTAssertEqual(scene.layers[0].cells.count, 6)
        XCTAssertEqual(scene.layers[0].cells[roof]?.surface?.alpha, glass.surface?.alpha)
    }

}
