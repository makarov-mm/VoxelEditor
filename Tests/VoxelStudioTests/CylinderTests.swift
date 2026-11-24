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

    func testCurvedPreviewContainsExactlyTheExposedFacesOnAllSixNormals() throws {
        let first = Cell(-5, 6, -8), last = first.offset(5, 3, 8)
        for normal in Cell.neighbors {
            let shape = try XCTUnwrap(VoxelShape(tool: .cylinder, from: first, to: last, normal: normal))
            var cells = Set<Cell>()
            shape.forEachCell { cells.insert($0) }
            XCTAssertEqual(shape.cellCount, cells.count)
            let opposite = Cell(-normal.x, -normal.y, -normal.z)
            let reverse = try XCTUnwrap(VoxelShape(tool: .cylinder, from: last, to: first, normal: opposite))
            var reversed = Set<Cell>()
            reverse.forEachCell { reversed.insert($0) }
            XCTAssertEqual(cells, reversed)
            var preview = Set<Face>()
            shape.forEachCylinderFace { patch, direction in
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
