import Foundation
import XCTest
@testable import VoxelStudio

final class MagicaVoxelTests: XCTestCase {
    // These fixture bytes are assembled independently of the production encoder.
    private func i32(_ n: Int32) -> Data {
        let u = UInt32(bitPattern: n)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: u >> ($0 * 8)) })
    }

    private func dictionary(_ pairs: [String: String]) -> Data {
        var data = i32(Int32(pairs.count))
        for key in pairs.keys.sorted() {
            for text in [key, pairs[key]!] {
                data += i32(Int32(text.utf8.count)) + Data(text.utf8)
            }
        }
        return data
    }

    private func chunk(_ tag: String, _ data: Data) -> Data {
        Data(tag.utf8) + i32(Int32(data.count)) + i32(0) + data
    }

    private func file(_ chunks: [Data], version: Int32 = 150) -> Data {
        let children = chunks.reduce(Data(), +)
        return Data("VOX ".utf8) + i32(version) + Data("MAIN".utf8) + i32(0) + i32(Int32(children.count)) + children
    }

    private func geometry(_ x: Int32, _ y: Int32, _ z: Int32, _ voxels: [UInt8]) -> [Data] {
        [chunk("SIZE", i32(x) + i32(y) + i32(z)), chunk("XYZI", i32(Int32(voxels.count / 4)) + Data(voxels))]
    }

    private func trn(_ id: Int32, child: Int32, layer: Int32, attrs: [String: String] = [:], frames: [[String: String]]) -> Data {
        let header = i32(id) + dictionary(attrs) + i32(child) + i32(-1) + i32(layer)
        return chunk("nTRN", header + i32(Int32(frames.count)) + frames.map(dictionary).reduce(Data(), +))
    }

    func testDefaultPaletteAndFull256CellExtent() throws {
        let model = geometry(256, 1, 256, [0, 0, 0, 2, 255, 0, 255, 255])
        let scene = try MagicaVoxel.decode(file(model))
        XCTAssertEqual(scene.palette.count, 255)
        XCTAssertEqual(scene.layers.first?.cells[Cell(-128, 0, -1)]?.hex, "#FFFFCC")
        XCTAssertEqual(scene.layers.first?.cells[Cell(127, 255, -1)]?.hex, "#111111")
    }

    func testGraphRotationHierarchyFrameSelectionPaletteAndHiddenLayer() throws {
        var chunks = geometry(3, 2, 1, [2, 0, 0, 1])
        chunks += [
            trn(0, child: 1, layer: -1, frames: [["_t": "7 4 1"]]),
            chunk("nGRP", i32(1) + dictionary([:]) + i32(2) + i32(2) + i32(4)),
            trn(2, child: 3, layer: 0, attrs: ["_name": "Rotated"],
                frames: [["_f": "3", "_t": "99 99 99"], ["_f": "0", "_r": "17", "_t": "4 1 3"]]),
            chunk("nSHP", i32(3) + dictionary([:]) + i32(1) + i32(0) + dictionary([:])),
            trn(4, child: 3, layer: 1, frames: [["_t": "-2 0 0"]]),
            chunk("LAYR", i32(1) + dictionary(["_name": "Hidden", "_hidden": "1"]) + i32(-1)),
            chunk("RGBA", Data([11, 22, 33, 144]) + Data(repeating: 0, count: 1020)),
            chunk("MATL", i32(1) + dictionary(["_type": "_glass", "_ior": "1.44"])),
            chunk("rOBJ", dictionary(["_type": "_render"]))
        ]
        let scene = try MagicaVoxel.decode(file(chunks, version: 200))
        XCTAssertEqual(scene.layers.map(\.name), ["Rotated", "Hidden"])
        XCTAssertEqual(scene.layers.map(\.isVisible), [true, false])
        let ink = try XCTUnwrap(scene.layers[0].cells[Cell(11, 4, -7)])
        XCTAssertEqual(ink.hex, "#0B1621")
        XCTAssertEqual(ink.surface, VoxSurface(alpha: 144, properties: ["_type": "_glass", "_ior": "1.44"]))
        XCTAssertEqual(scene.layers[1].cells[Cell(6, 1, -4)], ink)
    }

    func testExportRetainsLayerOrderOverlapMaterialsAndEmptyLayers() throws {
        let p = Cell(-128, 0, 127), q = Cell(127, 255, -128)
        let red = Ink(hex: "FF0000")
        var glass = red
        glass.surface = VoxSurface(alpha: 128, properties: ["_type": "_glass"])
        let original = [
            VoxelLayer(name: "Solid", cells: [p: red, q: glass]),
            VoxelLayer(name: "Glass overlap", isVisible: false, cells: [p: glass]),
            VoxelLayer(name: "Empty")
        ]
        let bytes = try MagicaVoxel.encode(layers: original, palette: [glass, red])
        XCTAssertEqual(bytes.prefix(4), Data("VOX ".utf8))
        let scene = try MagicaVoxel.decode(bytes)
        XCTAssertEqual(scene.layers.map(\.cells), original.map(\.cells))
        XCTAssertEqual(scene.layers.map(\.name), original.map(\.name))
        XCTAssertEqual(scene.layers.map(\.isVisible), original.map(\.isVisible))
        XCTAssertTrue(scene.palette.contains(glass))
    }

    func testMalformedFilesAndUnrepresentableScenesThrow() throws {
        let data = file(geometry(2, 1, 1, [1, 0, 0, 4]))
        for n in 0..<data.count {
            XCTAssertThrowsError(try MagicaVoxel.decode(Data(data.prefix(n))))
        }
        XCTAssertThrowsError(try MagicaVoxel.decode(file(geometry(1, 1, 1, [1, 0, 0, 1]))))
        let cyclic = geometry(1, 1, 1, [0, 0, 0, 1]) + [
            trn(0, child: 0, layer: -1, frames: [[:]])
        ]
        XCTAssertThrowsError(try MagicaVoxel.decode(file(cyclic)))
        let wide = geometry(1, 1, 1, [0, 0, 0, 1]) + [
            trn(0, child: 2, layer: -1, frames: [[:]]),
            trn(1, child: 2, layer: -1, frames: [["_t": "256 0 0"]]),
            chunk("nSHP", i32(2) + dictionary([:]) + i32(1) + i32(0) + dictionary([:]))
        ]
        XCTAssertThrowsError(try MagicaVoxel.decode(file(wide)))
        var cells: [Cell: Ink] = [:]
        for i in 0..<256 { cells[Cell(i - 128, 0, 0)] = Ink(Float(i) / 255, 0, 0) }
        XCTAssertThrowsError(try MagicaVoxel.encode(layers: [VoxelLayer(name: "256 colors", cells: cells)], palette: []))
    }

    func testWorldOffsetSurvivesNativeSaveAndReexport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let chunks = geometry(1, 1, 1, [0, 0, 0, 9]) + [
            trn(0, child: 1, layer: -1, frames: [["_t": "3000 -700 -55"]]),
            chunk("nSHP", i32(1) + dictionary([:]) + i32(1) + i32(0) + dictionary([:]))
        ]
        let imported = try MagicaVoxel.decode(file(chunks))
        let cell = try XCTUnwrap(imported.layers.first?.cells.keys.first)
        let delta = try XCTUnwrap(imported.origin)
        XCTAssertEqual(cell.offset(delta.x, delta.y, delta.z), Cell(3000, -55, 699))
        let source = folder.appendingPathComponent("Outside.vox")
        try file(chunks).write(to: source)
        let native = folder.appendingPathComponent("Offset.vxl")
        let model = EditorModel()
        try model.importVOX(from: source)
        try model.saveProject(to: native)
        let copy = EditorModel()
        try copy.loadProject(from: native)
        let output = folder.appendingPathComponent("Roundtrip.vox")
        try copy.exportVOX(to: output)
        let again = try MagicaVoxel.decode(Data(contentsOf: output))
        XCTAssertEqual(again.origin, imported.origin)
        XCTAssertEqual(again.layers.first?.cells, imported.layers.first?.cells)

        var project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: native)) as? [String: Any])
        project["voxOrigin"] = ["x": Int.max, "y": 0, "z": 0]
        try JSONSerialization.data(withJSONObject: project).write(to: native)
        XCTAssertThrowsError(try copy.loadProject(from: native))
    }

    func testImportedFileCanBeEditedAndSavedWithoutOverwritingSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Fixture.vox")
        let data = file(geometry(1, 1, 1, [0, 0, 0, 1]))
        try data.write(to: source)
        let model = EditorModel()
        try model.importVOX(from: source)
        XCTAssertTrue(model.isDirty)
        XCTAssertThrowsError(try model.saveProject(to: source))
        let p = try XCTUnwrap(model.visibleCells.keys.first)
        model.tool = .paint
        model.ink = Ink(hex: "AABBCC")
        model.apply(hit: p, adjacent: nil)
        let native = folder.appendingPathComponent("Edited.vxl")
        try model.saveProject(to: native)
        let copy = EditorModel()
        try copy.loadProject(from: native)
        XCTAssertEqual(copy.visibleCells[p]?.hex, "#AABBCC")
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
}
