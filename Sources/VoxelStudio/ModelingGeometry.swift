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
    private let cylinder: VoxelCylinder?

    var fitsOperationLimit: Bool { cellCount <= EditorModel.maxShapeCells }

    init?(tool: EditTool, from first: Cell, to last: Cell, normal: Cell = Cell(0, 1, 0)) {
        guard first.inBounds, last.inBounds else { return nil }
        if tool == .cylinder {
            guard let shape = VoxelShape(cylinderIn: BrushBox(first, last), normal: normal) else { return nil }
            self = shape
            return
        }
        bounds = BrushBox(first, last)
        cylinder = nil
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

    // A preview may extend beyond the grid. The editing initializer checks both endpoints.
    init?(cylinderIn bounds: BrushBox, normal: Cell) {
        guard let cylinder = VoxelCylinder(bounds: bounds, normal: normal) else { return nil }
        self.bounds = bounds
        self.cylinder = cylinder
        lineCells = []
        cellCount = cylinder.rows.reduce(0) { $0 + $1.count } * cylinder.depth
    }

    func forEachCylinderFace(_ visit: (BrushBox, Cell) -> Void) {
        cylinder?.forEachFace(visit)
    }

    func forEachCell(_ visit: (Cell) -> Void) {
        if let cylinder {
            for (row, columns) in cylinder.rows.enumerated() {
                for column in columns {
                    for level in 0..<cylinder.depth {
                        visit(cylinder.cell(column, row, level))
                    }
                }
            }
            return
        }
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

// Store a filled ellipse as one span per row. Depth changes the cell count without
// expanding the preview into individual voxels.
private struct VoxelCylinder {
    let origin: Cell
    let axis: VoxelAxis
    let rows: [Range<Int>]
    let depth: Int

    init?(bounds: BrushBox, normal: Cell) {
        guard Cell.neighbors.contains(normal) else { return nil }
        origin = bounds.min
        let size = bounds.size
        let dimensions = 1...Cell.gridSize
        guard dimensions.contains(size.x), dimensions.contains(size.y), dimensions.contains(size.z) else { return nil }
        let width, height: Int
        if normal.x != 0 {
            axis = .x
            (width, height, depth) = (size.y, size.z, size.x)
        } else if normal.y != 0 {
            axis = .y
            (width, height, depth) = (size.x, size.z, size.y)
        } else {
            axis = .z
            (width, height, depth) = (size.x, size.y, size.z)
        }
        let widthSquared = width * width, heightSquared = height * height
        rows = (0..<height).map { row in
            let dy = 2 * row + 1 - height
            var inset = 0
            while inset < width / 2 {
                let dx = 2 * inset + 1 - width
                // Keep the center axes connected to the ends of even, very narrow ellipses.
                if abs(dx) <= 1 || abs(dy) <= 1 ||
                    dx * dx * heightSquared + dy * dy * widthSquared <= widthSquared * heightSquared { break }
                inset += 1
            }
            return inset..<(width - inset)
        }
    }

    private func oriented(_ column: Int, _ row: Int, _ level: Int) -> Cell {
        switch axis {
        case .x: return Cell(level, column, row)
        case .y: return Cell(column, level, row)
        case .z: return Cell(column, row, level)
        }
    }

    func cell(_ column: Int, _ row: Int, _ level: Int) -> Cell {
        origin.offset(oriented(column, row, level))
    }

    func forEachFace(_ visit: (BrushBox, Cell) -> Void) {
        let top = depth - 1
        for (row, columns) in rows.enumerated() {
            let left = columns.lowerBound, right = columns.upperBound - 1
            visit(BrushBox(cell(left, row, 0), cell(right, row, 0)), oriented(0, 0, -1))
            visit(BrushBox(cell(left, row, top), cell(right, row, top)), oriented(0, 0, 1))
            visit(BrushBox(cell(left, row, 0), cell(left, row, top)), oriented(-1, 0, 0))
            visit(BrushBox(cell(right, row, 0), cell(right, row, top)), oriented(1, 0, 0))
            for step in [-1, 1] {
                let neighbor = row + step
                let normal = oriented(0, step, 0)
                func wall(_ from: Int, _ through: Int) {
                    if from <= through {
                        visit(BrushBox(cell(from, row, 0), cell(through, row, top)), normal)
                    }
                }
                if rows.indices.contains(neighbor) {
                    // Only the portions extending past the neighboring row are exposed.
                    wall(left, rows[neighbor].lowerBound - 1)
                    wall(rows[neighbor].upperBound, right)
                } else {
                    wall(left, right)
                }
            }
        }
    }
}
