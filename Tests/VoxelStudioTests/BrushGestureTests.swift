import AppKit
import XCTest
@testable import VoxelStudio

final class BrushGestureTests: XCTestCase {
    @MainActor
    private struct Canvas {
        let model = EditorModel()
        let surface: StudioViewportSurface

        init() {
            model.newProject()
            let camera = OrbitCamera()
            camera.orient("top")
            surface = StudioViewportSurface(model: model, camera: camera)
            surface.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        }

        func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) {
            let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
                                          clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: surface.mouseDown(with: event)
            case .leftMouseDragged: surface.mouseDragged(with: event)
            case .leftMouseUp: surface.mouseUp(with: event)
            default: XCTFail("Unexpected mouse event")
            }
        }
    }

    @MainActor
    func testReleaseAddsLastSegmentToTheSameUndoStep() async throws {
        let canvas = Canvas()
        canvas.send(.leftMouseDown, 158, 166)
        canvas.send(.leftMouseDragged, 200, 166)
        let beforeRelease = canvas.model.voxelCount
        canvas.send(.leftMouseUp, 243, 166)
        let cells = Set(canvas.model.visibleCells.keys)
        let click = Canvas()
        click.send(.leftMouseDown, 243, 166)
        click.send(.leftMouseUp, 243, 166)
        XCTAssertEqual(click.model.voxelCount, 1)
        XCTAssertTrue(cells.contains(try XCTUnwrap(click.model.visibleCells.keys.first)))
        XCTAssertGreaterThan(cells.count, beforeRelease)
        let positions = cells.map(\.x).sorted()
        XCTAssertEqual(positions, Array(try XCTUnwrap(positions.first)...XCTUnwrap(positions.last)))
        canvas.model.undo()
        XCTAssertEqual(canvas.model.voxelCount, 0)
        XCTAssertFalse(canvas.model.canUndo)
        canvas.model.redo()
        XCTAssertEqual(Set(canvas.model.visibleCells.keys), cells)
    }

    @MainActor
    func testDragOutsideAndBackPaintsOnlyVisiblePortions() async {
        let canvas = Canvas(), expected = Canvas()
        expected.send(.leftMouseDown, 188, 166)
        expected.send(.leftMouseUp, 399.99, 166)
        canvas.send(.leftMouseDown, 188, 166)
        canvas.send(.leftMouseDragged, 550, 166)
        XCTAssertGreaterThan(expected.model.voxelCount, 1)
        XCTAssertEqual(canvas.model.visibleCells, expected.model.visibleCells)
        canvas.send(.leftMouseDragged, 550, 214)
        XCTAssertEqual(canvas.model.visibleCells, expected.model.visibleCells)

        expected.send(.leftMouseDown, 399.99, 214)
        expected.send(.leftMouseUp, 346, 214)
        canvas.send(.leftMouseDragged, 363, 214)
        canvas.send(.leftMouseUp, 346, 214)
        XCTAssertEqual(canvas.model.visibleCells, expected.model.visibleCells)
        canvas.model.undo()
        XCTAssertEqual(canvas.model.voxelCount, 0)
        XCTAssertFalse(canvas.model.canUndo)
    }

    @MainActor
    func testContextChangesFinishHeldStrokeBeforeAnotherMouseEvent() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
        defer { try? FileManager.default.removeItem(at: file) }
        for context in ["tool", "layer", "slice", "reload", "undo"] {
            let canvas = Canvas()
            canvas.send(.leftMouseDown, 158, 166)
            XCTAssertEqual(canvas.model.voxelCount, 1)
            switch context {
            case "tool":
                canvas.model.tool = .erase
                canvas.model.tool = .add
            case "layer":
                canvas.model.addLayer()
            case "slice":
                canvas.model.sliceEnabled = true
                canvas.model.sliceEnabled = false
            case "reload":
                try canvas.model.saveProject(to: file)
                try canvas.model.loadProject(from: file)
            default:
                canvas.model.undo()
            }
            let expected = canvas.model.visibleCells
            canvas.send(.leftMouseDragged, 200, 166)
            canvas.send(.leftMouseUp, 243, 166)
            XCTAssertEqual(canvas.model.visibleCells, expected, context)
        }
    }
}
