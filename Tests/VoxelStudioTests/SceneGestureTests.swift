import AppKit
import XCTest
@testable import VoxelStudio

final class SceneGestureTests: XCTestCase {
    @MainActor
    private struct Canvas {
        let model = EditorModel()
        let camera = OrbitCamera()
        let view: StudioViewportSurface
        let start = CGPoint(x: 158, y: 166)

        init() {
            model.newProject()
            camera.orient("top")
            view = StudioViewportSurface(model: model, camera: camera)
            view.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        }

        func send(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1,
                                          pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: XCTFail("Unexpected pointer event")
            }
        }

        func click(_ p: CGPoint) {
            send(.leftMouseDown, at: p)
            send(.leftMouseUp, at: p)
        }

        func addCell(at p: CGPoint) throws -> Cell {
            model.tool = .add
            let before = Set(model.visibleCells.keys)
            click(p)
            return try XCTUnwrap(Set(model.visibleCells.keys).subtracting(before).first)
        }

        func extract(_ cell: Cell) throws -> SceneObject {
            model.tool = .select
            model.select([cell])
            XCTAssertTrue(model.createObjectFromSelection(name: "Beacon"))
            return try XCTUnwrap(model.activeSceneObject)
        }

        // Open a clean saved scene so History contains only the gestures under test.
        func reopen() throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
            defer { try? FileManager.default.removeItem(at: file) }
            try model.saveProject(to: file)
            try model.loadProject(from: file)
            XCTAssertFalse(model.canUndo)
        }

        func escape() {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            view.keyDown(with: key)
        }
    }

    @MainActor
    func testSceneClickPicksFrontLayerAndLooseLayerWithoutUsingTheBrush() async throws {
        let c = Canvas(), model = c.model
        let loose = model.activeLayerID
        let cell = try c.addCell(at: c.start)
        model.toggleLayer(loose)
        model.addLayer()
        model.apply(hit: nil, adjacent: cell)
        let object = try c.extract(cell)
        model.toggleLayer(loose)
        model.activeLayerID = loose
        model.tool = .erase
        c.view.objectMode = true
        var picks: [UUID] = []
        c.view.onScenePick = { picks.append($0) }

        let geometry = model.layers.map(\.cells)
        c.click(c.start)
        XCTAssertEqual(picks.last, object.layerIDs.first)
        XCTAssertEqual(model.activeSceneObject?.id, object.id)
        XCTAssertEqual(model.layers.map(\.cells), geometry)
        model.toggleLayer(object.layerIDs[0])
        c.click(c.start)
        XCTAssertEqual(picks.last, loose)
        XCTAssertEqual(model.activeLayerID, loose)
        XCTAssertNil(model.activeSceneObject)
        XCTAssertEqual(model.layers.map(\.cells), geometry)

        model.tool = .add
        c.click(CGPoint(x: 315, y: 230))
        XCTAssertEqual(model.layers.map(\.cells), geometry)
        c.view.objectMode = false
        model.tool = .erase
        c.click(c.start)
        XCTAssertNil(model.visibleCells[cell])
    }

    @MainActor
    func testDragCommitsAllMemberLayersOfOneLinkedInstanceAsOneUndo() async throws {
        let c = Canvas(), model = c.model
        let cell = try c.addCell(at: c.start)
        let first = try c.extract(cell)
        XCTAssertTrue(model.addObjectLayer(to: first.id))
        model.tool = .add
        let top = cell.offset(0, 1, 0)
        model.apply(hit: nil, adjacent: top)
        let topLayer = model.activeLayerID
        XCTAssertTrue(model.duplicateObject(first.id, linked: true))
        let peer = try XCTUnwrap(model.activeSceneObject)
        try c.reopen()
        model.tool = .paint
        c.view.objectMode = true

        let prior = model.sceneLayout, priorCells = model.layers.map(\.cells)
        let end = CGPoint(x: c.start.x - 64, y: c.start.y)
        c.send(.leftMouseDown, at: c.start)
        c.send(.leftMouseDragged, at: CGPoint(x: end.x + 16, y: end.y))
        c.send(.leftMouseDragged, at: end)
        XCTAssertEqual(model.activeLayerID, topLayer)
        XCTAssertEqual(model.sceneLayout, prior)
        XCTAssertEqual(model.layers.map(\.cells), priorCells)
        XCTAssertFalse(model.canUndo)
        c.send(.leftMouseUp, at: end)

        let moved = try XCTUnwrap(model.activeSceneObject)
        let dx = moved.transform.offset.x - first.transform.offset.x
        XCTAssertLessThan(dx, -1)
        XCTAssertEqual(moved.transform.offset, first.transform.offset.offset(dx, 0, 0))
        XCTAssertEqual(moved.definitionID, peer.definitionID)
        XCTAssertEqual(model.sceneLayout.objects.first { $0.id == peer.id }, peer)
        for (i, layer) in model.layers.enumerated() {
            let expected = moved.layerIDs.contains(layer.id)
                ? Dictionary(uniqueKeysWithValues: priorCells[i].map { ($0.key.offset(dx, 0, 0), $0.value) })
                : priorCells[i]
            XCTAssertEqual(layer.cells, expected)
        }
        let after = model.sceneLayout
        model.undo()
        XCTAssertEqual(model.sceneLayout, prior)
        XCTAssertEqual(model.layers.map(\.cells), priorCells)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.sceneLayout, after)
    }

    @MainActor
    func testCollisionEscapeAndSwitchingToEditDiscardTheObjectPreview() async throws {
        let c = Canvas(), model = c.model
        let wall = CGPoint(x: 238, y: c.start.y)
        let wallCell = try c.addCell(at: wall)
        for dx in [-1, 1] { model.apply(hit: nil, adjacent: wallCell.offset(dx, 0, 0)) }
        let cell = try c.addCell(at: c.start)
        _ = try c.extract(cell)
        try c.reopen()
        model.tool = .erase
        c.view.objectMode = true
        let before = model.sceneLayout, cells = model.visibleCells
        let open = CGPoint(x: 110, y: c.start.y)

        c.send(.leftMouseDown, at: c.start)
        c.send(.leftMouseDragged, at: wall)
        c.send(.leftMouseUp, at: wall)
        XCTAssertEqual(model.sceneLayout, before)
        XCTAssertFalse(model.canUndo)

        c.send(.leftMouseDown, at: c.start)
        c.send(.leftMouseDragged, at: open)
        c.escape()
        c.send(.leftMouseUp, at: open)
        XCTAssertEqual(model.sceneLayout, before)
        XCTAssertFalse(model.canUndo)

        c.send(.leftMouseDown, at: c.start)
        c.send(.leftMouseDragged, at: open)
        c.view.objectMode = false
        c.send(.leftMouseUp, at: open)
        XCTAssertEqual(model.sceneLayout, before)
        XCTAssertEqual(model.visibleCells, cells)
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testContextChangesDiscardHeldObjectMoveEvenWhenToolOrLayerIsRestored() async throws {
        enum Change: CaseIterable { case tool, layer, framing, zoom, resize }
        for change in Change.allCases {
            let c = Canvas(), model = c.model
            let loose = model.activeLayerID
            let cell = try c.addCell(at: c.start)
            let object = try c.extract(cell)
            try c.reopen()
            c.view.objectMode = true
            let prior = model.sceneLayout
            let end = CGPoint(x: c.start.x + 80, y: c.start.y)
            c.send(.leftMouseDown, at: c.start)
            c.send(.leftMouseDragged, at: end)
            XCTAssertTrue(c.view.hasObjectGesture)
            switch change {
            case .tool:
                let initial = model.tool
                model.tool = .erase
                model.tool = initial
            case .layer:
                model.activeLayerID = loose
                model.activeLayerID = object.layerIDs[0]
            case .framing:
                c.camera.orient("right")
            case .zoom:
                c.camera.zoomIn()
            case .resize:
                c.view.setFrameSize(CGSize(width: 420, height: 330))
            }
            c.send(.leftMouseUp, at: end)
            XCTAssertFalse(c.view.hasObjectGesture, "\(change)")
            XCTAssertEqual(model.sceneLayout, prior, "\(change)")
            XCTAssertFalse(model.canUndo, "\(change)")
        }
    }
}
