import AppKit
import ImageIO
import XCTest
@testable import VoxelStudio

final class SceneExportTests: XCTestCase {
    @MainActor
    private func exportedImage(_ camera: OrbitCamera, keeping surface: StudioViewportSurface) throws -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try withExtendedLifetime(surface) { try camera.exportPNG(to: url) }
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @MainActor
    func testExportUsesViewportDimensionsAndCapsLongSide() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 125, height: 75)
        let normal = try exportedImage(camera, keeping: surface)
        XCTAssertEqual(normal.width, 250)
        XCTAssertEqual(normal.height, 150)
        surface.setFrameSize(CGSize(width: 3000, height: 750))
        let capped = try exportedImage(camera, keeping: surface)
        XCTAssertEqual(capped.width, 4096)
        XCTAssertEqual(capped.height, 1024)
    }

    @MainActor
    private func exportedPixels(_ camera: OrbitCamera, surface: StudioViewportSurface) throws -> Data {
        let image = try exportedImage(camera, keeping: surface)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
    }

    @MainActor
    func testExportOmitsSelectionAndImmediatelyReflectsLayerVisibility() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 240, height: 160)

        let cell = Cell(0, 0, 0)
        model.ink = Ink(hex: "E02020")
        model.apply(hit: nil, adjacent: cell)
        camera.reset()
        let base = try exportedPixels(camera, surface: surface)

        model.tool = .select
        model.select([cell])
        XCTAssertEqual(model.selection, [cell])
        XCTAssertEqual(try exportedPixels(camera, surface: surface), base)

        model.addLayer()
        model.tool = .add
        model.ink = Ink(hex: "23E038")
        model.apply(hit: nil, adjacent: Cell(2, 0, 0))
        XCTAssertNotEqual(try exportedPixels(camera, surface: surface), base)
        model.toggleLayer(model.activeLayerID)
        XCTAssertEqual(try exportedPixels(camera, surface: surface), base)
    }

    @MainActor
    func testPastePreviewIsExcludedFromPNGUntilPlacement() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        model.apply(hit: nil, adjacent: Cell(0, 0, 0))
        model.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(model.selectionFragment())
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 150)
        camera.reset()
        let initial = try exportedPixels(camera, surface: surface)
        XCTAssertTrue(model.beginPaste(fragment))
        XCTAssertFalse(model.pasteAllowed)
        XCTAssertEqual(try exportedPixels(camera, surface: surface), initial)
        model.updatePasteAnchor(Cell(2, 0, 1))
        XCTAssertTrue(model.pasteAllowed)
        XCTAssertEqual(try exportedPixels(camera, surface: surface), initial)
        XCTAssertTrue(model.commitPaste())
        XCTAssertNotEqual(try exportedPixels(camera, surface: surface), initial)
        model.undo()
        XCTAssertEqual(try exportedPixels(camera, surface: surface), initial)
    }

    @MainActor
    func testFramingPreservesTheChosenViewAndFitsTheGeometry() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        XCTAssertTrue(model.addShape(tool: .box, from: Cell(24, 0, 0), to: Cell(34, 2, 5)))
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 180, height: 120)
        for view in ["front", "right", "top"] {
            camera.orient(view)
            let framed = try exportedPixels(camera, surface: surface)
            camera.zoomIn()
            XCTAssertNotEqual(try exportedPixels(camera, surface: surface), framed)
            camera.frameScene()
            XCTAssertEqual(camera.viewKey, view)
            XCTAssertEqual(camera.zoomPercent, 100)
            XCTAssertEqual(try exportedPixels(camera, surface: surface), framed)
        }
    }

    @MainActor
    func testEmptyViewportPreservesExistingDestination() async throws {
        let camera = OrbitCamera()
        let surface = StudioViewportSurface(model: EditorModel(), camera: camera)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = Data("original file".utf8)
        try previous.write(to: url)
        XCTAssertThrowsError(try withExtendedLifetime(surface) { try camera.exportPNG(to: url) })
        XCTAssertEqual(try Data(contentsOf: url), previous)
    }
}
