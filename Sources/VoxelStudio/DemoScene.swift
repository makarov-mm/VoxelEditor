import Foundation

/// The starter project is built from ordinary editable voxels.
enum DemoScene {
    private typealias Cells = [Cell: Ink]

    private enum Paint {
        static let red = Ink(hex: "#E96555")
        static let terracotta = Ink(hex: "#BF5045")
        static let ivory = Ink(hex: "#F4E6CA")
        static let iron = Ink(hex: "#314552")
        static let slate = Ink(hex: "#697B82")
        static let limestone = Ink(hex: "#CCBDA1")
        static let warmStone = Ink(hex: "#AD9F8B")
        static let ochre = Ink(hex: "#D8BB84")
        static let wood = Ink(hex: "#926D50")
        static let meadow = Ink(hex: "#A4AE76")
        static let lichen = Ink(hex: "#C1C797")
        static let leaf = Ink(hex: "#6E916F")
        static let fir = Ink(hex: "#4F7467")
        static let tile = Ink(hex: "#538F8D")
        static let deepSea = Ink(hex: "#68A8AB")
        static let water = Ink(hex: "#82BCBA")
        static let surf = Ink(hex: "#D4EBDA")
        static let gold = Ink(hex: "#F5BD62")
        static let light = Ink(hex: "#FFE4A2")
    }

    static func layers() -> [VoxelLayer] {
        [
            layer("Sea", sea()),
            layer("Island", island()),
            layer("Vegetation", plants()),
            layer("Keeper’s Cottage", cottage()),
            layer("Lighthouse", lighthouse())
        ]
    }

    private static func layer(_ name: String, _ cells: Cells) -> VoxelLayer {
        VoxelLayer(id: UUID(), name: name, isVisible: true, cells: cells)
    }

    private static func fill(_ cells: inout Cells, _ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>,
                             _ zs: ClosedRange<Int>, _ color: Ink) {
        for x in xs {
            for z in zs {
                for y in ys {
                    cells[Cell(x, y, z)] = color
                }
            }
        }
    }

    private static func sea() -> Cells {
        var cells = Cells()
        // A shallow tile with clipped corners gives the diorama a clean footprint.
        for x in -14...14 {
            for z in -11...11 where abs(x) + abs(z) <= 21 {
                cells[Cell(x, 0, z)] = Paint.water
            }
        }
        // Low shelves break the water around the shore, with isolated ripples.
        let shoals = [(-11, 0, 3), (-9, 5, 3), (-5, 8, 4), (1, 8, 3),
                      (8, 6, 2), (10, -4, 2), (-10, -6, 2), (1, -9, 3)]
        for (x, z, length) in shoals {
            for offset in 0..<length {
                cells[Cell(x + offset, 0, z)] = Paint.surf
            }
        }
        for (x, z, length) in [(-11, 7, 2), (4, 10, 3), (11, 4, 2), (7, -9, 2)] {
            for dx in 0..<length {
                cells[Cell(x + dx, 0, z)] = Paint.deepSea
            }
        }
        return cells
    }

    private static func shoreHeight(_ x: Int, _ z: Int) -> Int {
        let u = (Double(x) + 0.4) / 11.1
        let v = (Double(z) + 0.2) / 8.2
        let angle = atan2(v, u)
        let radius = hypot(u, v) + 0.060 * cos(3 * angle + 0.8) + 0.035 * sin(5 * angle)
        if radius > 1.0 { return 0 }
        if radius > 0.94 { return 2 }
        if radius > 0.85 { return 3 }
        if radius > 0.75 { return 4 }
        return 5
    }

    private static func island() -> Cells {
        var cells = Cells()
        for x in -12...12 {
            for z in -10...10 {
                let top = shoreHeight(x, z)
                guard top > 0 else { continue }
                for y in 1...top {
                    let shade: Ink
                    if y == top {
                        shade = top >= 4 ? Paint.meadow : (top == 3 ? Paint.limestone : Paint.warmStone)
                    } else if y == 1 {
                        shade = Paint.slate
                    } else {
                        shade = ((x >= 5 && z > 1) || (x < -6 && z < 0)) ? Paint.warmStone : Paint.limestone
                    }
                    cells[Cell(x, y, z)] = shade
                }
            }
        }
        // A hand-laid footpath links both doors and descends to the landing.
        let paths = [
            (-5, 6), (-4, 6), (-3, 6), (-2, 6), (-2, 5), (-1, 5), (0, 5),
            (0, 4), (1, 4), (2, 4), (2, 3), (3, 3), (4, 3), (5, 3),
            (5, 4), (6, 4), (7, 4), (8, 4), (8, 3), (9, 3), (10, 3)
        ]
        for (x, z) in paths {
            let y = shoreHeight(x, z)
            if y > 0 { cells[Cell(x, y, z)] = Paint.ochre }
        }
        // The landing has paired piles and a staggered plank end.
        for x in 10...13 {
            for z in 2...4 {
                cells[Cell(x, 2, z)] = Paint.wood
            }
        }
        for x in [10, 13] {
            for z in [2, 4] {
                cells[Cell(x, 1, z)] = Paint.wood
                cells[Cell(x, 3, z)] = Paint.ochre
            }
        }
        // Low sea stacks, just offshore.
        fill(&cells, -11 ... -10, 1...1, 2...3, Paint.slate)
        cells[Cell(-10, 2, 2)] = Paint.warmStone
        fill(&cells, 2...4, 1...1, 8...8, Paint.slate)
        cells[Cell(3, 2, 8)] = Paint.warmStone
        return cells
    }

    private static func plants() -> Cells {
        var cells = Cells()
        func spruce(_ x: Int, _ z: Int, _ height: Int) {
            let base = shoreHeight(x, z)
            for dy in 1...height {
                cells[Cell(x, base + dy, z)] = Paint.wood
            }
            for dy in 2...height {
                let fromTip = height - dy
                // Two tapering whorls leave a notch between the boughs.
                let radius: Int
                switch fromTip {
                case 0: radius = 0
                case 1...4: radius = 1
                default: radius = 2
                }
                let cornerFill = fromTip == 2 || fromTip == 5 ? 1 : 0
                for dx in -radius...radius {
                    for dz in -radius...radius where abs(dx) + abs(dz) <= radius + cornerFill {
                        let shaded = fromTip >= 4
                        cells[Cell(x + dx, base + dy, z + dz)] = shaded ? Paint.fir : Paint.leaf
                    }
                }
            }
        }
        spruce(-9, 4, 8)
        spruce(8, -4, 6)
        for (x, z) in [(8, -3), (8, -2), (7, -3), (-8, 4), (-7, 5), (0, 6), (1, 6)] {
            let base = shoreHeight(x, z)
            if base >= 3 { cells[Cell(x, base + 1, z)] = Paint.leaf }
        }
        for (x, z) in [(-8, 0), (-7, 0), (-2, -5), (-1, -5), (6, 3), (6, 2)] {
            let base = shoreHeight(x, z)
            cells[Cell(x, base, z)] = Paint.lichen
        }
        return cells
    }

    private static func cottage() -> Cells {
        var cells = Cells()
        fill(&cells, -7 ... -2, 4...5, 0...5, Paint.warmStone)
        fill(&cells, -7 ... -2, 6...8, 0...5, Paint.ivory)
        // Doors and shutters are inset into the two visible elevations.
        fill(&cells, -6 ... -6, 6...7, 5...5, Paint.wood)
        cells[Cell(-3, 7, 5)] = Paint.iron
        cells[Cell(-2, 7, 1)] = Paint.tile
        cells[Cell(-2, 7, 2)] = Paint.iron
        cells[Cell(-2, 7, 3)] = Paint.tile
        for x in -8 ... -1 {
            let rise = min(x + 8, -1 - x)
            if rise > 0 {
                fill(&cells, x...x, 9...(8 + rise), 0...5, Paint.ivory)
            }
            fill(&cells, x...x, (9 + rise)...(9 + rise), -1...6, Paint.tile)
        }
        fill(&cells, -4 ... -4, 11...13, 1...1, Paint.terracotta)
        cells[Cell(-4, 14, 1)] = Paint.warmStone
        return cells
    }

    private static func lighthouse() -> Cells {
        var cells = Cells()
        let cx = 3, cz = -3
        func disk(_ y: Int, _ radius: Double, _ color: Ink) {
            let n = Int(ceil(radius))
            for dx in -n...n {
                for dz in -n...n where Double(dx * dx + dz * dz) <= radius * radius {
                    cells[Cell(cx + dx, y, cz + dz)] = color
                }
            }
        }
        disk(5, 4.6, Paint.slate)
        disk(6, 4.5, Paint.limestone)
        for y in 7...21 {
            let red = (11...13).contains(y) || (17...19).contains(y)
            let radius = 4.45 - Double(y - 7) * 0.115
            disk(y, radius, red ? Paint.red : Paint.ivory)
        }
        // Entrance, threshold, and two small recessed observation windows.
        for y in 7...9 {
            let radius = 4.45 - Double(y - 7) * 0.115
            for dx in 0...1 {
                let front = Int(sqrt(radius * radius - Double(dx * dx)))
                cells[Cell(cx + dx, y, cz + front)] = Paint.wood
            }
        }
        fill(&cells, 3...4, 6...6, 2...2, Paint.limestone)
        cells[Cell(cx + 3, 14, cz)] = Paint.iron
        cells[Cell(cx + 3, 15, cz)] = Paint.iron
        cells[Cell(cx, 20, cz + 2)] = Paint.iron
        // Gallery, glass lantern, and tiered vermilion cap.
        disk(22, 4.2, Paint.iron)
        for y in 23...25 {
            for dx in -2...2 {
                for dz in -2...2 {
                    let corner = abs(dx) == 2 && abs(dz) == 2
                    let glass = dx == 2 || dz == -2 ? Paint.gold : Paint.light
                    let gleam = y == 25 && ((dx == 2 && dz == -1) || (dz == 2 && dx == -1))
                    cells[Cell(cx + dx, y, cz + dz)] = corner ? Paint.iron : (gleam ? Paint.ivory : glass)
                }
            }
        }
        for (dx, dz) in [(-3, -2), (-2, -3), (2, -3), (3, -2), (3, 2), (2, 3), (-2, 3), (-3, 2)] {
            cells[Cell(cx + dx, 23, cz + dz)] = Paint.slate
        }
        disk(26, 3.8, Paint.terracotta)
        disk(27, 3.0, Paint.red)
        disk(28, 2.0, Paint.red)
        disk(29, 1.0, Paint.terracotta)
        cells[Cell(cx, 30, cz)] = Paint.iron
        return cells
    }
}
