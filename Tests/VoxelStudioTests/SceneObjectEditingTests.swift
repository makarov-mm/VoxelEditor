import XCTest
@testable import VoxelStudio

final class SceneObjectEditingTests: XCTestCase {
    private func newObject(at point: Cell) throws -> (EditorModel, SceneObject) {
        let model = EditorModel()
        model.newProject()
        model.apply(hit: nil, adjacent: point)
        model.tool = .select
        model.select([point])
        XCTAssertTrue(model.createObjectFromSelection(name: "Light"))
        return (model, try XCTUnwrap(model.activeSceneObject))
    }

    func testSharedEditRejectsLockedCollidingAndOutOfBoundsPeersAtomically() throws {
        let (model, source) = try newObject(at: Cell(0, 0, 0))
        XCTAssertTrue(model.duplicateObject(source.id, linked: true))
        let peer = try XCTUnwrap(model.activeSceneObject)
        XCTAssertTrue(model.moveObject(peer.id, by: Cell(126, 0, 0)))
        model.selectObject(source.id)
        model.tool = .add
        model.apply(hit: nil, adjacent: Cell(1, 0, 0))
        XCTAssertEqual(model.voxelCount, 2)
        model.toggleLayerLock(peer.layerIDs[0])
        model.tool = .erase
        model.apply(hit: Cell(0, 0, 0), adjacent: nil)
        XCTAssertEqual(model.voxelCount, 2)
        model.toggleLayerLock(peer.layerIDs[0])
        let loose = try XCTUnwrap(model.layers.first)
        model.activeLayerID = loose.id
        model.tool = .add
        model.apply(hit: nil, adjacent: Cell(127, 1, 0))
        model.selectObject(source.id)
        model.apply(hit: nil, adjacent: Cell(0, 1, 0))
        XCTAssertEqual(model.voxelCount, 3)
        model.apply(hit: nil, adjacent: Cell(0, 0, 2))
        XCTAssertEqual(model.voxelCount, 5)
        model.undo()
        XCTAssertEqual(model.voxelCount, 3)
        model.redo()
        XCTAssertEqual(model.voxelCount, 5)
    }

    func testMemberLayerChangesAcrossInstancesAndUndoOfLastPlacement() throws {
        let (model, first) = try newObject(at: Cell(4, 2, 0))
        XCTAssertTrue(model.duplicateObject(first.id, linked: true))
        let second = try XCTUnwrap(model.activeSceneObject)
        XCTAssertTrue(model.addObjectLayer(to: second.id))
        XCTAssertEqual(model.sceneLayout.objects.map { $0.layerIDs.count }, [2, 2])
        model.tool = .add
        model.apply(hit: nil, adjacent: Cell(5, 3, 0))
        XCTAssertEqual(model.voxelCount, 4)
        model.removeActiveLayer()
        XCTAssertEqual(model.sceneLayout.objects.map { $0.layerIDs.count }, [1, 1])
        XCTAssertEqual(model.voxelCount, 2)
        model.undo()
        XCTAssertEqual(model.voxelCount, 4)
        model.undo()
        model.undo()
        XCTAssertEqual(model.sceneLayout.objects.map { $0.layerIDs.count }, [1, 1])
        model.selectObject(second.id)
        model.removeActiveLayer()
        XCTAssertEqual(model.sceneLayout.objects.map(\.id), [first.id])
        model.undo()
        XCTAssertEqual(model.sceneLayout.objects.map(\.id), [first.id, second.id])
    }

    func testUngroupDeleteAndIndependentDuplicateRetainGeometryAndUndo() throws {
        let (model, source) = try newObject(at: Cell(-8, 1, 5))
        let harbor = try XCTUnwrap(model.createGroup(name: "Harbor"))
        let lamps = try XCTUnwrap(model.createGroup(name: "Lights", parentID: harbor))
        let east = try XCTUnwrap(model.createGroup(name: "East", parentID: lamps))
        XCTAssertTrue(model.setObjectGroup(source.id, to: lamps))
        XCTAssertTrue(model.duplicateObject(source.id, linked: false))
        let copy = try XCTUnwrap(model.activeSceneObject)
        XCTAssertNotEqual(copy.definitionID, source.definitionID)
        let before = model.sceneLayout
        XCTAssertTrue(model.ungroup(lamps))
        XCTAssertEqual(model.sceneLayout.groups.first { $0.id == east }?.parentID, harbor)
        XCTAssertTrue(model.sceneLayout.objects.allSatisfy { $0.groupID == harbor })
        model.undo()
        XCTAssertEqual(model.sceneLayout, before)
        model.redo()
        XCTAssertTrue(model.removeObject(copy.id))
        XCTAssertEqual(model.visibleCells.count, 1)
        XCTAssertEqual(model.sceneLayout.objects.map(\.id), [source.id])
        model.undo()
        XCTAssertEqual(model.visibleCells.count, 2)
        XCTAssertEqual(model.activeSceneObject?.id, copy.id)
        model.toggleLayerLock(copy.layerIDs[0])
        XCTAssertFalse(model.removeObject(copy.id))
    }

    func testInvalidGroupAndTransformInFilePreserveOpenScene() throws {
        let (model, obj) = try newObject(at: Cell(3, 2, -5))
        let a = try XCTUnwrap(model.createGroup(name: "Harbor"))
        let b = try XCTUnwrap(model.createGroup(name: "Lights", parentID: a))
        XCTAssertTrue(model.setObjectGroup(obj.id, to: b))
        XCTAssertFalse(model.setGroupParent(a, to: b))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let original = model.sceneLayout
        for corruptGroup in [true, false] {
            var broken = project
            var layout = try XCTUnwrap(broken["layout"] as? [String: Any])
            if corruptGroup {
                var groups = try XCTUnwrap(layout["groups"] as? [[String: Any]])
                groups[0]["parentID"] = b.uuidString
                layout["groups"] = groups
            } else {
                var objects = try XCTUnwrap(layout["objects"] as? [[String: Any]])
                var pose = try XCTUnwrap(objects[0]["transform"] as? [String: Any])
                pose["axes"] = [3, 3, -1]
                objects[0]["transform"] = pose
                layout["objects"] = objects
            }
            broken["layout"] = layout
            try JSONSerialization.data(withJSONObject: broken).write(to: url)
            XCTAssertThrowsError(try model.loadProject(from: url, confirmReplacement: { XCTFail("Invalid file prompted"); return true }))
            XCTAssertEqual(model.sceneLayout, original)
        }
    }
}
