import AppKit
import ImageIO
import XCTest
@testable import VoxelStudio

final class SliceExportTests: XCTestCase {
    func testWorkingInASlicePreservesUpperGeometryInModelFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorModel()
        model.newProject()
        let top = Cell(0, 7, 0), bottom = Cell(0, 0, 0)
        let red = Ink(hex: "DE5736"), blue = Ink(hex: "1470A2")
        model.ink = red
        model.apply(hit: nil, adjacent: top)
        model.sliceLevel = 2
        model.sliceEnabled = true
        model.ink = blue
        model.apply(hit: nil, adjacent: bottom)
        XCTAssertEqual(model.viewportCells, [bottom: blue])
        let expected = [bottom: blue, top: red]
        let native = folder.appendingPathComponent("Sliced.vxl")
        try model.saveProject(to: native)
        XCTAssertFalse(model.isDirty)
        model.sliceLevel = 1
        XCTAssertFalse(model.isDirty)
        let reopened = EditorModel()
        try reopened.loadProject(from: native)
        XCTAssertFalse(reopened.sliceEnabled)
        XCTAssertEqual(reopened.viewportCells, expected)

        let vox = folder.appendingPathComponent("Sliced.vox")
        try model.exportVOX(to: vox)
        XCTAssertEqual(try MagicaVoxel.decode(Data(contentsOf: vox)).layers.first?.cells, expected)
        let obj = folder.appendingPathComponent("Sliced.obj")
        try model.exportOBJ(to: obj)
        let mesh = try String(contentsOf: obj, encoding: .utf8)
        XCTAssertEqual(mesh.split(separator: "\n").filter { $0.hasPrefix("f ") }.count, 12)
        XCTAssertTrue(mesh.contains("usemtl cDE5736"))
    }

    @MainActor
    func testPNGReflectsTheCutAsSoonAsItChanges() async throws {
        let model = EditorModel()
        model.newProject()
        model.showGrid = false
        model.ink = Ink(hex: "FF1616")
        model.apply(hit: nil, adjacent: Cell(0, 5, 0))
        let camera = OrbitCamera()
        let surface = StudioViewportSurface(model: model, camera: camera)
        defer { withExtendedLifetime(surface) {} }
        surface.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        camera.reset()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }

        func countRedPixels() throws -> Int {
            try camera.exportPNG(to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: image.width * image.height * 4, by: 4).reduce(0) { count, i in
                count + (Int(pixels[i]) > 2 * Int(pixels[i + 1]) && Int(pixels[i]) > 2 * Int(pixels[i + 2]) ? 1 : 0)
            }
        }

        let initial = try countRedPixels()
        XCTAssertGreaterThan(initial, 50)
        model.sliceLevel = 2
        model.sliceEnabled = true
        XCTAssertEqual(try countRedPixels(), 0)
        model.sliceEnabled = false
        XCTAssertEqual(try countRedPixels(), initial)
    }
}
