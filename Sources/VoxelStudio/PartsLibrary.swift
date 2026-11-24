import AppKit

struct LibraryPart: Identifiable, Codable {
    let id: UUID
    let name: String
    let count: Int
}

final class PartsLibrary: ObservableObject {
    @Published private(set) var parts: [LibraryPart] = []
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("studio.forma.voxel/Parts", isDirectory: true)) {
        self.directory = directory
    }

    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func reload() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { parts = []; return }
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])
        let loaded = entries.compactMap { url -> LibraryPart? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let data = try? Data(contentsOf: url.appendingPathComponent("info.json")),
                  let part = try? JSONDecoder().decode(LibraryPart.self, from: data),
                  part.id == id else { return nil }
            return part
        }
        parts = loaded.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    @discardableResult
    func save(_ fragment: VoxelFragment, name: String) throws -> LibraryPart {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PartsError.emptyName }
        let part = LibraryPart(id: UUID(), name: name, count: fragment.cells.count)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".saving-" + part.id.uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try fragment.encoded().write(to: staging.appendingPathComponent("voxels.fvx"))
        try PartThumbnail.png(for: fragment).write(to: staging.appendingPathComponent("preview.png"))
        try JSONEncoder().encode(part).write(to: staging.appendingPathComponent("info.json"))
        try manager.moveItem(at: staging, to: folder(part.id))
        try reload()
        return part
    }

    func fragment(for part: LibraryPart) throws -> VoxelFragment {
        let data = try Data(contentsOf: folder(part.id).appendingPathComponent("voxels.fvx"), options: .mappedIfSafe)
        return try VoxelFragment.decode(data)
    }

    func thumbnail(for part: LibraryPart) -> NSImage? {
        NSImage(contentsOf: folder(part.id).appendingPathComponent("preview.png"))
    }

    func remove(_ part: LibraryPart) throws {
        try FileManager.default.removeItem(at: folder(part.id))
        try reload()
    }
}

private enum PartsError: LocalizedError {
    case emptyName, thumbnail
    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the part."
        case .thumbnail: return "The preview image couldn’t be created."
        }
    }
}

private enum PartThumbnail {
    static func png(for fragment: VoxelFragment) throws -> Data {
        // Reduce only the preview geometry. Pick the frontmost source color in each sample.
        let stride = (max(fragment.size.x, fragment.size.y, fragment.size.z) + 39) / 40
        var samples: [Cell: (Int, Ink)] = [:]
        for (cell, ink) in fragment.cells {
            let sample = Cell(cell.x / stride, cell.y / stride, cell.z / stride)
            let rank = ((cell.x + cell.y + cell.z) * 256 + cell.y) * 256 + cell.x
            if rank > (samples[sample]?.0 ?? -1) { samples[sample] = (rank, ink) }
        }
        let width = CGFloat((fragment.size.x + stride - 1) / stride)
        let height = CGFloat((fragment.size.y + stride - 1) / stride)
        let depth = CGFloat((fragment.size.z + stride - 1) / stride)
        let edge = 160
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PartsError.thumbnail }
        let horizontal = sqrt(CGFloat(3)) / 2
        let scale = (CGFloat(edge) - 12) / max((width + depth) * horizontal, height + (width + depth) / 2)
        func project(_ x: Int, _ y: Int, _ z: Int) -> CGPoint {
            let u = horizontal * (CGFloat(x - z) - (width - depth) / 2)
            let v = CGFloat(y) - CGFloat(x + z) / 2 - (height / 2 - (width + depth) / 4)
            return CGPoint(x: CGFloat(edge) / 2 + u * scale, y: CGFloat(edge) / 2 + v * scale)
        }
        context.setShouldAntialias(false)
        let backToFront = samples.keys.sorted { $0.x + $0.y + $0.z < $1.x + $1.y + $1.z }
        for p in backToFront {
            guard let ink = samples[p]?.1 else { continue }
            let x = p.x, y = p.y, z = p.z
            func face(_ shade: CGFloat, _ points: [CGPoint]) {
                context.setFillColor(red: CGFloat(ink.r) * shade, green: CGFloat(ink.g) * shade,
                                     blue: CGFloat(ink.b) * shade, alpha: 1)
                context.beginPath()
                context.addLines(between: points)
                context.closePath()
                context.fillPath()
            }
            if samples[p.offset(1, 0, 0)] == nil {
                face(0.82, [project(x+1,y,z), project(x+1,y,z+1), project(x+1,y+1,z+1), project(x+1,y+1,z)])
            }
            if samples[p.offset(0, 0, 1)] == nil {
                face(0.65, [project(x,y,z+1), project(x+1,y,z+1), project(x+1,y+1,z+1), project(x,y+1,z+1)])
            }
            if samples[p.offset(0, 1, 0)] == nil {
                face(1, [project(x,y+1,z), project(x+1,y+1,z), project(x+1,y+1,z+1), project(x,y+1,z+1)])
            }
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw PartsError.thumbnail }
        return png
    }
}
