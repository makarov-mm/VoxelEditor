import AppKit
import XCTest
@testable import VoxelStudio

final class ConnectedSelectionTests: XCTestCase {
    @MainActor
    func testDoubleClickSelectsFaceConnectedVoxelsAcrossColors() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        camera.orient("top")
        let view = StudioViewportSurface(model: model, camera: camera)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        func click(_ count: Int) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 160),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                    clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
                if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
            }
        }
        try click(1)
        let seed = try XCTUnwrap(model.visibleCells.keys.first)
        let next = seed.offset(1, 0, 0)
        model.ink = Ink(hex: "2299FF")
        for cell in [next, next.offset(1, 0, 1)] { model.apply(hit: nil, adjacent: cell) }
        model.tool = .select
        let revision = model.revision
        try click(1)
        XCTAssertEqual(model.selection, [seed])
        try click(2)
        XCTAssertEqual(model.selection, [seed, next])
        XCTAssertEqual(model.revision, revision)
    }

    func testSliceAndOverlappingLayerCanBreakAConnection() {
        let model = EditorModel()
        model.newProject()
        let origin = Cell(0, 0, 0), bridge = origin.offset(1, 0, 0), end = origin.offset(2, 0, 0)
        for cell in [origin, bridge, end, origin.offset(0, 1, 0)] { model.apply(hit: nil, adjacent: cell) }
        let lower = model.activeLayerID
        model.toggleLayer(lower)
        model.addLayer()
        model.apply(hit: nil, adjacent: bridge)
        model.toggleLayer(lower)
        model.activeLayerID = lower
        model.sliceEnabled = true
        model.sliceLevel = 0
        model.tool = .select
        model.selectConnected(at: origin)
        XCTAssertEqual(model.selection, [origin])
        model.toggleLayer(model.layers[1].id)
        model.selectConnected(at: end)
        XCTAssertEqual(model.selection, [origin, bridge, end])
    }
}
