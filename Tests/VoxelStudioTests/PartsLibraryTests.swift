import AppKit
import XCTest
@testable import VoxelStudio

final class PartsLibraryTests: XCTestCase {
    private func part() throws -> VoxelFragment {
        var glass = Ink(hex: "54BDA6")
        glass.surface = VoxSurface(alpha: 127, properties: ["_type": "_glass"])
        return try XCTUnwrap(VoxelFragment(origin: Cell(-2, 0, 4),
                                            cells: [Cell(0, 0, 0): glass, Cell(1, 1, 0): Ink(hex: "EC5034")]))
    }

    func testNamedPartThumbnailAndMaterialsSurviveRestartAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PartsLibrary(directory: folder)
        let original = try part()
        XCTAssertThrowsError(try store.save(original, name: "  "))
        let saved = try store.save(original, name: "  Beacon / lamp  ")
        let reopened = PartsLibrary(directory: folder)
        try reopened.reload()
        XCTAssertEqual(reopened.parts.map(\.name), ["Beacon / lamp"])
        XCTAssertEqual(reopened.parts.first?.count, 2)
        let item = try XCTUnwrap(reopened.parts.first)
        let loaded = try reopened.fragment(for: item)
        XCTAssertEqual(loaded.cells, original.cells)
        XCTAssertEqual(loaded.size, original.size)
        let image = try XCTUnwrap(reopened.thumbnail(for: item))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide, 160)
        var red = false, green = false
        for y in stride(from: 0, to: 160, by: 4) {
            for x in stride(from: 0, to: 160, by: 4) {
                guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), ink.alphaComponent > 0.9 else { continue }
                if ink.redComponent > 2 * ink.greenComponent { red = true }
                if ink.greenComponent > 1.5 * ink.redComponent { green = true }
            }
        }
        XCTAssertTrue(red && green)
        try reopened.remove(saved)
        try store.reload()
        XCTAssertTrue(store.parts.isEmpty)
    }

    func testStampRevalidatesCollisionsAndEachUndoRedoWhileOrdinaryPasteStaysSingleUse() throws {
        let stamp = try part(), model = EditorModel()
        model.newProject()
        XCTAssertTrue(model.beginPaste(stamp, stampName: "Lamp"))
        XCTAssertNil(model.pasteAnchor)
        let a = Cell(4, 0, 4), b = Cell(9, 0, 4)
        model.updatePasteAnchor(a)
        XCTAssertTrue(model.commitPaste())
        XCTAssertTrue(model.pendingPaste === stamp)
        XCTAssertFalse(model.pasteAllowed)
        XCTAssertFalse(model.commitPaste())
        model.updatePasteAnchor(b)
        XCTAssertTrue(model.commitPaste())
        XCTAssertEqual(model.voxelCount, 4)
        model.undo()
        XCTAssertTrue(model.pasteAllowed)
        XCTAssertTrue(model.pendingPaste === stamp)
        XCTAssertEqual(model.voxelCount, 2)
        model.redo()
        XCTAssertFalse(model.pasteAllowed)
        XCTAssertEqual(model.voxelCount, 4)
        model.cancelPaste()
        XCTAssertNil(model.stampName)
        XCTAssertTrue(model.beginPaste(stamp))
        XCTAssertTrue(model.commitPaste())
        XCTAssertNil(model.pendingPaste)
        XCTAssertEqual(model.voxelCount, 6)
    }

    @MainActor
    func testCanvasPlacesMultipleCopiesAndEscapeFinishes() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        camera.orient("top")
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 400, height: 320)
        let stamp = try part()
        XCTAssertTrue(model.beginPaste(stamp, stampName: "Lamp"))
        for x: CGFloat in [150, 235] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 160),
                                                             modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                if type == .leftMouseDown { surface.mouseDown(with: event) } else { surface.mouseUp(with: event) }
            }
        }
        XCTAssertEqual(model.voxelCount, 4)
        surface.cancelOperation(nil)
        XCTAssertNil(model.pendingPaste)
        XCTAssertEqual(model.voxelCount, 4)
    }
}
