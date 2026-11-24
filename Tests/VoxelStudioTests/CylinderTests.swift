import XCTest
@testable import VoxelStudio

final class CylinderTests: XCTestCase {
    private struct Face: Hashable {
        let cell: Cell
        let normal: Cell
    }

    func testFiveByFiveDiscAndOneCellFootprints() throws {
        let base = Cell(-7, 4, -2)
        let disc = try XCTUnwrap(VoxelShape(tool: .cylinder, from: base, to: base.offset(4, 0, 4)))
        let widths = [3, 5, 5, 5, 3]
        var cells = Set<Cell>()
        disc.forEachCell { cells.insert($0) }
        for (row, width) in widths.enumerated() {
            let inset = (5 - width) / 2
            for column in 0..<5 {
                XCTAssertEqual(cells.contains(base.offset(column, 0, row)), (inset..<(5 - inset)).contains(column))
            }
        }
        XCTAssertEqual(disc.cellCount, 21)
        for end in [base, base.offset(0, 8, 0), base.offset(0, 0, 8), base.offset(8, 0, 0)] {
            let shape = try XCTUnwrap(VoxelShape(tool: .cylinder, from: end, to: base))
            let size = shape.bounds.size
            XCTAssertEqual(shape.cellCount, size.x * size.y * size.z)
        }
    }

    func testCurvedAndHollowPreviewsContainExactlyTheExposedFacesOnAllSixNormals() throws {
        let first = Cell(-5, 6, -8), last = first.offset(6, 6, 8)
        for normal in Cell.neighbors {
            for (tool, wall): (EditTool, Int) in [(.cylinder, 0), (.cylinder, 1), (.cylinder, 2), (.box, 1), (.box, 2)] {
                let shape = try XCTUnwrap(VoxelShape(tool: tool, from: first, to: last, normal: normal,
                                                     wallThickness: wall))
                var cells = Set<Cell>()
                shape.forEachCell { cells.insert($0) }
                XCTAssertEqual(shape.cellCount, cells.count)
                let opposite = Cell(-normal.x, -normal.y, -normal.z)
                let reverse = try XCTUnwrap(VoxelShape(tool: tool, from: last, to: first, normal: opposite,
                                                       wallThickness: wall))
                var reversed = Set<Cell>()
                reverse.forEachCell { reversed.insert($0) }
                XCTAssertEqual(cells, reversed)
                checkPreview(of: shape, against: cells)
            }
        }
    }

    private func checkPreview(of shape: VoxelShape, against cells: Set<Cell>) {
        var preview = Set<Face>()
        shape.forEachProfileFace { patch, direction in
            for x in patch.min.x...patch.max.x {
                for y in patch.min.y...patch.max.y {
                    for z in patch.min.z...patch.max.z {
                        XCTAssertTrue(preview.insert(Face(cell: Cell(x, y, z), normal: direction)).inserted)
                    }
                }
            }
        }
        var expected = Set<Face>()
        for cell in cells {
            for direction in Cell.neighbors where !cells.contains(cell.offset(direction)) {
                expected.insert(Face(cell: cell, normal: direction))
            }
        }
        XCTAssertEqual(preview, expected)
    }

    func testHollowFootprintsStayOpenAtBothEndsAndFillWhenTheOpeningIsTooSmall() throws {
        let first = Cell(0, 0, 0)
        for tool in [EditTool.cylinder, .box] {
            for wall in [1, 2, 3] {
                let last = Cell(4, 2, 4)
                let shape = try XCTUnwrap(VoxelShape(tool: tool, from: first, to: last, wallThickness: wall))
                var cells = Set<Cell>()
                shape.forEachCell { cells.insert($0) }
                for y in 0...2 {
                    XCTAssertEqual(cells.contains(Cell(2, y, 2)), wall >= 3)
                    XCTAssertEqual(cells.contains(Cell(2, y, 1)), wall >= 2)
                    XCTAssertTrue(cells.contains(Cell(2, y, 0)))
                    XCTAssertEqual(cells.contains(Cell(0, y, 0)), tool == .box)
                }
            }
        }
        let huge = Cell(127, 255, 127), corner = Cell(-128, 0, -128)
        let thin = try XCTUnwrap(VoxelShape(tool: .box, from: corner, to: huge, wallThickness: 1))
        XCTAssertEqual(thin.cellCount, (256 * 256 - 254 * 254) * 256)
        XCTAssertTrue(thin.fitsOperationLimit)
        let thick = try XCTUnwrap(VoxelShape(tool: .box, from: corner, to: huge, wallThickness: 2))
        XCTAssertFalse(thick.fitsOperationLimit)
    }

    func testHollowDrawPreservesExistingVoxelsAndUndoesInOneStep() {
        let model = EditorModel()
        model.newProject()
        let center = Cell(2, 0, 2), rim = Cell(2, 0, 0)
        model.apply(hit: nil, adjacent: center)
        model.apply(hit: nil, adjacent: rim)
        let original = model.visibleCells
        model.hollowShapes = true
        model.ink = Ink(hex: "5D8F95")
        for tool in [EditTool.box, .cylinder] {
            XCTAssertTrue(model.addShape(tool: tool, from: Cell(0, 0, 0), to: Cell(4, 2, 4)))
            XCTAssertEqual(model.visibleCells[center], original[center])
            XCTAssertEqual(model.visibleCells[rim], original[rim])
            XCTAssertNil(model.visibleCells[Cell(2, 2, 2)])
            XCTAssertEqual(model.visibleCells[Cell(2, 2, 0)], model.ink)
            let built = model.visibleCells
            model.undo()
            XCTAssertEqual(model.visibleCells, original)
            model.redo()
            XCTAssertEqual(model.visibleCells, built)
            model.undo()
        }
    }

    func testCylinderRespectsOccupiedCellsSliceAndOperationLimitAndUndoesInOneStep() {
        let model = EditorModel()
        model.newProject()
        let first = Cell(-2, 0, -2), last = Cell(2, 2, 2), center = Cell(0, 0, 0)
        let oldInk = model.ink
        model.apply(hit: nil, adjacent: center)
        model.addLayer()
        model.ink = Ink(hex: "528399")
        model.sliceEnabled = true
        model.sliceLevel = 1
        XCTAssertFalse(model.addShape(tool: .cylinder, from: first, to: last))
        model.sliceEnabled = false
        XCTAssertFalse(model.addShape(tool: .cylinder, from: Cell(-128, 0, -128), to: Cell(127, 255, 127)))
        XCTAssertFalse(model.addShape(tool: .cylinder, from: first, to: Cell(2, -1, 2)))
        XCTAssertFalse(model.addShape(tool: .cylinder, from: first, to: last, normal: Cell(1, 1, 0)))
        XCTAssertTrue(model.addShape(tool: .cylinder, from: first, to: last))
        XCTAssertEqual(model.visibleCells[center], oldInk)
        XCTAssertEqual(model.layers.last?.cells.count, 62)
        XCTAssertNil(model.visibleCells[first])
        let finished = model.visibleCells
        model.undo()
        XCTAssertEqual(model.visibleCells, [center: oldInk])
        model.redo()
        XCTAssertEqual(model.visibleCells, finished)
    }
}
