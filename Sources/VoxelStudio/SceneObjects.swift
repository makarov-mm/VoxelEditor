import Foundation

/// A signed axis permutation maps integer cell centers from definition space into the scene.
struct VoxelTransform: Equatable, Codable {
    var axes: [Int]
    var offset: Cell
    static let identity = Self(axes: [1, 2, 3], offset: Cell(0, 0, 0))

    var isValid: Bool {
        guard axes.count == 3, axes.allSatisfy({ (-3...3).contains($0) && $0 != 0 }),
              Set(axes.map { abs($0) }).count == 3, offset.isSceneCoordinate else { return false }
        // VOX files may contain reflected placements as well as rotations.
        return true
    }

    private func direction(_ cell: Cell) -> Cell {
        let components = SIMD3(cell.x, cell.y, cell.z)
        func component(_ axis: Int) -> Int { (axis > 0 ? 1 : -1) * components[abs(axis) - 1] }
        return Cell(component(axes[0]), component(axes[1]), component(axes[2]))
    }

    func apply(_ cell: Cell) -> Cell { direction(cell).offset(offset) }

    func unapply(_ cell: Cell) -> Cell {
        let values = SIMD3(cell.x - offset.x, cell.y - offset.y, cell.z - offset.z)
        var out = SIMD3<Int>.zero
        for (row, axis) in axes.enumerated() { out[abs(axis) - 1] = axis > 0 ? values[row] : -values[row] }
        return Cell(out[0], out[1], out[2])
    }

    func followed(by outer: Self) -> Self {
        let next = outer.axes.map { axis in (axis > 0 ? 1 : -1) * axes[abs(axis) - 1] }
        return Self(axes: next, offset: outer.apply(offset))
    }

    static func quarterTurn(around axis: VoxelAxis, pivot: Cell) -> Self {
        let rows: [Int]
        switch axis { case .x: rows = [1, -3, 2]; case .y: rows = [3, 2, -1]; case .z: rows = [-2, 1, 3] }
        var turn = Self(axes: rows, offset: .init(0, 0, 0))
        let p = turn.direction(pivot)
        turn.offset = pivot.offset(-p.x, -p.y, -p.z)
        return turn
    }
}

extension Cell {
    static let transformOffsetLimit = 1_000_000

    func fitsCoordinateLimit(_ limit: Int) -> Bool {
        (-limit...limit).contains(x) && (-limit...limit).contains(y) && (-limit...limit).contains(z)
    }

    var isSceneCoordinate: Bool { fitsCoordinateLimit(Self.transformOffsetLimit) }
}

struct SceneObject: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var groupID: UUID? = nil
    var definitionID = UUID()
    var layerIDs: [UUID]
    var transform: VoxelTransform = .identity
    var libraryPartID: UUID? = nil
}

struct SceneGroup: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var parentID: UUID? = nil
}

struct SceneLayout: Equatable, Codable {
    var objects: [SceneObject] = []
    var groups: [SceneGroup] = []

    func isValid(layerIDs: Set<UUID>) -> Bool {
        let groupIDs = Set(groups.map(\.id))
        let members = objects.flatMap(\.layerIDs)
        let objectIDs = Set(objects.map(\.id))
        guard groups.count <= 4096, groupIDs.count == groups.count, groupIDs.isDisjoint(with: objectIDs),
              objectIDs.count == objects.count, Set(members).count == members.count,
              Set(members).isSubset(of: layerIDs) else { return false }
        let parents = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.parentID) })
        for group in groups {
            guard !group.name.isEmpty else { return false }
            var seen = Set<UUID>(), current: UUID? = group.id
            while let id = current {
                guard seen.insert(id).inserted, let parent = parents[id] else { return false }
                current = parent
            }
        }
        var counts: [UUID: Int] = [:]
        for object in objects {
            guard !object.name.isEmpty, !object.layerIDs.isEmpty, object.transform.isValid,
                  object.groupID.map(groupIDs.contains) ?? true else { return false }
            if let count = counts[object.definitionID], count != object.layerIDs.count { return false }
            counts[object.definitionID] = object.layerIDs.count
        }
        return true
    }
}
