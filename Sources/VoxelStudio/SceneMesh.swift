import Metal
import simd

typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>

struct VoxelFace: Equatable {
    var base: V4
    var color: V4
    var ao: V4
    var extent = V4(repeating: 1)
}

let normalOffsets = [SIMD3<Int>(1, 0, 0), SIMD3<Int>(-1, 0, 0),
                     SIMD3<Int>(0, 1, 0), SIMD3<Int>(0, -1, 0),
                     SIMD3<Int>(0, 0, 1), SIMD3<Int>(0, 0, -1)]
private let corners = [SIMD2<Int>(0, 0), SIMD2<Int>(1, 0), SIMD2<Int>(1, 1), SIMD2<Int>(0, 1)]
private let basisU = [SIMD3<Int>(0, 0, 1), SIMD3<Int>(0, 0, 1), SIMD3<Int>(1, 0, 0),
              SIMD3<Int>(1, 0, 0), SIMD3<Int>(1, 0, 0), SIMD3<Int>(1, 0, 0)]
private let basisV = [SIMD3<Int>(0, 1, 0), SIMD3<Int>(0, 1, 0), SIMD3<Int>(0, 0, 1),
              SIMD3<Int>(0, 0, 1), SIMD3<Int>(0, 1, 0), SIMD3<Int>(0, 1, 0)]
let faceLight: [Float] = [0.79, 0.87, 1.04, 0.65, 0.96, 0.83]

func cell(_ p: SIMD3<Int>) -> Cell { Cell(p.x, p.y, p.z) }
func float3(_ p: SIMD3<Int>) -> V3 { V3(Float(p.x), Float(p.y), Float(p.z)) }
func origin(_ f: VoxelFace) -> V3 { V3(f.base.x, f.base.y, f.base.z) }

func vertices(_ face: VoxelFace) -> [V3] {
    let side = Int(face.base.w)
    let extent = V3(face.extent.x, face.extent.y, face.extent.z)
    let start = origin(face) + (side % 2 == 0 ? float3(normalOffsets[side]) * extent : .zero)
    let u = float3(basisU[side]) * extent, v = float3(basisV[side]) * extent
    return [start, start + u, start + u + v, start + v]
}

/// Exposed faces and ambient occlusion in definition coordinates.
final class VoxelMesh {
    private(set) var faces = [VoxelFace]()
    private(set) var centers = [V3]()
    private(set) var lower = V3(repeating: .infinity)
    private(set) var upper = V3(repeating: -.infinity)
    var metalBuffer: MTLBuffer?

    init(_ voxels: [Cell: Ink], neighbors: [Cell: Ink]? = nil) {
        let occupied = neighbors ?? voxels
        centers.reserveCapacity(min(65_536, voxels.count))
        faces.reserveCapacity(min(131_072, voxels.count * 2))
        for (c, ink) in voxels {
            let xyz = SIMD3(c.x, c.y, c.z)
            let p = float3(xyz)
            lower = simd_min(lower, p)
            upper = simd_max(upper, p)
            let firstFace = faces.count
            let rgb = V4(ink.r, ink.g, ink.b, 1)
            for faceID in 0..<6 {
                let n = xyz &+ normalOffsets[faceID]
                guard occupied[cell(n)] == nil else { continue }
                var ao = V4(repeating: 1)
                for j in 0..<4 {
                    let u = basisU[faceID] &* (corners[j].x * 2 - 1)
                    let v = basisV[faceID] &* (corners[j].y * 2 - 1)
                    let a = occupied[cell(n &+ u)] != nil, b = occupied[cell(n &+ v)] != nil
                    let d = occupied[cell(n &+ u &+ v)] != nil
                    let level = a && b ? 3 : (a ? 1 : 0) + (b ? 1 : 0) + (d ? 1 : 0)
                    ao[j] = 1 - Float(level) * 0.045
                }
                faces.append(VoxelFace(base: V4(p, Float(faceID)), color: rgb, ao: ao))
            }
            guard faces.count > firstFace else { continue }
            centers.append(p + 0.5)
        }
    }
}

struct GroundShadow {
    var shadow = [UInt8]()
    let shadowSize: Int
    let shadowOrigin: SIMD2<Float>
    let shadowSpan: Float

    init(_ centers: [V3]) {
        // Keep the shadow texture around the projected geometry even for off-center models.
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for center in centers {
            let p = center - 0.5
            let projected = SIMD2(p.x + p.y * 0.31, p.z - p.y * 0.19)
            lo = simd_min(lo, projected)
            hi = simd_max(hi, projected + 1)
        }
        if centers.isEmpty { (lo, hi) = (.zero, .zero) }
        shadowSpan = max(8, max(hi.x - lo.x, hi.y - lo.y) + 8)
        shadowOrigin = (lo + hi - SIMD2(repeating: shadowSpan)) * 0.5
        shadowSize = max(20, min(640, Int(ceil(shadowSpan * 2))))
        let side = shadowSize
        var shadowField = [Float](repeating: 0, count: side * side)
        let resolution = Float(side) / shadowSpan
        for center in centers {
            let p = center - 0.5
            // Project each cell onto the ground in the opposite direction to the key light.
            let sx = (p.x + p.y * 0.31 - shadowOrigin.x) * resolution
            let sz = (p.z - p.y * 0.19 - shadowOrigin.y) * resolution
            let value = max(0.4, 1 - p.y * 0.012)
            let x0 = max(0, min(side - 1, Int(floor(sx)))), x1 = max(x0, min(side - 1, Int(ceil(sx + resolution))))
            let z0 = max(0, min(side - 1, Int(floor(sz)))), z1 = max(z0, min(side - 1, Int(ceil(sz + resolution))))
            for z in z0...z1 {
                for x in x0...x1 {
                    let i = z * side + x
                    shadowField[i] = max(shadowField[i], value)
                }
            }
        }
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var horizontal = shadowField
        for y in 0..<side {
            for x in 2..<(side - 2) {
                let i = y * side + x
                horizontal[i] = (0..<5).reduce(0) { $0 + shadowField[i + $1 - 2] * weights[$1] }
            }
        }
        shadow = [UInt8](repeating: 0, count: side * side)
        for y in 2..<(side - 2) {
            for x in 0..<side {
                let i = y * side + x
                let value = (0..<5).reduce(Float(0)) { $0 + horizontal[i + ($1 - 2) * side] * weights[$1] }
                shadow[i] = UInt8(clamping: Int((value * 255).rounded()))
            }
        }
    }
}

/// CPU and Metal use these same rows and side/corner permutations. Cell indices
/// refer to cube minima; even with a reflected axis, a cube still extends toward +1.
struct MeshPlacement: Equatable {
    var x, y, z: V4
    private var sides0 = SIMD4<UInt32>.zero
    private var sides1 = SIMD4<UInt32>.zero
    static let identity = MeshPlacement(.identity)

    init(_ transform: VoxelTransform) {
        func row(_ axis: Int, offset: Int) -> V4 {
            var result = V4(0, 0, 0, Float(offset))
            result[abs(axis) - 1] = axis > 0 ? 1 : -1
            return result
        }
        x = row(transform.axes[0], offset: transform.offset.x)
        y = row(transform.axes[1], offset: transform.offset.y)
        z = row(transform.axes[2], offset: transform.offset.z)
        for local in normalOffsets.indices {
            let normal = direction(float3(normalOffsets[local]))
            let axis = normal.x != 0 ? 0 : (normal.y != 0 ? 1 : 2)
            let world = axis * 2 + (normal[axis] < 0 ? 1 : 0)
            var mapping = UInt32(world)
            for i in corners.indices {
                // Corner offsets around the face center are signed unit tangents.
                let tangent = basisU[local] &* (2 * corners[i].x - 1) &+ basisV[local] &* (2 * corners[i].y - 1)
                let placed = direction(float3(tangent))
                let u = simd_dot(placed, float3(basisU[world])) > 0
                let v = simd_dot(placed, float3(basisV[world])) > 0
                let j = v ? (u ? 2 : 3) : (u ? 1 : 0)
                mapping |= UInt32(i) << (3 + 2 * j)
            }
            if local < 4 { sides0[local] = mapping } else { sides1[local - 4] = mapping }
        }
    }

    private func direction(_ v: V3) -> V3 {
        let v = V4(v, 0)
        return V3(simd_dot(x, v), simd_dot(y, v), simd_dot(z, v))
    }

    func placeCell(_ p: V3) -> V3 { direction(p) + V3(x.w, y.w, z.w) }

    func placeFace(_ face: VoxelFace) -> VoxelFace {
        let side = Int(face.base.w)
        let mapping = side < 4 ? sides0[side] : sides1[side - 4]
        var result = face
        result.base = V4(placeCell(origin(face)), Float(mapping & 7))
        for i in 0..<4 { result.ao[i] = face.ao[Int((mapping >> (3 + 2 * i)) & 3)] }
        return result
    }
}

struct MeshDraw {
    let mesh: VoxelMesh
    let placement: MeshPlacement
}

final class RenderScene {
    let draws: [MeshDraw]
    let centers: [V3]
    let ground: GroundShadow

    init(draws: [MeshDraw]) {
        self.draws = draws
        if draws.count == 1, draws[0].placement == .identity {
            centers = draws[0].mesh.centers
        } else {
            centers = draws.flatMap { draw -> [V3] in
                if draw.placement == .identity { return draw.mesh.centers }
                return draw.mesh.centers.map { draw.placement.placeCell($0 - 0.5) + 0.5 }
            }
        }
        ground = GroundShadow(centers)
    }

    func worldFaces() -> [VoxelFace] {
        if draws.count == 1, draws[0].placement == .identity { return draws[0].mesh.faces }
        return draws.flatMap { draw in
            draw.placement == .identity ? draw.mesh.faces : draw.mesh.faces.map(draw.placement.placeFace)
        }
    }
}

enum MeshKey: Hashable {
    case definition(id: UUID, version: UUID, visibleSlots: [Int])
    case looseLayers(ids: [UUID], versions: [UUID])
}

struct MeshSource {
    let key: MeshKey
    let transform: VoxelTransform
    let layers: [(index: Int, layer: VoxelLayer)]

    private static func merge(_ layers: [(index: Int, layer: VoxelLayer)]) -> [Cell: Ink] {
        var result = [Cell: Ink]()
        for entry in layers.sorted(by: { $0.index < $1.index }) {
            result.merge(entry.layer.cells) { _, upper in upper }
        }
        return result
    }

    func localCells() -> [Cell: Ink] {
        let cells = Self.merge(layers)
        guard transform != .identity else { return cells }
        return Dictionary(uniqueKeysWithValues: cells.map { (transform.unapply($0.key), $0.value) })
    }

    static func composite(_ sources: [Self]) -> [Cell: Ink] {
        merge(sources.flatMap(\.layers))
    }
}

private struct PlacedMeshKey: Hashable {
    let mesh: MeshKey
    let axes: [Int]
    let offset: Cell
    let order: [Int]

    init(_ source: MeshSource) {
        mesh = source.key
        axes = source.transform.axes
        offset = source.transform.offset
        order = source.layers.map(\.index)
    }
}

private struct MeshBounds {
    let index: Int
    let low, high: Cell

    init?(_ draw: MeshDraw, index: Int) {
        guard !draw.mesh.centers.isEmpty else { return nil }
        self.index = index
        let a = draw.placement.placeCell(draw.mesh.lower), b = draw.placement.placeCell(draw.mesh.upper)
        let lower = simd_min(a, b), upper = simd_max(a, b)
        low = Cell(Int(lower.x), Int(lower.y), Int(lower.z))
        high = Cell(Int(upper.x), Int(upper.y), Int(upper.z))
    }

    func contains(_ p: Cell) -> Bool {
        p.x >= low.x && p.x <= high.x && p.y >= low.y && p.y <= high.y && p.z >= low.z && p.z <= high.z
    }

    func forEachChunk(padding: Int, _ visit: (Cell) -> Void) {
        let first = meshChunk(low.offset(-padding, -padding, -padding))
        let last = meshChunk(high.offset(padding, padding, padding))
        for x in first.x...last.x {
            for y in first.y...last.y {
                for z in first.z...last.z { visit(Cell(x, y, z)) }
            }
        }
    }
}

private func meshChunk(_ p: Cell) -> Cell { Cell(p.x >> 4, p.y >> 4, p.z >> 4) }

/// Separate objects can use a shared local mesh. Within one cell, a neighbor
/// can change face visibility or corner occlusion, including across a chunk edge.
private func touchingSources(_ bounds: [MeshBounds]) -> Set<Int> {
    let sorted = bounds.sorted { $0.low.x < $1.low.x }
    var touching = Set<Int>()
    for (i, a) in sorted.enumerated() {
        for b in sorted[(i + 1)...] {
            if b.low.x > a.high.x + 1 { break }
            if b.low.y <= a.high.y + 1 && b.high.y + 1 >= a.low.y &&
               b.low.z <= a.high.z + 1 && b.high.z + 1 >= a.low.z {
                touching.insert(a.index)
                touching.insert(b.index)
            }
        }
    }
    return touching
}

private struct MeshChunkRecord {
    let dependencies: [PlacedMeshKey]
    let mesh: VoxelMesh?
}

final class SceneMeshCache {
    private var projectID: UUID?
    private var local = [MeshKey: VoxelMesh]()
    private var chunks = [Cell: MeshChunkRecord]()
    private var previous: RenderScene?
    private(set) var localBuildCount = 0
    private(set) var compositeBuildCount = 0

    func resolve(_ model: EditorModel, world: [Cell: Ink]) -> RenderScene {
        if projectID != model.projectID {
            projectID = model.projectID
            local.removeAll()
            chunks.removeAll()
            previous = nil
        }
        if model.sliceEnabled { return clipped(world) }
        let shown = model.layers.enumerated().filter { !$0.element.cells.isEmpty && model.isLayerShownInEditor($0.element) }
        let byID = Dictionary(uniqueKeysWithValues: shown.map { ($0.element.id, ($0.offset, $0.element)) })
        let objects = model.sceneLayout.objects
        let owned = Set(objects.flatMap(\.layerIDs))
        let loose = shown.filter { !owned.contains($0.element.id) }.map { (index: $0.offset, layer: $0.element) }
        var sources = [MeshSource]()
        if !loose.isEmpty {
            let ids = loose.map { $0.layer.id }
            let key = MeshKey.looseLayers(ids: ids, versions: ids.map { model.geometryVersion(for: $0) })
            sources.append(MeshSource(key: key, transform: .identity, layers: loose))
        }
        for object in objects {
            let entries = object.layerIDs.enumerated().compactMap { slot, id -> (Int, Int, VoxelLayer)? in
                guard let (index, layer) = byID[id] else { return nil }
                return (slot, index, layer)
            }.sorted { $0.1 < $1.1 }
            guard !entries.isEmpty else { continue }
            let key = MeshKey.definition(id: object.definitionID, version: model.definitionVersion(for: object.definitionID),
                                         visibleSlots: entries.map { $0.0 })
            sources.append(MeshSource(key: key, transform: object.transform, layers: entries.map { ($0.1, $0.2) }))
        }
        return resolve(sources, world: world)
    }

    func clipped(_ world: [Cell: Ink]) -> RenderScene {
        // A world-space cut exposes different faces in every transformed instance.
        compositeBuildCount += 1
        return RenderScene(draws: [MeshDraw(mesh: VoxelMesh(world), placement: .identity)])
    }

    func resolve(_ sources: [MeshSource], world: [Cell: Ink]) -> RenderScene {
        var live = [MeshKey: VoxelMesh]()
        let draws = sources.map { source -> MeshDraw in
            let mesh: VoxelMesh
            if let hit = live[source.key] ?? local[source.key] {
                mesh = hit
            } else {
                let cells = sources.count == 1 && source.transform == .identity ? world : source.localCells()
                mesh = VoxelMesh(cells)
                localBuildCount += 1
            }
            live[source.key] = mesh
            let placement = source.transform == .identity ? MeshPlacement.identity : MeshPlacement(source.transform)
            return MeshDraw(mesh: mesh, placement: placement)
        }
        local = live
        let bounds = draws.enumerated().compactMap { MeshBounds($0.element, index: $0.offset) }
        let touching = touchingSources(bounds)
        var batches = bounds.filter { !touching.contains($0.index) }.map { draws[$0.index] }
        if touching.isEmpty {
            chunks.removeAll()
        } else {
            batches += resolveChunks(bounds: bounds, touching: touching, sources: sources, world: world)
        }
        if let previous, previous.draws.count == batches.count,
           zip(previous.draws, batches).allSatisfy({ $0.mesh === $1.mesh && $0.placement == $1.placement }) {
            return previous
        }
        let scene = RenderScene(draws: batches)
        previous = scene
        return scene
    }

    private func resolveChunks(bounds: [MeshBounds], touching: Set<Int>, sources: [MeshSource],
                               world: [Cell: Ink]) -> [MeshDraw] {
        var covered = Set<Cell>()
        var dependencies = [Cell: [PlacedMeshKey]]()
        var separate = [Cell: [MeshBounds]]()
        for box in bounds {
            if touching.contains(box.index) {
                let key = PlacedMeshKey(sources[box.index])
                box.forEachChunk(padding: 0) { covered.insert($0) }
                box.forEachChunk(padding: 1) { dependencies[$0, default: []].append(key) }
            } else {
                // A separate object can share a chunk without touching its other voxels.
                box.forEachChunk(padding: 0) { separate[$0, default: []].append(box) }
            }
        }

        let dirty: Set<Cell> = covered.filter { chunks[$0]?.dependencies != dependencies[$0] }
        var ownedCells = [Cell: [Cell: Ink]]()
        if !dirty.isEmpty {
            for (p, ink) in world {
                let id = meshChunk(p)
                guard dirty.contains(id), separate[id]?.contains(where: { $0.contains(p) }) != true else { continue }
                ownedCells[id, default: [:]][p] = ink
            }
        }
        var next = [Cell: MeshChunkRecord]()
        var draws = [MeshDraw]()
        let order = covered.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
        for id in order {
            let record: MeshChunkRecord
            if !dirty.contains(id), let cached = chunks[id] {
                record = cached
            } else {
                let mesh = ownedCells[id].map { VoxelMesh($0, neighbors: world) }
                if mesh != nil { compositeBuildCount += 1 }
                record = MeshChunkRecord(dependencies: dependencies[id] ?? [], mesh: mesh)
            }
            next[id] = record
            if let mesh = record.mesh, !mesh.faces.isEmpty { draws.append(MeshDraw(mesh: mesh, placement: .identity)) }
        }
        chunks = next
        return draws
    }
}
