import Foundation

enum VoxelAxis: String, CaseIterable {
    case x, y, z
}

extension Cell {
    static let neighbors = [Cell(1, 0, 0), Cell(-1, 0, 0), Cell(0, 1, 0),
                            Cell(0, -1, 0), Cell(0, 0, 1), Cell(0, 0, -1)]

    func offset(_ vector: Cell, by distance: Int = 1) -> Cell {
        offset(vector.x * distance, vector.y * distance, vector.z * distance)
    }
}

extension BrushBox {
    init(_ first: Cell, _ second: Cell) {
        min = Cell(Swift.min(first.x, second.x), Swift.min(first.y, second.y), Swift.min(first.z, second.z))
        max = Cell(Swift.max(first.x, second.x), Swift.max(first.y, second.y), Swift.max(first.z, second.z))
    }

    init?(enclosing cells: Set<Cell>) {
        guard let first = cells.first else { return nil }
        self.init(first, first)
        for cell in cells {
            min = Cell(Swift.min(min.x, cell.x), Swift.min(min.y, cell.y), Swift.min(min.z, cell.z))
            max = Cell(Swift.max(max.x, cell.x), Swift.max(max.y, cell.y), Swift.max(max.z, cell.z))
        }
    }

    var size: Cell { Cell(max.x - min.x + 1, max.y - min.y + 1, max.z - min.z + 1) }

    // Keep the grid cell containing the bounds' midpoint fixed. Even and odd side lengths
    // can then trade places without introducing fractional voxels or drift over four turns.
    func rotated(_ cell: Cell, around axis: VoxelAxis) -> Cell {
        let span = size.offset(-1, -1, -1)
        let midpoint = min.offset(span.x / 2, span.y / 2, span.z / 2)
        let x = cell.x - min.x, y = cell.y - min.y, z = cell.z - min.z
        switch axis {
        case .x:
            return midpoint.offset(x - span.x / 2, span.z - z - span.z / 2, y - span.y / 2)
        case .y:
            return midpoint.offset(z - span.z / 2, y - span.y / 2, span.x - x - span.x / 2)
        case .z:
            return midpoint.offset(span.y - y - span.y / 2, x - span.x / 2, z - span.z / 2)
        }
    }
}

struct VoxelShape {
    let bounds: BrushBox
    let lineCells: [Cell]
    let cellCount: Int

    var fitsOperationLimit: Bool { cellCount <= EditorModel.maxShapeCells }

    init?(tool: EditTool, from first: Cell, to last: Cell) {
        guard first.inBounds, last.inBounds else { return nil }
        bounds = BrushBox(first, last)
        let size = bounds.size
        switch tool {
        case .line:
            let steps = max(size.x, size.y, size.z) - 1
            if steps == 0 {
                lineCells = [first]
            } else {
                // Integer numerators keep tie-breaking identical in both drag directions.
                func coordinate(_ start: Int, _ end: Int, _ i: Int) -> Int {
                    let numerator = start * (steps - i) + end * i
                    return Int(floor(Double(numerator) / Double(steps) + 0.5))
                }
                lineCells = (0...steps).map { i in
                    Cell(coordinate(first.x, last.x, i), coordinate(first.y, last.y, i),
                         coordinate(first.z, last.z, i))
                }
            }
            cellCount = lineCells.count
        case .rectangle, .box:
            guard tool == .box || size.x == 1 || size.y == 1 || size.z == 1 else { return nil }
            lineCells = []
            cellCount = size.x * size.y * size.z
        default:
            return nil
        }
    }

    func forEachCell(_ visit: (Cell) -> Void) {
        if !lineCells.isEmpty {
            lineCells.forEach(visit)
            return
        }
        for x in bounds.min.x...bounds.max.x {
            for y in bounds.min.y...bounds.max.y {
                for z in bounds.min.z...bounds.max.z { visit(Cell(x, y, z)) }
            }
        }
    }
}
