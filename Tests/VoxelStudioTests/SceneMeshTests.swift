import XCTest
@testable import VoxelStudio

final class SceneMeshTests: XCTestCase {
    private let red = Ink(hex: "C63029"), blue = Ink(hex: "1999BC")

    private func source(_ cells: [Cell: Ink], key: MeshKey, at transform: VoxelTransform, index: Int) -> MeshSource {
        let placed = Dictionary(uniqueKeysWithValues: cells.map { (transform.apply($0.key), $0.value) })
        let layer = VoxelLayer(name: "Part", cells: placed)
        return MeshSource(key: key, transform: transform, layers: [(index, layer)])
    }

    private func definition() -> MeshKey { .definition(id: UUID(), version: UUID(), visibleSlots: [0]) }

    private func faceMap(_ faces: [VoxelFace]) -> [SIMD4<Float>: VoxelFace] {
        Dictionary(uniqueKeysWithValues: faces.map { ($0.base, $0) })
    }

    func testAllSignedPermutationsMatchWorldMeshAndAmbientOcclusion() {
        let cells = [Cell(0, 0, 0): red, Cell(1, 1, 0): blue, Cell(1, 1, 1): red,
                     Cell(-1, 0, 1): red, Cell(0, 0, 1): blue]
        let mesh = VoxelMesh(cells)
        XCTAssertTrue(mesh.faces.contains { $0.ao.x != $0.ao.z })
        let permutations = [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]]
        for axes in permutations {
            for mask in 0..<8 {
                let signed = axes.enumerated().map { ($0.element) * (mask & (1 << $0.offset) == 0 ? 1 : -1) }
                let transform = VoxelTransform(axes: signed, offset: Cell(-11, 20, 9))
                let placed = MeshPlacement(transform)
                let world = source(cells, key: definition(), at: transform, index: 0).layers[0].layer.cells
                XCTAssertEqual(faceMap(mesh.faces.map(placed.placeFace)), faceMap(VoxelMesh(world).faces), "\(signed)")
            }
        }
        XCTAssertEqual(MemoryLayout<MeshPlacement>.stride, 80, "Metal's Placement consists of five 16-byte vectors")
    }

    @MainActor
    func testEditorObjectMovementLinkedPaintingIsolationAndSlicing() async throws {
        let model = EditorModel(), cache = SceneMeshCache()
        model.newProject()
        model.ink = red
        model.apply(hit: nil, adjacent: Cell(0, 0, 0))
        model.apply(hit: nil, adjacent: Cell(0, 1, 0))
        model.tool = .select
        model.selectAllOnActiveLayer()
        XCTAssertTrue(model.createObjectFromSelection(name: "Tower"))
        let first = try XCTUnwrap(model.activeSceneObject)
        XCTAssertTrue(model.duplicateObject(first.id, linked: true))
        let copy = try XCTUnwrap(model.activeSceneObject)
        XCTAssertTrue(model.moveObject(copy.id, by: Cell(8, 0, 0)))
        let initial = cache.resolve(model, world: model.viewportCells)
        XCTAssertEqual(initial.draws.count, 2)
        XCTAssertTrue(initial.draws[0].mesh === initial.draws[1].mesh)
        XCTAssertEqual(cache.localBuildCount, 1)
        XCTAssertTrue(model.rotateObject(copy.id, around: .z, pivot: copy.transform.apply(Cell(0, 0, 0)).offset(8, 0, 0)))
        let moved = cache.resolve(model, world: model.viewportCells)
        XCTAssertTrue(moved.draws[0].mesh === initial.draws[0].mesh)
        XCTAssertEqual(cache.localBuildCount, 1)
        XCTAssertEqual(faceMap(moved.worldFaces()), faceMap(VoxelMesh(model.viewportCells).faces))

        model.selectObject(first.id)
        model.tool = .paint
        model.ink = blue
        model.apply(hit: Cell(0, 0, 0), adjacent: nil)
        let painted = cache.resolve(model, world: model.viewportCells)
        XCTAssertEqual(cache.localBuildCount, 2)
        XCTAssertTrue(painted.draws[0].mesh === painted.draws[1].mesh)
        XCTAssertEqual(faceMap(painted.worldFaces()), faceMap(VoxelMesh(model.viewportCells).faces))

        model.toggleLayer(copy.layerIDs[0])
        let hidden = cache.resolve(model, world: model.viewportCells)
        XCTAssertEqual(hidden.draws.count, 1)
        XCTAssertTrue(hidden.draws[0].mesh === painted.draws[0].mesh)
        model.sliceEnabled = true
        model.sliceLevel = 0
        let sliced = cache.resolve(model, world: model.viewportCells)
        XCTAssertEqual(faceMap(sliced.worldFaces()), faceMap(VoxelMesh(model.viewportCells).faces))
    }

    func testLocalMeshReuseAndSceneRebuildCost() {
        var shape = [Cell: Ink]()
        for y in 0..<12 {
            for x in 0..<12 {
                for z in 0..<12 where (x + z + y) % 5 != 0 { shape[Cell(x, y, z)] = red }
            }
        }
        let cache = SceneMeshCache(), definitionID = UUID()
        let key = MeshKey.definition(id: definitionID, version: UUID(), visibleSlots: [0])
        var sources = (0..<9).map { i in
            source(shape, key: key, at: VoxelTransform(axes: [1, 2, 3], offset: Cell(i % 3 * 19, 0, i / 3 * 19)),
                   index: i)
        }
        let initialCells = MeshSource.composite(sources)
        let placedCellCount = initialCells.count
        let initial = cache.resolve(sources, world: initialCells)
        XCTAssertEqual(cache.localBuildCount, 1)
        XCTAssertEqual(initial.draws.count, 9)
        XCTAssertTrue(initial.draws.allSatisfy { $0.mesh === initial.draws[0].mesh })
        var cachedMS = [Double](), fullMS = [Double]()
        for step in 1...3 {
            let moved = VoxelTransform(axes: [3, 2, -1], offset: Cell(0, step, 0))
            sources[0] = source(shape, key: key, at: moved, index: 0)
            let world = MeshSource.composite(sources)
            var t = CFAbsoluteTimeGetCurrent()
            let scene = cache.resolve(sources, world: world)
            cachedMS.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            t = CFAbsoluteTimeGetCurrent()
            let flat = RenderScene(draws: [MeshDraw(mesh: VoxelMesh(world), placement: .identity)])
            fullMS.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            XCTAssertEqual(scene.draws.count, 9)
            XCTAssertTrue(scene.draws.allSatisfy { $0.mesh === initial.draws[0].mesh })
            XCTAssertEqual(scene.ground.shadow, flat.ground.shadow)
            XCTAssertEqual(scene.ground.shadowOrigin, flat.ground.shadowOrigin)
            XCTAssertEqual(scene.ground.shadowSpan, flat.ground.shadowSpan)
            if step == 1 { XCTAssertEqual(faceMap(scene.worldFaces()), faceMap(flat.worldFaces())) }
        }
        XCTAssertEqual(cache.localBuildCount, 1)
        XCTAssertEqual(cache.compositeBuildCount, 0)
        shape[Cell(0, 0, 0)] = blue
        let edited = MeshKey.definition(id: definitionID, version: UUID(), visibleSlots: [0])
        sources = sources.enumerated().map { source(shape, key: edited, at: $0.element.transform, index: $0.offset) }
        let changed = cache.resolve(sources, world: MeshSource.composite(sources))
        XCTAssertEqual(cache.localBuildCount, 2)
        XCTAssertTrue(changed.draws.allSatisfy { $0.mesh === changed.draws[0].mesh })
        XCTAssertFalse(changed.draws[0].mesh === initial.draws[0].mesh)
        let cached = String(format: "%.1f", cachedMS.sorted()[1]), flat = String(format: "%.1f", fullMS.sorted()[1])
        print("Scene mesh timing (\(placedCellCount) placed cells, 9 instances): moved \(cached) ms, flat rebuild \(flat) ms")
    }

    func testMovingALanternAcrossTerrainRebuildsOnlyItsTwoChunks() {
        var terrain = [Cell: Ink]()
        for x in -32..<32 {
            for z in -32..<32 { terrain[Cell(x, 0, z)] = blue }
        }
        let ground = source(terrain, key: definition(), at: .identity, index: 0)
        let lightShape = [Cell(0, 0, 0): red, Cell(0, 1, 0): red, Cell(1, 2, 0): blue]
        let light = definition()
        func lantern(_ x: Int, _ z: Int, _ index: Int) -> MeshSource {
            source(lightShape, key: light, at: .init(axes: [1, 2, 3], offset: Cell(x, 1, z)), index: index)
        }
        var sources = [ground, lantern(-20, -20, 1), lantern(15, -8, 2), lantern(-16, 16, 3), lantern(20, 20, 4)]
        let cache = SceneMeshCache()
        var previous = cache.resolve(sources, world: MeshSource.composite(sources))
        XCTAssertEqual(cache.localBuildCount, 2)
        XCTAssertEqual(previous.draws.count, 16)
        var cachedMS = [Double](), flatMS = [Double]()
        for x in [-12, -20, -12] {
            sources[1] = lantern(x, -20, 1)
            let world = MeshSource.composite(sources)
            let priorBuilds = cache.compositeBuildCount
            var t = CFAbsoluteTimeGetCurrent()
            let moved = cache.resolve(sources, world: world)
            cachedMS.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            t = CFAbsoluteTimeGetCurrent()
            let flat = RenderScene(draws: [MeshDraw(mesh: VoxelMesh(world), placement: .identity)])
            flatMS.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
            let priorMeshes = Set(previous.draws.map { ObjectIdentifier($0.mesh) })
            XCTAssertEqual(moved.draws.filter { priorMeshes.contains(ObjectIdentifier($0.mesh)) }.count, 14)
            XCTAssertEqual(cache.compositeBuildCount - priorBuilds, 2)
            XCTAssertEqual(cache.localBuildCount, 2)
            XCTAssertEqual(faceMap(moved.worldFaces()), faceMap(flat.worldFaces()))
            XCTAssertEqual(moved.ground.shadow, flat.ground.shadow)
            previous = moved
        }
        let cached = String(format: "%.2f", cachedMS.sorted()[1]), flat = String(format: "%.2f", flatMS.sorted()[1])
        print("Grounded scene (4,096 terrain cells, four linked lanterns): rebuilt 2/16 chunks, moved \(cached) ms, flat rebuild \(flat) ms")
    }

    func testTouchingObjectsShareCompositeWhileRemoteObjectKeepsItsMesh() {
        let cache = SceneMeshCache(), key = definition()
        let shape = [Cell(0, 0, 0): red, Cell(1, 0, 0): blue]
        let first = source(shape, key: key, at: .identity, index: 0)
        let overlay = source([Cell(1, 0, 0): red, Cell(1, 1, 0): blue], key: definition(), at: .identity, index: 2)
        let far = source(shape, key: key, at: .init(axes: [1, 2, 3], offset: Cell(11, 0, 0)), index: 1)
        let sources = [first, overlay, far]
        let cells = MeshSource.composite(sources)
        let scene = cache.resolve(sources, world: cells)
        XCTAssertEqual(scene.draws.count, 2)
        XCTAssertEqual(cache.compositeBuildCount, 1)
        XCTAssertEqual(faceMap(scene.worldFaces()), faceMap(VoxelMesh(cells).faces))
        let moved = source(shape, key: key, at: .init(axes: [-1, 2, 3], offset: Cell(21, 0, 2)), index: 1)
        let later = [first, overlay, moved]
        let unchanged = cache.resolve(later, world: MeshSource.composite(later))
        XCTAssertEqual(cache.localBuildCount, 2)
        XCTAssertEqual(cache.compositeBuildCount, 1)
        XCTAssertTrue(zip(scene.draws, unchanged.draws).allSatisfy { $0.mesh === $1.mesh })
        let clipped = cells.filter { $0.key.y == 0 }
        XCTAssertEqual(faceMap(cache.clipped(clipped).worldFaces()), faceMap(VoxelMesh(clipped).faces))
    }
}
