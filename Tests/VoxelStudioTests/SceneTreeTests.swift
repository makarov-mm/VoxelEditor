import XCTest
@testable import VoxelStudio

final class SceneTreeTests: XCTestCase {
    private let root = SceneGroup(name: "Lighthouse")
    private let other = SceneGroup(name: "Shore")

    func testCollapsedGroupsAndOwnedLayers() {
        let child = SceneGroup(name: "Lantern room", parentID: root.id)
        let spare = VoxelLayer(name: "Ground")
        let objectLayer = VoxelLayer(name: "Paint")
        let object = SceneObject(name: "Lens", groupID: child.id, layerIDs: [objectLayer.id])
        let scene = SceneLayout(objects: [object], groups: [root, other, child])
        let layers = [spare, objectLayer]

        let rows = SceneTreeRow.rows(layout: scene, layers: layers)
        XCTAssertEqual(rows.map(\.id), [.group(root.id), .group(child.id), .object(object.id),
                                        .group(other.id), .layer(spare.id)])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0, 0])
        XCTAssertEqual(SceneTreeRow.rows(layout: scene, layers: layers, collapsed: [root.id]).map(\.id),
                       [.group(root.id), .group(other.id), .layer(spare.id)])
    }

    func testParentMenuExcludesWholeSubtreeButKeepsAncestorsAndSiblings() {
        let lantern = SceneGroup(name: "Lantern", parentID: root.id)
        let lens = SceneGroup(name: "Lens", parentID: lantern.id)
        let door = SceneGroup(name: "Door", parentID: root.id)
        let scene = SceneLayout(groups: [root, other, lantern, lens, door])
        XCTAssertEqual(SceneTreeRow.possibleParents(layout: scene, moving: root.id).map(\.id),
                       [.group(other.id)])
        XCTAssertEqual(SceneTreeRow.possibleParents(layout: scene, moving: lantern.id).map(\.id),
                       [.group(root.id), .group(door.id), .group(other.id)])
    }
}
