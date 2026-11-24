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

    init?<S: Sequence>(enclosing cells: S) where S.Element == Cell {
        var iterator = cells.makeIterator()
        guard let first = iterator.next() else { return nil }
        self.init(first, first)
        while let cell = iterator.next() {
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
    private let profile: ExtrudedFootprint?

    var fitsOperationLimit: Bool { cellCount <= EditorModel.maxShapeCells }

    init?(tool: EditTool, from first: Cell, to last: Cell, normal: Cell = Cell(0, 1, 0), wallThickness: Int = 0) {
        guard first.inBounds, last.inBounds else { return nil }
        if tool == .cylinder || (tool == .box && wallThickness != 0) {
            guard let shape = VoxelShape(profileFor: tool, in: BrushBox(first, last), normal: normal,
                                         wallThickness: wallThickness) else { return nil }
            self = shape
            return
        }
        bounds = BrushBox(first, last)
        profile = nil
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
    init?(profileFor tool: EditTool, in bounds: BrushBox, normal: Cell, wallThickness: Int) {
        guard let profile = ExtrudedFootprint(tool: tool, bounds: bounds, normal: normal,
                                              wallThickness: wallThickness) else { return nil }
        self.bounds = bounds
        self.profile = profile
        lineCells = []
        cellCount = profile.rows.joined().reduce(0) { $0 + $1.count } * profile.depth
    }

    func forEachProfileFace(_ visit: (BrushBox, Cell) -> Void) {
        profile?.forEachFace(visit)
    }

    func forEachCell(_ visit: (Cell) -> Void) {
        if let profile {
            for (row, spans) in profile.rows.enumerated() {
                for span in spans {
                    for column in span {
                        for level in 0..<profile.depth { visit(profile.cell(column, row, level)) }
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

// A solid row has one span. A row crossing an opening has two. Both geometry and
// preview use the same spans, regardless of extrusion depth.
private struct ExtrudedFootprint {
    let origin: Cell
    let axis: VoxelAxis
    let rows: [[Range<Int>]]
    let depth: Int

    init?(tool: EditTool, bounds: BrushBox, normal: Cell, wallThickness: Int) {
        guard tool == .cylinder || tool == .box, Cell.neighbors.contains(normal),
              (0...(Cell.gridSize / 2)).contains(wallThickness) else { return nil }
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
        let outer = (0..<height).map { row in
            tool == .box ? 0..<width : Self.ellipseSpan(width: width, height: height, row: row)
        }
        guard wallThickness > 0, 2 * wallThickness < min(width, height) else {
            rows = outer.map { [$0] }
            return
        }

        // A cell is inside the opening when a voxel disc of the chosen radius fits
        // around it. A radius-one disc includes the diagonals, keeping stepped walls
        // face-connected. Work in scanlines so thickness never multiplies by depth.
        let diameter = wallThickness * 2 + 1
        let radii = (0..<diameter).map { row in
            wallThickness - Self.ellipseSpan(width: diameter, height: diameter, row: row).lowerBound
        }
        rows = outer.enumerated().map { row, span in
            let first = row - wallThickness
            guard first >= 0, row + wallThickness < height else { return [span] }
            var holeStart = span.lowerBound
            for (offset, radius) in radii.enumerated() {
                holeStart = max(holeStart, outer[first + offset].lowerBound + radius)
            }
            let holeEnd = width - holeStart
            guard holeStart < holeEnd else { return [span] }
            return [span.lowerBound..<holeStart, holeEnd..<span.upperBound]
        }
    }

    private static func ellipseSpan(width: Int, height: Int, row: Int) -> Range<Int> {
        let widthSquared = width * width, heightSquared = height * height
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
        for (row, spans) in rows.enumerated() {
            for span in spans {
                let left = span.lowerBound, right = span.upperBound - 1
                visit(BrushBox(cell(left, row, 0), cell(right, row, 0)), oriented(0, 0, -1))
                visit(BrushBox(cell(left, row, top), cell(right, row, top)), oriented(0, 0, 1))
                visit(BrushBox(cell(left, row, 0), cell(left, row, top)), oriented(-1, 0, 0))
                visit(BrushBox(cell(right, row, 0), cell(right, row, top)), oriented(1, 0, 0))
                for step in [-1, 1] {
                    let neighbor = row + step
                    let blockers = rows.indices.contains(neighbor) ? rows[neighbor] : []
                    let normal = oriented(0, step, 0)
                    var cursor = left
                    for blocker in blockers {
                        let start = max(left, blocker.lowerBound), end = min(span.upperBound, blocker.upperBound)
                        guard start < end else { continue }
                        if cursor < start {
                            visit(BrushBox(cell(cursor, row, 0), cell(start - 1, row, top)), normal)
                        }
                        cursor = end
                    }
                    if cursor <= right {
                        visit(BrushBox(cell(cursor, row, 0), cell(right, row, top)), normal)
                    }
                }
            }
        }
    }
}
