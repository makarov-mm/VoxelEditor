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
    func testExportOmitsSelectionAndImmediatelyReflectsLayerVisibility() async throws {
        let model = EditorModel(), camera = OrbitCamera()
        model.newProject()
        let surface = StudioViewportSurface(model: model, camera: camera)
        surface.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        func exportedPixels() throws -> Data {
            let image = try exportedImage(camera, keeping: surface)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
        }

        let cell = Cell(0, 0, 0)
        model.ink = Ink(hex: "E02020")
        model.apply(hit: nil, adjacent: cell)
        camera.reset()
        let base = try exportedPixels()

        model.tool = .select
        model.select([cell])
        XCTAssertEqual(model.selection, [cell])
        XCTAssertEqual(try exportedPixels(), base)

        model.addLayer()
        model.tool = .add
        model.ink = Ink(hex: "23E038")
        model.apply(hit: nil, adjacent: Cell(2, 0, 0))
        XCTAssertNotEqual(try exportedPixels(), base)
        model.toggleLayer(model.activeLayerID)
        XCTAssertEqual(try exportedPixels(), base)
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
