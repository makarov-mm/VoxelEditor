import Foundation

/// VOX material metadata travels with its RGB swatch, including through native project saves.
struct VoxSurface: Hashable, Codable {
    var alpha: UInt8
    var properties: [String: String]
}

enum MagicaVoxel {
    struct Scene {
        var layers: [VoxelLayer]
        var palette: [Ink]
        /// Add to an editor-space cell to recover its original world-space coordinates.
        var origin: Cell?
    }

    static func validOrigin(_ origin: Cell?) -> Bool {
        guard let origin else { return true }
        // Leave room for a 256-cell model around a signed-32-bit transform pivot.
        let limit = Int(Int32.max) + Cell.gridSize + 1
        return [origin.x, origin.y, origin.z].allSatisfy { (-limit...limit).contains($0) }
    }

    fileprivate enum Issue: LocalizedError {
        case invalid(String), limit(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid VOX file. " + reason
            case .limit(let reason): return reason
            }
        }
    }

    // A sparse 256³ model is supported. Bound the expanded scene before creating editor dictionaries.
    fileprivate static let voxelBudget = 2_000_000

    static func decode(_ data: Data) throws -> Scene {
        guard data.count <= 128 * 1024 * 1024 else { throw Issue.limit("The VOX file exceeds 128 MB.") }
        var file = VoxFile()
        try file.read(data)
        return try file.scene(from: data)
    }

    static func encode(layers: [VoxelLayer], palette: [Ink], origin: Cell? = nil) throws -> Data {
        guard validOrigin(origin) else { throw Issue.limit("The stored VOX world offset is out of range.") }
        return try VoxEncoder(layers: layers, palette: palette, origin: origin ?? Cell(0, 0, 0)).encode()
    }

    fileprivate static func defaultPalette() -> [Ink] {
        let levels = [255, 204, 153, 102, 51, 0]
        var colors: [Ink] = []
        func append(_ r: Int, _ g: Int, _ b: Int) {
            colors.append(Ink(Float(r) / 255, Float(g) / 255, Float(b) / 255))
        }
        for r in levels {
            for g in levels {
                for b in levels where r + g + b != 0 { append(r, g, b) }
            }
        }
        for channel in 0..<4 {
            for v in [238, 221, 187, 170, 136, 119, 85, 68, 34, 17] {
                append(channel == 0 || channel == 3 ? v : 0, channel == 1 || channel == 3 ? v : 0,
                       channel == 2 || channel == 3 ? v : 0)
            }
        }
        return colors
    }
}

private typealias VoxError = MagicaVoxel.Issue
private typealias Attributes = [String: String]

/// Every cursor is bounded to its enclosing chunk, including all counted fields inside it.
private struct VoxCursor {
    let data: Data
    var offset: Int
    let end: Int
    var remaining: Int { end - offset }

    mutating func take(_ n: Int) throws -> Range<Int> {
        guard n >= 0 && n <= remaining else { throw VoxError.invalid("A chunk is truncated.") }
        let start = offset
        offset += n
        return start..<offset
    }

    mutating func int() throws -> Int {
        let i = try take(4).lowerBound
        let n = UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
        return Int(Int32(bitPattern: n))
    }

    mutating func count(upTo limit: Int) throws -> Int {
        let n = try int()
        guard n >= 0 && n <= limit else { throw VoxError.invalid("A count or length is out of range.") }
        return n
    }

    mutating func text(_ length: Int) throws -> String {
        let range = try take(length)
        guard let result = String(data: data[range], encoding: .utf8) else {
            throw VoxError.invalid("Invalid text encoding.")
        }
        return result
    }

    mutating func dict() throws -> Attributes {
        var entries: Attributes = [:]
        for _ in 0..<(try count(upTo: remaining / 8)) {
            let key = try text(count(upTo: remaining))
            let value = try text(count(upTo: remaining))
            entries[key] = value
        }
        return entries
    }

    mutating func chunk() throws -> (String, VoxCursor, VoxCursor) {
        let tag = try text(4)
        let payload = try int()
        let children = try int()
        let a = try take(payload)
        let b = try take(children)
        return (tag, VoxCursor(data: data, offset: a.lowerBound, end: a.upperBound),
                VoxCursor(data: data, offset: b.lowerBound, end: b.upperBound))
    }
}

private struct VoxTransform {
    // Each signed element chooses a one-based source axis for one output row.
    var rows = [1, 2, 3]
    var shift = Cell(0, 0, 0)

    init() {}

    init(_ frame: Attributes) throws {
        if let rotation = frame["_r"] {
            guard let r = Int(rotation), (0...127).contains(r) else { throw VoxError.invalid("Invalid rotation.") }
            let a = r & 3, b = (r >> 2) & 3
            guard a < 3, b < 3, a != b else { throw VoxError.invalid("Invalid rotation axes.") }
            rows = [a + 1, b + 1, 4 - a - b]
            for i in 0..<3 where r & (1 << (4 + i)) != 0 { rows[i] = -rows[i] }
        }
        if let text = frame["_t"] {
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, let x = Int32(parts[0]), let y = Int32(parts[1]), let z = Int32(parts[2]) else {
                throw VoxError.invalid("Invalid transform translation.")
            }
            shift = Cell(Int(x), Int(y), Int(z))
        }
    }

    func point(_ p: Cell) -> Cell {
        func component(_ a: Int) -> Int {
            let value: Int
            switch abs(a) {
            case 1: value = p.x
            case 2: value = p.y
            default: value = p.z
            }
            return a < 0 ? -value : value
        }
        return shift.offset(component(rows[0]), component(rows[1]), component(rows[2]))
    }

    func concatenating(_ local: Self) -> Self {
        var result = Self()
        result.rows = rows.map { ($0 < 0 ? -1 : 1) * local.rows[abs($0) - 1] }
        result.shift = point(local.shift)
        return result
    }

    func cell(_ p: Cell) -> Cell {
        // A reflected unit cube starts one unit below its transformed lower corner.
        point(p).offset(rows[0] < 0 ? -1 : 0, rows[1] < 0 ? -1 : 0, rows[2] < 0 ? -1 : 0)
    }
}

private enum VoxNode {
    case transform(Attributes, Int, Int, VoxTransform)
    case group(Attributes, [Int])
    case shape(Attributes, Int)

    var children: [Int] {
        switch self {
        case let .transform(_, id, _, _): return [id]
        case let .group(_, ids): return ids
        case .shape: return []
        }
    }
}

private struct VoxFile {
    struct Model {
        var size: Cell
        var bytes: Range<Int>
    }

    var models: [Model] = []
    var nodes: [Int: VoxNode] = [:]
    var layerInfo: [Int: Attributes] = [:]
    var colors = MagicaVoxel.defaultPalette()
    var materials: [Int: Attributes] = [:]
    var displayOrder: [Int]?
    var nextSize: Cell?

    mutating func read(_ data: Data) throws {
        var reader = VoxCursor(data: data, offset: data.startIndex, end: data.endIndex)
        guard try reader.text(4) == "VOX " else { throw VoxError.invalid("Missing VOX signature.") }
        let version = try reader.int()
        guard version == 150 || version == 200 else {
            throw VoxError.limit("VOX version \(version) is unsupported. Use version 150 or 200.")
        }
        let (tag, root, contents) = try reader.chunk()
        guard tag == "MAIN", root.remaining == 0, reader.remaining == 0 else {
            throw VoxError.invalid("Invalid MAIN chunk.")
        }
        var chunks = contents
        while chunks.remaining > 0 {
            let (tag, payload, _) = try chunks.chunk()
            var c = payload
            switch tag {
            case "SIZE":
                guard nextSize == nil else { throw VoxError.invalid("A SIZE chunk has no voxel data.") }
                let size = try Cell(c.int(), c.int(), c.int())
                guard [size.x, size.y, size.z].allSatisfy({ (1...256).contains($0) }) else {
                    throw VoxError.limit("Each VOX model must be between 1 and 256 cells on each axis.")
                }
                nextSize = size
            case "XYZI":
                guard let size = nextSize else { throw VoxError.invalid("Missing model dimensions.") }
                let count = try c.count(upTo: size.x * size.y * size.z)
                guard count <= MagicaVoxel.voxelBudget else { throw budgetError }
                let bytes = try c.take(count * 4)
                guard models.count < 65_536 else { throw VoxError.limit("This file contains too many models.") }
                models.append(Model(size: size, bytes: bytes))
                nextSize = nil
            case "RGBA":
                let range = try c.take(1024)
                colors = (0..<255).map {
                    let i = range.lowerBound + $0 * 4
                    var color = Ink(Float(data[i]) / 255, Float(data[i + 1]) / 255, Float(data[i + 2]) / 255)
                    if data[i + 3] != 255 { color.surface = VoxSurface(alpha: data[i + 3], properties: [:]) }
                    return color
                }
            case "IMAP":
                let indices = Array(data[try c.take(256)]).map(Int.init)
                if Set(indices).count == 256 { displayOrder = indices.filter { $0 != 0 } }
            case "MATL":
                let id = try c.int()
                materials[id] = try c.dict()
            case "LAYR":
                let id = try c.int()
                layerInfo[id] = try c.dict()
                _ = try c.int()
            case "nTRN", "nGRP", "nSHP":
                let id = try c.int()
                guard id >= 0, nodes[id] == nil, nodes.count < 262_144 else {
                    throw VoxError.invalid("Invalid scene node ID.")
                }
                let attrs = try c.dict()
                if tag == "nTRN" {
                    let child = try c.int()
                    _ = try c.int()
                    let layer = try c.int()
                    let n = try c.count(upTo: c.remaining / 4)
                    guard n > 0 else { throw VoxError.invalid("Missing transform frame.") }
                    var chosen = Attributes(), earliest = Int.max
                    for index in 0..<n {
                        let frame = try c.dict()
                        let time = Int(frame["_f"] ?? "") ?? index
                        if index == 0 || time < earliest {
                            earliest = time
                            chosen = frame
                        }
                    }
                    nodes[id] = .transform(attrs, child, layer, try VoxTransform(chosen))
                } else if tag == "nGRP" {
                    let n = try c.count(upTo: c.remaining / 4)
                    var children: [Int] = []
                    for _ in 0..<n { children.append(try c.int()) }
                    nodes[id] = .group(attrs, children)
                } else {
                    let n = try c.count(upTo: c.remaining / 8)
                    guard n > 0 else { throw VoxError.invalid("Missing shape model.") }
                    var chosen = 0, earliest = Int.max
                    for index in 0..<n {
                        let model = try c.int(), frame = try c.dict()
                        let time = Int(frame["_f"] ?? "") ?? index
                        if index == 0 || time < earliest {
                            earliest = time
                            chosen = model
                        }
                    }
                    nodes[id] = .shape(attrs, chosen)
                }
            default: continue // Unknown chunk data and children were already skipped by chunk().
            }
            guard c.remaining == 0 else { throw VoxError.invalid("Unexpected data in \(tag).") }
        }
        guard nextSize == nil, !models.isEmpty else { throw VoxError.invalid("No complete model was found.") }
        for (id, attributes) in materials where (1...255).contains(id) && !attributes.isEmpty {
            colors[id - 1].surface = VoxSurface(alpha: colors[id - 1].surface?.alpha ?? 255, properties: attributes)
        }
    }

    private var budgetError: VoxError {
        .limit("This scene exceeds two million voxels. Split it into smaller files before importing.")
    }

    func scene(from data: Data) throws -> MagicaVoxel.Scene {
        var layers: [VoxelLayer] = []
        var minCell: Cell?, maxCell: Cell?
        var total = 0
        func instantiate(_ id: Int, _ transform: VoxTransform, _ name: String?, _ hidden: Bool) throws {
            guard models.indices.contains(id) else { throw VoxError.invalid("Unknown model reference.") }
            guard layers.count < EditorModel.layerLimit else {
                throw VoxError.limit("Forma supports up to \(EditorModel.layerLimit) objects per scene. "
                                     + "Merge objects in MagicaVoxel and try again.")
            }
            let model = models[id], n = model.bytes.count / 4
            total += n
            guard total <= MagicaVoxel.voxelBudget else { throw budgetError }
            var cells: [Cell: Ink] = [:]
            cells.reserveCapacity(n)
            for i in stride(from: model.bytes.lowerBound, to: model.bytes.upperBound, by: 4) {
                let x = Int(data[i]), y = Int(data[i + 1]), z = Int(data[i + 2]), index = Int(data[i + 3])
                guard x < model.size.x, y < model.size.y, z < model.size.z, index != 0 else {
                    throw VoxError.invalid("A voxel has an invalid position or palette index.")
                }
                let local = Cell(x - model.size.x / 2, y - model.size.y / 2, z - model.size.z / 2)
                let world = transform.cell(local)
                let p = Cell(world.x, world.z, -world.y - 1)
                cells[p] = colors[index - 1]
                if let a = minCell, let b = maxCell {
                    minCell = Cell(min(a.x, p.x), min(a.y, p.y), min(a.z, p.z))
                    maxCell = Cell(max(b.x, p.x), max(b.y, p.y), max(b.z, p.z))
                } else {
                    minCell = p
                    maxCell = p
                }
            }
            let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Model \(id + 1)"
            layers.append(VoxelLayer(name: label, isVisible: !hidden, cells: cells))
        }

        if nodes.isEmpty {
            // Legacy PACKs contain animation frames. Keep them as editable alternative layers.
            for i in models.indices {
                try instantiate(i, VoxTransform(), nil, i != 0)
            }
        } else {
            var visited = Set<Int>(), path = Set<Int>(), visits = 0
            func visit(_ id: Int, _ parent: VoxTransform, _ inherited: String?, _ hidden: Bool) throws {
                guard let node = nodes[id], path.insert(id).inserted else {
                    throw VoxError.invalid("Invalid node reference or cyclic scene graph.")
                }
                defer { path.remove(id) }
                visited.insert(id)
                visits += 1
                guard path.count <= 256, visits <= 500_000 else {
                    throw VoxError.limit("The VOX scene graph is too complex.")
                }
                switch node {
                case let .transform(attrs, child, layer, local):
                    let info = layerInfo[layer] ?? [:]
                    try visit(child, parent.concatenating(local), attrs["_name"] ?? info["_name"] ?? inherited,
                              hidden || attrs["_hidden"] == "1" || info["_hidden"] == "1")
                case let .group(attrs, children):
                    for child in children {
                        try visit(child, parent, attrs["_name"] ?? inherited, hidden || attrs["_hidden"] == "1")
                    }
                case let .shape(attrs, model):
                    try instantiate(model, parent, attrs["_name"] ?? inherited, hidden || attrs["_hidden"] == "1")
                }
            }
            let children = Set(nodes.values.flatMap(\.children))
            let roots = nodes.keys.filter { !children.contains($0) }.sorted()
            for id in roots { try visit(id, VoxTransform(), nil, false) }
            guard visited.count == nodes.count, !layers.isEmpty else {
                throw VoxError.invalid("Incomplete scene graph.")
            }
        }

        var origin: Cell?
        if let a = minCell, let b = maxCell {
            func offset(_ low: Int, _ high: Int, inside bounds: ClosedRange<Int>) throws -> Int {
                guard high - low < Cell.gridSize else {
                    throw VoxError.limit("The scene spans more than 256 cells on an axis. "
                                         + "Move its objects closer together or split the scene.")
                }
                if low < bounds.lowerBound { return bounds.lowerBound - low }
                if high > bounds.upperBound { return bounds.upperBound - high }
                return 0
            }
            let dx = try offset(a.x, b.x, inside: Cell.horizontalRange)
            let dy = try offset(a.y, b.y, inside: Cell.verticalRange)
            let dz = try offset(a.z, b.z, inside: Cell.horizontalRange)
            if dx != 0 || dy != 0 || dz != 0 {
                origin = Cell(-dx, -dy, -dz)
                guard MagicaVoxel.validOrigin(origin) else {
                    throw VoxError.limit("The scene origin exceeds the signed 32-bit VOX transform range.")
                }
                for i in layers.indices {
                    var rebased: [Cell: Ink] = [:]
                    rebased.reserveCapacity(layers[i].cells.count)
                    for (p, ink) in layers[i].cells { rebased[p.offset(dx, dy, dz)] = ink }
                    layers[i].cells = rebased
                }
            }
        }
        let order = displayOrder ?? Array(1...255)
        var seen = Set<Ink>()
        let swatches = order.map { colors[$0 - 1] }.filter { seen.insert($0).inserted }
        return MagicaVoxel.Scene(layers: layers, palette: swatches, origin: origin)
    }
}

private extension Data {
    mutating func put(_ n: Int) {
        var little = Int32(n).littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func putText(_ s: String) {
        put(s.utf8.count)
        append(contentsOf: s.utf8)
    }

    mutating func putDict(_ attributes: Attributes) {
        put(attributes.count)
        for key in attributes.keys.sorted() {
            putText(key)
            putText(attributes[key]!)
        }
    }

    mutating func chunk(_ tag: String, content: Data, children: Data = Data()) {
        append(contentsOf: tag.utf8)
        put(content.count)
        put(children.count)
        append(content)
        append(children)
    }
}

private struct VoxEncoder {
    let layers: [VoxelLayer]
    let palette: [Ink]
    let origin: Cell

    func encode() throws -> Data {
        guard !layers.isEmpty, layers.count <= EditorModel.layerLimit else {
            throw VoxError.limit("The number of layers is unsupported.")
        }
        let total = layers.reduce(0) { $0 + $1.cells.count }
        guard total <= MagicaVoxel.voxelBudget else {
            throw VoxError.limit("Split the scene into files with at most two million voxels each.")
        }
        var required = Set<Ink>()
        for layer in layers { required.formUnion(layer.cells.values) }
        guard required.count <= 255 else {
            throw VoxError.limit("VOX supports 255 colors and materials. "
                                 + "Reduce the number of swatches used by voxels before exporting.")
        }

        var colors: [Ink] = []
        var indices: [Ink: UInt8] = [:]
        func include(_ color: Ink) {
            guard indices[color] == nil, colors.count < 255 else { return }
            colors.append(color)
            indices[color] = UInt8(colors.count)
        }
        // Keep the existing swatch order whenever all swatches and all painted colors fit.
        let allFit = required.union(palette).count <= 255
        for color in palette where allFit || required.contains(color) { include(color) }
        for color in required where indices[color] == nil { include(color) }
        for color in palette { include(color) }

        var chunks = Data()
        func transform(_ id: Int, child: Int, layer: Int, name: String?, t: Cell) -> Data {
            var p = Data()
            p.put(id)
            p.putDict(name.map { ["_name": $0] } ?? [:])
            p.put(child)
            p.put(-1)
            p.put(layer)
            p.put(1)
            p.putDict(["_t": "\(t.x) \(t.y) \(t.z)"])
            return p
        }

        var transforms: [Cell] = []
        for layer in layers {
            var minimum: Cell?, maximum: Cell?
            func vox(_ p: Cell) -> Cell { Cell(p.x, -p.z - 1, p.y) }
            for p in layer.cells.keys {
                guard p.inBounds else { throw VoxError.limit("A voxel lies outside the editing grid.") }
                let v = vox(p)
                if let a = minimum, let b = maximum {
                    minimum = Cell(min(a.x, v.x), min(a.y, v.y), min(a.z, v.z))
                    maximum = Cell(max(b.x, v.x), max(b.y, v.y), max(b.z, v.z))
                } else {
                    minimum = v
                    maximum = v
                }
            }
            let a = minimum ?? Cell(0, 0, 0), b = maximum ?? a
            let size = Cell(b.x - a.x + 1, b.y - a.y + 1, b.z - a.z + 1)
            let pivot = a.offset(size.x / 2 + origin.x, size.y / 2 - origin.z, size.z / 2 + origin.y)
            guard [pivot.x, pivot.y, pivot.z].allSatisfy({ Int32(exactly: $0) != nil }) else {
                throw VoxError.limit("A model pivot is outside the signed 32-bit VOX transform range.")
            }
            transforms.append(pivot)
            var dimensions = Data()
            dimensions.put(size.x)
            dimensions.put(size.y)
            dimensions.put(size.z)
            chunks.chunk("SIZE", content: dimensions)

            var xyzi = Data(capacity: 4 + layer.cells.count * 4)
            xyzi.put(layer.cells.count)
            for (p, color) in layer.cells {
                let v = vox(p)
                xyzi.append(UInt8(v.x - a.x))
                xyzi.append(UInt8(v.y - a.y))
                xyzi.append(UInt8(v.z - a.z))
                xyzi.append(indices[color]!)
            }
            chunks.chunk("XYZI", content: xyzi)
        }

        chunks.chunk("nTRN", content: transform(0, child: 1, layer: -1, name: nil, t: Cell(0, 0, 0)))
        var group = Data()
        group.put(1)
        group.putDict([:])
        group.put(layers.count)
        for i in layers.indices { group.put(2 + 2 * i) }
        chunks.chunk("nGRP", content: group)
        for (i, layer) in layers.enumerated() {
            let id = 2 + i * 2
            chunks.chunk("nTRN", content: transform(id, child: id + 1, layer: i, name: layer.name, t: transforms[i]))
            var shape = Data()
            shape.put(id + 1)
            shape.putDict([:])
            shape.put(1)
            shape.put(i)
            shape.putDict([:])
            chunks.chunk("nSHP", content: shape)
            var info = Data()
            info.put(i)
            var attrs = ["_name": layer.name]
            if !layer.isVisible { attrs["_hidden"] = "1" }
            info.putDict(attrs)
            info.put(-1)
            chunks.chunk("LAYR", content: info)
        }

        var rgba = Data()
        func byte(_ n: Float) -> UInt8 { UInt8((max(0, min(1, n)) * 255).rounded()) }
        for color in colors {
            rgba.append(byte(color.r))
            rgba.append(byte(color.g))
            rgba.append(byte(color.b))
            rgba.append(color.surface?.alpha ?? 255)
        }
        rgba.append(Data(repeating: 0, count: 1024 - rgba.count))
        chunks.chunk("RGBA", content: rgba)
        for (i, color) in colors.enumerated() {
            if let attributes = color.surface?.properties, !attributes.isEmpty {
                var material = Data()
                material.put(i + 1)
                material.putDict(attributes)
                chunks.chunk("MATL", content: material)
            }
        }

        var result = Data("VOX ".utf8)
        result.put(150)
        result.chunk("MAIN", content: Data(), children: chunks)
        return result
    }
}
