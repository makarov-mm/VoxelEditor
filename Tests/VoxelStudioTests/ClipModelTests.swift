import Foundation
import XCTest
@testable import VoxelStudio

final class ClipModelTests: XCTestCase {
    private let blue = Ink(hex: "283E70")
    private var glass: Ink {
        var ink = Ink(0.1437911, 0.002, 1)
        ink.surface = VoxSurface(alpha: 93, properties: ["_type": "_glass", "_ior": "1.471", "finish": "etched"])
        return ink
    }

    private func empty() -> EditorModel {
        let model = EditorModel()
        model.newProject()
        return model
    }

    private func place(_ cells: [Cell: Ink], in model: EditorModel) {
        model.tool = .add
        for (cell, ink) in cells {
            model.ink = ink
            model.apply(hit: nil, adjacent: cell)
        }
    }

    func testRoundTripPreservesSparseOffsetsFloatChannelsAndMaterialMetadata() throws {
        let model = empty(), a = Cell(-128, 2, -127), b = Cell(127, 0, 126), c = Cell(127, 255, -128)
        place([a: blue, b: glass, c: blue], in: model)
        model.selectAllOnActiveLayer()
        let source = try XCTUnwrap(model.selectionFragment())
        let copied = try VoxelFragment.decode(source.encoded())
        XCTAssertEqual(copied.origin, Cell(-128, 0, -128))
        XCTAssertEqual(copied.size, Cell(256, 256, 255))
        XCTAssertEqual(copied.cells, [Cell(0, 2, 1): blue, Cell(255, 0, 254): glass, Cell(255, 255, 0): blue])
        XCTAssertEqual(copied.cells[Cell(255, 0, 254)]?.r.bitPattern, glass.r.bitPattern)
    }

    func testPaletteHasMoreThan256EntriesAndPreservesOriginalGeometryAfterCut() throws {
        let model = empty()
        var original: [Cell: Ink] = [:]
        for i in 0..<300 {
            original[Cell(i % 30, i / 30, 0)] = Ink(Float(i) / 300, 0.02, 0.03)
        }
        place(original, in: model)
        model.selectAllOnActiveLayer()
        let clipboard = try XCTUnwrap(model.selectionFragment()).encoded()
        XCTAssertTrue(model.deleteSelection())
        XCTAssertEqual(model.voxelCount, 0)
        let copied = try VoxelFragment.decode(clipboard)
        XCTAssertEqual(copied.cells, original)
        model.undo()
        XCTAssertEqual(model.visibleCells, original)
        XCTAssertEqual(model.selection, Set(original.keys))
        model.redo()
        XCTAssertTrue(model.visibleCells.isEmpty)
    }

    func testMalformedAndUnnormalizedFragmentsFailBeforePlacement() throws {
        let zero = Cell(0, 0, 0)
        let source = try XCTUnwrap(VoxelFragment(origin: zero, cells: [zero: blue, Cell(1, 0, 0): glass]))
        let bytes = try source.encoded()
        XCTAssertThrowsError(try VoxelFragment.decode(bytes.dropLast()))
        XCTAssertThrowsError(try VoxelFragment.decode(bytes + Data([0])))
        var unknown = bytes
        unknown[3] = 0x39
        XCTAssertThrowsError(try VoxelFragment.decode(unknown))
        var forgedSize = bytes
        forgedSize.replaceSubrange(7..<11, with: [255, 255, 255, 127])
        XCTAssertThrowsError(try VoxelFragment.decode(forgedSize))
        var duplicate = bytes
        duplicate.replaceSubrange(18..<21, with: bytes[11..<14])
        XCTAssertThrowsError(try VoxelFragment.decode(duplicate))
        var missingInk = bytes
        missingInk.replaceSubrange(14..<18, with: [2, 0, 0, 0])
        XCTAssertThrowsError(try VoxelFragment.decode(missingInk))
        var notFinite = bytes
        notFinite.replaceSubrange(29..<33, with: [0, 0, 128, 127])
        XCTAssertThrowsError(try VoxelFragment.decode(notFinite))
        XCTAssertNil(VoxelFragment(origin: zero, cells: [Cell(1, 0, 0): blue]))
        XCTAssertNil(VoxelFragment(origin: Cell(127, 0, 0), cells: [zero: blue, Cell(1, 0, 0): blue]))
        XCTAssertNil(VoxelFragment(origin: zero, cells: [zero: Ink(.nan, 0, 0)]))
        XCTAssertNil(VoxelFragment(origin: zero, cells: [:]))
    }

    func testPreviewPreservesSelectionAndIsExcludedFromNativeProject() throws {
        let model = empty(), source = Cell(1, 2, 3), anchor = Cell(8, 5, 7)
        place([source: glass], in: model)
        model.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(model.selectionFragment())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vxl")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.saveProject(to: url)
        let revision = model.revision
        XCTAssertTrue(model.beginPaste(fragment))
        XCTAssertFalse(model.pasteAllowed)
        model.updatePasteAnchor(anchor)
        XCTAssertTrue(model.pasteAllowed)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.revision, revision)
        try model.saveProject(to: url)
        let reopened = empty()
        try reopened.loadProject(from: url)
        XCTAssertEqual(reopened.visibleCells, [source: glass])
        XCTAssertNil(reopened.pendingPaste)
        model.cancelPaste()
        XCTAssertEqual(model.selection, [source])
        XCTAssertFalse(model.isDirty)
    }

    func testCutCanTransferLayerAtOriginalPositionAndUndoIndependently() throws {
        let model = empty(), a = Cell(-3, 0, 6), b = a.offset(1, 0, 1)
        place([a: blue, b: glass], in: model)
        let lower = model.activeLayerID
        model.addLayer()
        let upper = model.activeLayerID
        model.activeLayerID = lower
        model.selectAllOnActiveLayer()
        let fragment = try XCTUnwrap(model.selectionFragment())
        XCTAssertTrue(model.deleteSelection())
        XCTAssertTrue(model.selection.isEmpty)
        model.activeLayerID = upper
        XCTAssertTrue(model.beginPaste(fragment))
        XCTAssertTrue(model.pasteAllowed)
        XCTAssertEqual(model.pasteAnchor, a)
        XCTAssertTrue(model.commitPaste())
        XCTAssertEqual(model.selection, [a, b])
        XCTAssertEqual(model.layers.first?.cells, [:])
        XCTAssertEqual(model.layers.last?.cells, [a: blue, b: glass])
        model.undo()
        XCTAssertTrue(model.visibleCells.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        model.activeLayerID = lower
        model.undo()
        XCTAssertEqual(model.layers.first?.cells, [a: blue, b: glass])
        XCTAssertEqual(model.selection, [a, b])
        model.redo()
        model.activeLayerID = upper
        model.redo()
        XCTAssertEqual(model.layers.last?.cells, [a: blue, b: glass])
        XCTAssertEqual(model.selection, [a, b])
    }

    func testPasteRejectsOverlapAcrossVisibleLayersOutsideGridAndCutWithoutPartialWrites() throws {
        let model = empty(), occupied = Cell(1, 2, 1), anchor = Cell(0, 1, 1)
        place([occupied: blue], in: model)
        let lower = model.activeLayerID
        model.addLayer()
        let fragment = try XCTUnwrap(VoxelFragment(origin: anchor, cells: [Cell(0, 0, 0): blue, Cell(1, 1, 0): glass]))
        model.sliceLevel = 2
        model.sliceEnabled = true
        XCTAssertTrue(model.beginPaste(fragment))
        for blocked: Cell? in [anchor, Cell(5, 2, 1), Cell(127, 0, 0), Cell(Int.max, 0, 0), nil] {
            model.updatePasteAnchor(blocked)
            XCTAssertFalse(model.pasteAllowed)
            XCTAssertFalse(model.commitPaste())
            XCTAssertTrue(model.pendingPaste === fragment)
            XCTAssertTrue(model.layers.last!.cells.isEmpty)
        }
        model.toggleLayer(lower)
        XCTAssertNil(model.pendingPaste)
        XCTAssertTrue(model.beginPaste(fragment))
        XCTAssertTrue(model.commitPaste())
        XCTAssertEqual(model.layers.last?.cells, [anchor: blue, occupied: glass])
    }

    func testPasteInOtherProjectRestoresPreviousSelectionOnUndo() throws {
        let source = empty(), destination = empty(), a = Cell(-1, 0, -5), b = Cell(6, 2, 2)
        place([a: glass], in: source)
        source.selectAllOnActiveLayer()
        place([b: blue], in: destination)
        destination.selectAllOnActiveLayer()
        let fragment = try VoxelFragment.decode(try XCTUnwrap(source.selectionFragment()).encoded())
        XCTAssertTrue(destination.beginPaste(fragment))
        XCTAssertTrue(destination.commitPaste())
        XCTAssertEqual(destination.visibleCells, [a: glass, b: blue])
        XCTAssertEqual(destination.selection, [a])
        destination.undo()
        XCTAssertEqual(destination.selection, [b])
        XCTAssertEqual(destination.visibleCells, [b: blue])
        destination.redo()
        XCTAssertEqual(destination.selection, [a])
        XCTAssertEqual(destination.visibleCells[a], glass)
        XCTAssertEqual(source.visibleCells, [a: glass])
    }

    func testContextChangesCancelPendingPasteWithoutCreatingHistory() throws {
        let model = empty(), f = try XCTUnwrap(VoxelFragment(origin: Cell(0, 0, 0), cells: [Cell(0, 0, 0): glass]))
        XCTAssertTrue(model.beginPaste(f))
        model.tool = .paint
        XCTAssertNil(model.pendingPaste)
        XCTAssertTrue(model.beginPaste(f))
        model.sliceEnabled = true
        XCTAssertNil(model.pendingPaste)
        XCTAssertTrue(model.beginPaste(f))
        model.sliceLevel = 2
        XCTAssertNil(model.pendingPaste)
        XCTAssertTrue(model.beginPaste(f))
        model.undo()
        XCTAssertNil(model.pendingPaste)
        XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.beginPaste(f))
        model.newProject()
        XCTAssertNil(model.pendingPaste)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.beginPaste(f))
        model.addLayer()
        XCTAssertNil(model.pendingPaste)
        model.toggleLayer(model.activeLayerID)
        XCTAssertFalse(model.beginPaste(f))
    }
}
