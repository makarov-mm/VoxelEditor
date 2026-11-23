import Foundation

/// An immutable, sparse selection. Cell positions are offsets from the original bounding-box minimum.
final class VoxelFragment: Equatable {
    static let maxCells = 2_000_000
    private static let byteLimit = 128 * 1024 * 1024
    private static let signature = Data("FVX1".utf8)

    let origin: Cell
    let size: Cell
    let cells: [Cell: Ink]

    static func == (lhs: VoxelFragment, rhs: VoxelFragment) -> Bool { lhs === rhs }

    init?(origin: Cell, cells: [Cell: Ink]) {
        guard origin.inBounds, !cells.isEmpty, cells.count <= Self.maxCells else { return nil }
        var low = Cell(255, 255, 255), high = Cell(0, 0, 0)
        for (offset, ink) in cells {
            guard (0..<Cell.gridSize).contains(offset.x), (0..<Cell.gridSize).contains(offset.y),
                  (0..<Cell.gridSize).contains(offset.z), ink.isValid else { return nil }
            low = Cell(min(low.x, offset.x), min(low.y, offset.y), min(low.z, offset.z))
            high = Cell(max(high.x, offset.x), max(high.y, offset.y), max(high.z, offset.z))
        }
        guard low == Cell(0, 0, 0), origin.offset(high).inBounds else { return nil }
        self.origin = origin
        self.cells = cells
        self.size = high.offset(1, 1, 1)
    }

    enum Issue: LocalizedError {
        case invalid, tooLarge

        var errorDescription: String? {
            switch self {
            case .invalid: return "The clipboard does not contain a valid Forma voxel fragment."
            case .tooLarge: return "The voxel fragment exceeds the clipboard size limit."
            }
        }
    }

    // FVX1: source origin, cell count, seven-byte voxel records (XYZ + UInt32 palette index),
    // then a palette of exact Float32 RGB values and optional length-prefixed VOX material data.
    func encoded() throws -> Data {
        var data = Self.signature
        data.append(contentsOf: [UInt8(origin.x + 128), UInt8(origin.y), UInt8(origin.z + 128)])
        data.appendFragmentWord(UInt32(cells.count))
        var indices: [Ink: UInt32] = [:]
        var palette: [Ink] = []
        for (point, ink) in cells {
            let index: UInt32
            if let known = indices[ink] {
                index = known
            } else {
                index = UInt32(palette.count)
                indices[ink] = index
                palette.append(ink)
            }
            data.append(contentsOf: [UInt8(point.x), UInt8(point.y), UInt8(point.z)])
            data.appendFragmentWord(index)
        }
        data.appendFragmentWord(UInt32(palette.count))
        let encoder = JSONEncoder()
        for ink in palette {
            let material = try ink.surface.map { try encoder.encode($0) } ?? Data()
            guard material.count <= Self.byteLimit - data.count - 16 else { throw Issue.tooLarge }
            data.appendFragmentWord(ink.r.bitPattern)
            data.appendFragmentWord(ink.g.bitPattern)
            data.appendFragmentWord(ink.b.bitPattern)
            data.appendFragmentWord(UInt32(material.count))
            data.append(material)
        }
        return data
    }

    static func decode(_ data: Data) throws -> VoxelFragment {
        guard data.count <= byteLimit else { throw Issue.tooLarge }
        var reader = FragmentReader(data)
        guard try reader.read(4) == signature else { throw Issue.invalid }
        let origin = try Cell(Int(reader.byte()) - 128, Int(reader.byte()), Int(reader.byte()) - 128)
        let count = Int(try reader.word())
        guard count > 0, count <= maxCells else { throw Issue.invalid }
        var records = try FragmentReader(reader.read(count * 7))
        let paletteCount = Int(try reader.word())
        guard (1...count).contains(paletteCount), paletteCount <= reader.remaining / 16 else { throw Issue.invalid }
        var palette: [Ink] = []
        palette.reserveCapacity(paletteCount)
        let decoder = JSONDecoder()
        for _ in 0..<paletteCount {
            var ink = try Ink(Float(bitPattern: reader.word()), Float(bitPattern: reader.word()),
                              Float(bitPattern: reader.word()))
            guard ink.isValid else { throw Issue.invalid }
            let length = Int(try reader.word())
            if length > 0 {
                let payload = try reader.read(length)
                guard let surface = try? decoder.decode(VoxSurface.self, from: payload) else { throw Issue.invalid }
                ink.surface = surface
            }
            palette.append(ink)
        }
        guard reader.remaining == 0 else { throw Issue.invalid }
        var cells: [Cell: Ink] = [:]
        cells.reserveCapacity(count)
        for _ in 0..<count {
            let offset = try Cell(Int(records.byte()), Int(records.byte()), Int(records.byte()))
            let index = Int(try records.word())
            guard index < palette.count, cells.updateValue(palette[index], forKey: offset) == nil else {
                throw Issue.invalid
            }
        }
        guard let fragment = VoxelFragment(origin: origin, cells: cells) else { throw Issue.invalid }
        return fragment
    }
}

private extension Data {
    mutating func appendFragmentWord(_ word: UInt32) {
        var bytes = word.littleEndian
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}

private struct FragmentReader {
    let data: Data
    var position: Data.Index
    var remaining: Int { data.endIndex - position }

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count <= remaining else { throw VoxelFragment.Issue.invalid }
        let start = position
        position += count
        return data[start..<position]
    }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw VoxelFragment.Issue.invalid }
        defer { position += 1 }
        return data[position]
    }

    mutating func word() throws -> UInt32 {
        guard remaining >= 4 else { throw VoxelFragment.Issue.invalid }
        let offset = position - data.startIndex
        position += 4
        return data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
