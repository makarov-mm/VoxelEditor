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
        XCTAssertTrue(scene.layout.objects.isEmpty)
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
        XCTAssertEqual(scene.layout.objects.count, 2)
        let a = scene.layout.objects[0], b = scene.layout.objects[1]
        XCTAssertEqual(a.definitionID, b.definitionID)
        XCTAssertEqual(a.transform.unapply(Cell(11, 4, -7)), b.transform.unapply(Cell(6, 1, -4)))
        let saved = try MagicaVoxel.encode(layers: scene.layers, palette: scene.palette, layout: scene.layout)
        let reopened = try MagicaVoxel.decode(saved)
        XCTAssertEqual(reopened.layout, scene.layout)
        XCTAssertEqual(reopened.layers.map(\.cells), scene.layers.map(\.cells))
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
        XCTAssertTrue(scene.layout.objects.isEmpty)
        XCTAssertTrue(scene.layout.groups.isEmpty)
    }

    func testSharedMultiLayerObjectsAndGroupOrderSurviveNativeGraphExport() throws {
        let ink = Ink(hex: "B85C42")
        var glass = Ink(hex: "84BBC2")
        glass.surface = VoxSurface(alpha: 90, properties: ["_type": "_glass"])
        let local = Cell(2, 3, -1)
        let poses = [VoxelTransform.identity, VoxelTransform(axes: [-3, 2, 1], offset: Cell(11, 2, 5))]
        let lower = SceneGroup(name: "Lantern room")
        let upper = SceneGroup(name: "Island")
        var room = lower
        room.parentID = upper.id
        let definition = UUID(), partID = UUID()
        var objects: [SceneObject] = []
        var layers: [VoxelLayer] = []
        for (index, pose) in poses.enumerated() {
            let body = VoxelLayer(name: "Body", cells: [pose.apply(local): ink, pose.apply(local.offset(1, 0, 0)): ink])
            let pane = VoxelLayer(name: "Pane", isVisible: index == 0, isLocked: true,
                                  cells: [pose.apply(local.offset(0, 1, 0)): glass])
            layers += [body, pane]
            objects.append(SceneObject(name: "Lamp \(index + 1)", groupID: index == 0 ? upper.id : room.id,
                                       definitionID: definition, layerIDs: [body.id, pane.id], transform: pose,
                                       libraryPartID: partID))
        }
        let loose = VoxelLayer(name: "Loose", cells: [Cell(0, 0, 0): ink])
        layers = [layers[3], loose, layers[0], layers[2], layers[1]]
        let layout = SceneLayout(objects: objects, groups: [room, upper])
        let bytes = try MagicaVoxel.encode(layers: layers, palette: [glass, ink], layout: layout)

        // Inspect native chunks without relying on this codec's interpretation of Forma attributes.
        func int(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
        }
        var offset = 20, models = 0, referencedModels: [Int] = []
        while offset < bytes.count {
            let tag = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = int(offset + 4)
            if tag == "SIZE" { models += 1 }
            if tag == "nSHP" {
                // One model per shape. The last two ints are its model index and an empty frame dictionary.
                referencedModels.append(int(offset + 12 + size - 8))
            }
            offset += 12 + size + int(offset + 8)
        }
        XCTAssertEqual(models, 3)
        XCTAssertEqual(Dictionary(grouping: referencedModels, by: { $0 }).values.map(\.count).sorted(), [1, 2, 2])
        let result = try MagicaVoxel.decode(bytes)
        XCTAssertEqual(result.layout, layout)
        XCTAssertEqual(result.layers.map(\.id), layers.map(\.id))
        XCTAssertEqual(result.layers.map(\.cells), layers.map(\.cells))
        XCTAssertEqual(result.layers.map(\.isLocked), layers.map(\.isLocked))
        XCTAssertEqual(result.layers.map(\.isVisible), layers.map(\.isVisible))

        layers[0].cells.removeAll()
        XCTAssertThrowsError(try MagicaVoxel.encode(layers: layers, palette: [], layout: layout))
    }

    func testNestedNativeGroupsPreserveRebasedObjectTransforms() throws {
        var chunks = geometry(1, 1, 1, [0, 0, 0, 7])
        func group(_ id: Int32, _ children: [Int32]) -> Data {
            chunk("nGRP", i32(id) + dictionary([:]) + i32(Int32(children.count)) + children.map(i32).reduce(Data(), +))
        }
        chunks += [trn(0, child: 1, layer: -1, attrs: ["_name": "Harbor"], frames: [["_t": "3000 0 -40"]]),
                   group(1, [2, 4]), trn(2, child: 3, layer: -1, attrs: ["_name": "Pier"], frames: [["_r": "17"]]),
                   group(3, [6]), trn(6, child: 7, layer: -1, attrs: ["_name": "East"], frames: [["_t": "1 3 6"]]),
                   trn(4, child: 7, layer: -1, attrs: ["_name": "West"], frames: [["_t": "1 2 0"]]),
                   chunk("nSHP", i32(7) + dictionary([:]) + i32(1) + i32(0) + dictionary([:]))]
        let scene = try MagicaVoxel.decode(file(chunks))
        let root = try XCTUnwrap(scene.layout.groups.first { $0.name == "Harbor" })
        let pier = try XCTUnwrap(scene.layout.groups.first { $0.name == "Pier" })
        XCTAssertEqual(pier.parentID, root.id)
        XCTAssertEqual(scene.layout.objects.map(\.groupID), [pier.id, root.id])
        let a = scene.layout.objects[0], b = scene.layout.objects[1]
        XCTAssertEqual(a.definitionID, b.definitionID)
        let pointA = try XCTUnwrap(scene.layers[0].cells.keys.first)
        let pointB = try XCTUnwrap(scene.layers[1].cells.keys.first)
        XCTAssertEqual(a.transform.unapply(pointA), b.transform.unapply(pointB))
        XCTAssertNotNil(scene.origin)
        let data = try MagicaVoxel.encode(layers: scene.layers, palette: scene.palette, origin: scene.origin, layout: scene.layout)
        let copy = try MagicaVoxel.decode(data)
        XCTAssertEqual(copy.layers.map(\.cells), scene.layers.map(\.cells))
        XCTAssertEqual(copy.origin, scene.origin)
        XCTAssertEqual(copy.layout, scene.layout)
    }

    func testExternalSharedGroupBecomesOneMultiLayerDefinition() throws {
        var chunks = geometry(1, 1, 1, [0, 0, 0, 2]) + geometry(1, 1, 1, [0, 0, 0, 3])
        chunks += [trn(0, child: 1, layer: -1, frames: [[:]]),
                   chunk("nGRP", i32(1) + dictionary([:]) + i32(2) + i32(2) + i32(3)),
                   trn(2, child: 4, layer: -1, attrs: ["_name": "First"], frames: [["_t": "-4 0 0"]]),
                   trn(3, child: 4, layer: -1, attrs: ["_name": "Second"], frames: [["_r": "17", "_t": "5 1 1"]]),
                   chunk("nGRP", i32(4) + dictionary([:]) + i32(2) + i32(5) + i32(7)),
                   trn(5, child: 6, layer: -1, attrs: ["_name": "Base"], frames: [[:]]),
                   chunk("nSHP", i32(6) + dictionary([:]) + i32(1) + i32(0) + dictionary([:])),
                   trn(7, child: 8, layer: -1, attrs: ["_name": "Lamp"], frames: [["_t": "1 0 2"]]),
                   chunk("nSHP", i32(8) + dictionary([:]) + i32(1) + i32(1) + dictionary([:]))]
        let scene = try MagicaVoxel.decode(file(chunks))
        XCTAssertEqual(scene.layout.objects.map(\.name), ["First", "Second"])
        XCTAssertEqual(scene.layers.map(\.name), ["Base", "Lamp", "Base", "Lamp"])
        let a = scene.layout.objects[0], b = scene.layout.objects[1]
        XCTAssertEqual(a.definitionID, b.definitionID)
        XCTAssertEqual(a.layerIDs, Array(scene.layers.map(\.id)[0..<2]))
        XCTAssertEqual(b.layerIDs, Array(scene.layers.map(\.id)[2..<4]))
        for index in 0..<2 {
            let first = try XCTUnwrap(scene.layers[index].cells.keys.first)
            let second = try XCTUnwrap(scene.layers[index + 2].cells.keys.first)
            XCTAssertEqual(a.transform.unapply(first), b.transform.unapply(second))
        }
        let copy = try MagicaVoxel.decode(MagicaVoxel.encode(layers: scene.layers, palette: [], layout: scene.layout))
        XCTAssertEqual(copy.layout, scene.layout)
        XCTAssertEqual(copy.layers.map(\.cells), scene.layers.map(\.cells))
    }

    func testSigned32BitWorldOriginCanSpanMultipleNativeTransforms() throws {
        // Native node translations are signed 32-bit. Their composed world transform can be larger.
        var chunks = geometry(1, 1, 1, [0, 0, 0, 1])
        chunks += [trn(0, child: 1, layer: -1, frames: [["_t": "2147483647 0 0"]]),
                   trn(1, child: 2, layer: -1, frames: [["_t": "99 0 0"]]),
                   chunk("nSHP", i32(2) + dictionary([:]) + i32(1) + i32(0) + dictionary([:]))]
        let scene = try MagicaVoxel.decode(file(chunks))
        let bytes = try MagicaVoxel.encode(layers: scene.layers, palette: [], origin: scene.origin, layout: scene.layout)
        let copy = try MagicaVoxel.decode(bytes)
        XCTAssertEqual(copy.origin, scene.origin)
        XCTAssertEqual(copy.layout, scene.layout)
        XCTAssertEqual(copy.layers.map(\.cells), scene.layers.map(\.cells))
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

    func testPastedMaterialSurvivesNativeSaveAndMagicaVoxelExport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Lantern.vox")
        var chunks = geometry(2, 1, 1, [0, 0, 0, 1, 1, 0, 0, 2])
        chunks.append(chunk("RGBA", Data([64, 145, 178, 98, 64, 145, 178, 255]) + Data(repeating: 0, count: 1016)))
        chunks.append(chunk("MATL", i32(1) + dictionary(["_type": "_glass", "_ior": "1.5"])))
        try file(chunks).write(to: source)
        let original = EditorModel()
        try original.importVOX(from: source)
        original.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(original.selectionFragment())
        let bytes = try fragment.encoded()

        let destination = EditorModel()
        destination.newProject()
        let anchor = Cell(5, 7, -3)
        XCTAssertTrue(destination.beginPaste(try VoxelFragment.decode(bytes)))
        destination.updatePasteAnchor(anchor)
        XCTAssertTrue(destination.commitPaste())
        let matching = try XCTUnwrap(destination.visibleCells[anchor])
        XCTAssertEqual(matching.surface, VoxSurface(alpha: 98, properties: ["_type": "_glass", "_ior": "1.5"]))
        XCTAssertEqual(destination.visibleCells[anchor.offset(1, 0, 0)]?.hex, matching.hex)
        XCTAssertNotEqual(destination.visibleCells[anchor.offset(1, 0, 0)], matching)

        let native = folder.appendingPathComponent("Transferred.vxl")
        try destination.saveProject(to: native)
        let reopened = EditorModel()
        try reopened.loadProject(from: native)
        XCTAssertEqual(reopened.visibleCells, destination.visibleCells)
        let exported = folder.appendingPathComponent("Transferred.vox")
        try reopened.exportVOX(to: exported)
        let scene = try MagicaVoxel.decode(Data(contentsOf: exported))
        XCTAssertEqual(scene.layers.first?.cells, destination.visibleCells)
        XCTAssertEqual(original.visibleCells.count, 2)
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
