import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct Cell: Hashable, Codable {
    var x, y, z: Int

    init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let gridSize = 256
    static let horizontalRange = -128...127
    static let verticalRange = 0...255

    var inBounds: Bool {
        Self.horizontalRange.contains(x) && Self.verticalRange.contains(y) && Self.horizontalRange.contains(z)
    }

    func offset(_ dx: Int, _ dy: Int, _ dz: Int) -> Cell {
        Cell(x + dx, y + dy, z + dz)
    }
}

struct Ink: Hashable, Codable {
    var r, g, b: Float
    var surface: VoxSurface?

    init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: String) {
        let rgb = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(Float((rgb >> 16) & 255) / 255, Float((rgb >> 8) & 255) / 255, Float(rgb & 255) / 255)
    }

    var rgb24: UInt32 {
        func byte(_ value: Float) -> UInt32 {
            value.isFinite ? UInt32((min(1, max(0, value)) * 255).rounded()) : 0
        }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    var hex: String { String(format: "#%06X", rgb24) }

    var color: Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b))
    }

    var isValid: Bool {
        [r, g, b].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum EditTool: String, CaseIterable {
    case add, paint, erase, pick, select, line, rectangle, box, cylinder, extrude, fill
}

enum SelectionMode {
    case replace, add, toggle
}

struct BrushBox: Equatable {
    var min, max: Cell
}

struct VoxelLayer: Identifiable {
    var id = UUID()
    var name: String
    var isVisible = true
    var isLocked = false
    var cells: [Cell: Ink] = [:]
}

private enum ProjectError: LocalizedError {
    case invalidProject, unsupportedVersion, tooLarge, emptyExport, nativeExtension

    var errorDescription: String? {
        switch self {
        case .nativeExtension:
            return "Save the native project as .vxl or use Export VOX for a MagicaVoxel file."
        case .invalidProject: return "This file contains invalid project data."
        case .unsupportedVersion: return "This project requires a different version of Forma."
        case .tooLarge: return "This project exceeds the supported size."
        case .emptyExport: return "Show a layer containing voxels before exporting the model."
        }
    }
}

private struct ProjectFile: Codable {
    static let currentVersion = 1

    struct Voxel: Codable {
        var cell: Cell
        var ink: Ink
    }

    struct Layer: Codable {
        var id: UUID
        var name: String
        var isVisible: Bool
        var isLocked: Bool?
        var voxels: [Voxel]
    }

    var version: Int
    var title: String
    var palette: [Ink]
    var activeLayerID: UUID
    var layers: [Layer]
    var voxOrigin: Cell? = nil

    func validatedLayers() throws -> [VoxelLayer] {
        guard version == Self.currentVersion else { throw ProjectError.unsupportedVersion }
        guard MagicaVoxel.validOrigin(voxOrigin), !layers.isEmpty, layers.count <= EditorModel.layerLimit,
              layers.contains(where: { $0.id == activeLayerID }),
              Set(layers.map(\.id)).count == layers.count, !title.isEmpty,
              !palette.isEmpty, palette.count <= EditorModel.paletteLimit,
              palette.allSatisfy(\.isValid) else { throw ProjectError.invalidProject }

        return try layers.map { source in
            guard !source.name.isEmpty, source.voxels.count <= Cell.gridSize * Cell.gridSize * Cell.gridSize else {
                throw ProjectError.invalidProject
            }
            var cells: [Cell: Ink] = [:]
            cells.reserveCapacity(source.voxels.count)
            for voxel in source.voxels {
                guard voxel.cell.inBounds, voxel.ink.isValid,
                      cells.updateValue(voxel.ink, forKey: voxel.cell) == nil else {
                    throw ProjectError.invalidProject
                }
            }
            return VoxelLayer(id: source.id, name: source.name, isVisible: source.isVisible,
                              isLocked: source.isLocked ?? false, cells: cells)
        }
    }
}

final class EditorModel: ObservableObject {
    static let layerLimit = 128
    static let paletteLimit = 256
    static let maxShapeCells = 262_144

    static let defaultPalette = [
        "E96555", "BF5045", "F5BD62", "F4E6CA",
        "D8BB84", "CCBDA1", "926D50", "314552",
        "A4AE76", "C1C797", "6E916F", "4F7467",
        "538F8D", "82BCBA", "D4EBDA", "697B82"
    ].map { Ink(hex: $0) }

    @Published private(set) var layers: [VoxelLayer] {
        didSet {
            cancelPaste()
            merged = nil
            clipped = nil
            revision &+= 1
        }
    }
    @Published var activeLayerID: UUID {
        didSet {
            if oldValue != activeLayerID {
                endStroke()
                clearSelection()
                if isolatedLayerID != nil { isolatedLayerID = nil }
            }
        }
    }
    @Published private(set) var isolatedLayerID: UUID? {
        didSet {
            if oldValue != isolatedLayerID { workingViewDidChange() }
        }
    }
    @Published var tool: EditTool = .add {
        didSet {
            if oldValue != tool {
                endStroke()
                clearSelection()
            }
        }
    }
    @Published var mirrorX = false
    @Published var mirrorZ = false
    @Published private(set) var selection: Set<Cell> = []
    @Published private(set) var pendingPaste: VoxelFragment?
    @Published private(set) var pasteAnchor: Cell?
    @Published private(set) var pasteAllowed = false
    @Published var ink = Ink(hex: "E96555")
    @Published var showGrid = true
    @Published var showEdges = false
    @Published var brushSize = 1
    @Published var shapeDepth = 1
    @Published var sliceEnabled = false {
        didSet { if oldValue != sliceEnabled { workingViewDidChange() } }
    }
    @Published var sliceLevel = 0 {
        didSet {
            let clamped = min(Cell.verticalRange.upperBound, max(Cell.verticalRange.lowerBound, sliceLevel))
            if sliceLevel != clamped { sliceLevel = clamped }
            if oldValue != sliceLevel && sliceEnabled { workingViewDidChange() }
        }
    }
    @Published private(set) var title = "Northern Lighthouse"
    @Published private(set) var isDirty = false
    @Published private(set) var palette = EditorModel.defaultPalette
    @Published private(set) var revision = 0
    @Published private(set) var projectID = UUID()

    private var merged: [Cell: Ink]?
    private var clipped: [Cell: Ink]?
    private var projectURL: URL?
    private var voxOrigin: Cell?
    private var currentState = UUID()
    private var savedState: UUID
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var stroke: Stroke?

    private struct Delta {
        var before: Ink?
        var after: Ink?
    }

    private struct Stroke {
        var layer: UUID
        var changes: [Cell: Delta] = [:]
    }

    private enum Change {
        case voxels(UUID, [Cell: Delta], selectionBefore: Set<Cell>? = nil, selectionAfter: Set<Cell>? = nil)
        case uniform(UUID, Set<Cell>, before: Ink?, after: Ink)
        case move(layer: UUID, source: Set<Cell>, delta: Cell)
        case layer(VoxelLayer, index: Int, inserted: Bool, oldActive: UUID, newActive: UUID)
        case visibility(UUID, Bool)
        case lock(UUID, Bool)
        case name(UUID, before: String, after: String)
        case palette(Ink)
    }

    private struct Entry {
        var change: Change
        var before, after: UUID
    }

    init() {
        let initial = DemoScene.layers()
        layers = initial
        activeLayerID = initial.last!.id
        savedState = currentState
    }

    var visibleCells: [Cell: Ink] {
        if let merged { return merged }
        var result: [Cell: Ink] = [:]
        for layer in layers where layer.isVisible {
            result.merge(layer.cells) { _, upper in upper }
        }
        merged = result
        return result
    }

    private var editingCells: [Cell: Ink] {
        if let isolatedLayerID { return layers.first { $0.id == isolatedLayerID }?.cells ?? [:] }
        return visibleCells
    }

    func isLayerShownInEditor(_ layer: VoxelLayer) -> Bool {
        if let isolatedLayerID { return isolatedLayerID == layer.id }
        return layer.isVisible
    }

    var viewportCells: [Cell: Ink] {
        guard sliceEnabled else { return editingCells }
        if let clipped { return clipped }
        let result = editingCells.filter { $0.key.y <= sliceLevel }
        clipped = result
        return result
    }

    func isEditableHeight(_ y: Int) -> Bool {
        Cell.verticalRange.contains(y) && (!sliceEnabled || y <= sliceLevel)
    }

    private func workingViewDidChange() {
        cancelPaste()
        endStroke()
        clipped = nil
        pruneSelection()
        revision &+= 1
    }

    var voxelCount: Int { visibleCells.count }
    var hasActiveStroke: Bool { stroke != nil }
    var canUndo: Bool { !undoStack.isEmpty || stroke?.changes.isEmpty == false }
    var canRedo: Bool { !redoStack.isEmpty && stroke?.changes.isEmpty != false }

    func beginStroke() {
        cancelPaste()
        endStroke()
        stroke = Stroke(layer: activeLayerID)
    }

    func endStroke() {
        guard let finished = stroke else { return }
        stroke = nil
        let changes = finished.changes.filter { $0.value.before != $0.value.after }
        if !changes.isEmpty {
            record(.voxels(finished.layer, changes))
        } else {
            isDirty = currentState != savedState
        }
    }

    func brushBounds(hit: Cell?, adjacent: Cell?) -> (min: Cell, max: Cell)? {
        guard [.add, .paint, .erase, .pick].contains(tool), let center = tool == .add ? adjacent : hit,
              center.inBounds, isEditableHeight(center.y) else { return nil }
        if tool == .pick { return (center, center) }

        let size = min(8, max(1, brushSize))
        let low = -(size - 1) / 2
        // Placement grows outwards along the face normal; other axes center on the target.
        func extents(_ coordinate: Int, normal: Int, limits: ClosedRange<Int>) -> ClosedRange<Int> {
            var first = coordinate + low
            if tool == .add && normal > 0 { first = coordinate }
            if tool == .add && normal < 0 { first = coordinate - size + 1 }
            return max(limits.lowerBound, first)...min(limits.upperBound, first + size - 1)
        }

        let x = extents(center.x, normal: hit.map { center.x - $0.x } ?? 0, limits: Cell.horizontalRange)
        let ceiling = sliceEnabled ? sliceLevel : Cell.verticalRange.upperBound
        let y = extents(center.y, normal: hit.map { center.y - $0.y } ?? 1, limits: 0...ceiling)
        let z = extents(center.z, normal: hit.map { center.z - $0.z } ?? 0, limits: Cell.horizontalRange)
        return (Cell(x.lowerBound, y.lowerBound, z.lowerBound), Cell(x.upperBound, y.upperBound, z.upperBound))
    }

    func brushBoxes(hit: Cell?, adjacent: Cell?) -> [BrushBox] {
        guard let base = brushBounds(hit: hit, adjacent: adjacent) else { return [] }
        if tool == .pick { return [BrushBox(min: base.min, max: base.max)] }

        func intervals(_ start: Int, _ end: Int, mirrored: Bool) -> [ClosedRange<Int>] {
            let original = start...end
            guard mirrored else { return [original] }
            let reflection = (-end - 1)...(-start - 1)
            let (left, right) = start <= reflection.lowerBound ? (original, reflection) : (reflection, original)
            if left.upperBound + 1 < right.lowerBound { return [left, right] }
            return [left.lowerBound...max(left.upperBound, right.upperBound)]
        }

        let xs = intervals(base.min.x, base.max.x, mirrored: mirrorX)
        let zs = intervals(base.min.z, base.max.z, mirrored: mirrorZ)
        return xs.flatMap { x in
            zs.map { z in
                BrushBox(min: Cell(x.lowerBound, base.min.y, z.lowerBound),
                         max: Cell(x.upperBound, base.max.y, z.upperBound))
            }
        }
    }

    func apply(hit: Cell?, adjacent: Cell?) {
        guard [.add, .paint, .erase, .pick].contains(tool) else { return }
        if tool == .pick {
            if let hit, isEditableHeight(hit.y), let color = editingCells[hit] { ink = color }
            return
        }
        let boxes = brushBoxes(hit: hit, adjacent: adjacent)
        guard !boxes.isEmpty, let index = visibleActiveLayerIndex else { return }

        if let activeStroke = stroke, activeStroke.layer != activeLayerID { endStroke() }
        let singleClick = stroke == nil
        if singleClick { beginStroke() }
        defer { if singleClick { endStroke() } }

        let visible = editingCells
        var edits: [Cell: Delta] = [:]
        for bounds in boxes {
            for x in bounds.min.x...bounds.max.x {
                for y in bounds.min.y...bounds.max.y {
                    for z in bounds.min.z...bounds.max.z {
                        let cell = Cell(x, y, z)
                        let previous = layers[index].cells[cell]
                        if tool == .add {
                            guard visible[cell] == nil else { continue }
                        } else {
                            guard ownsVisibleCell(cell, in: index) else { continue }
                        }
                        let next: Ink? = tool == .erase ? nil : ink
                        if previous != next { edits[cell] = Delta(before: previous, after: next) }
                    }
                }
            }
        }
        guard !edits.isEmpty else { return }
        for (cell, change) in edits {
            if stroke?.changes[cell] != nil {
                stroke?.changes[cell]?.after = change.after
            } else {
                stroke?.changes[cell] = change
            }
        }
        write(edits, in: &layers[index].cells, forward: true)
        isDirty = true
    }

    private var visibleActiveLayerIndex: Int? {
        layers.firstIndex { $0.id == activeLayerID && !$0.isLocked && isLayerShownInEditor($0) }
    }

    var editableActiveLayer: VoxelLayer? {
        visibleActiveLayerIndex.map { layers[$0] }
    }

    private func ownsVisibleCell(_ cell: Cell, in index: Int) -> Bool {
        isEditableHeight(cell.y) && layers[index].cells[cell] != nil && !layers.dropFirst(index + 1).contains {
            isLayerShownInEditor($0) && $0.cells[cell] != nil
        }
    }

    func clearSelection() {
        cancelPaste()
        if !selection.isEmpty { selection = [] }
    }

    func select(_ cells: Set<Cell>, mode: SelectionMode = .replace) {
        guard pendingPaste == nil else { return }
        guard tool == .select, let index = visibleActiveLayerIndex else {
            clearSelection()
            return
        }
        let eligible = cells.filter { ownsVisibleCell($0, in: index) }
        let result: Set<Cell>
        switch mode {
        case .replace: result = eligible
        case .add: result = selection.union(eligible)
        case .toggle: result = selection.symmetricDifference(eligible)
        }
        if result != selection { selection = result }
    }

    func selectAllOnActiveLayer() {
        cancelPaste()
        tool = .select
        guard let index = visibleActiveLayerIndex else {
            clearSelection()
            return
        }
        selectEditableCells(in: index) { _ in true }
    }

    func selectConnected(at seed: Cell) {
        guard pendingPaste == nil, tool == .select, let index = visibleActiveLayerIndex,
              ownsVisibleCell(seed, in: index) else { return }
        var connected: Set<Cell> = [seed]
        var pending = [seed]
        while let cell = pending.popLast() {
            for direction in Cell.neighbors {
                let next = cell.offset(direction)
                if !connected.contains(next), ownsVisibleCell(next, in: index) {
                    connected.insert(next)
                    pending.append(next)
                }
            }
        }
        if selection != connected { selection = connected }
    }

    @discardableResult
    func selectByColor() -> Bool {
        guard pendingPaste == nil, let index = visibleActiveLayerIndex else { return false }
        tool = .select
        let color = ink.rgb24
        selectEditableCells(in: index) { $0.rgb24 == color }
        return !selection.isEmpty
    }

    private func selectEditableCells(in index: Int, matching matches: (Ink) -> Bool) {
        var visible = Set<Cell>()
        for (cell, ink) in layers[index].cells where isEditableHeight(cell.y) && matches(ink) {
            visible.insert(cell)
        }
        for layer in layers.dropFirst(index + 1) where isLayerShownInEditor(layer) {
            if visible.isEmpty { break }
            visible.subtract(layer.cells.keys)
        }
        if visible != selection { selection = visible }
    }

    @discardableResult
    func recolorSelection() -> Bool {
        guard pendingPaste == nil, tool == .select, !selection.isEmpty,
              let index = visibleActiveLayerIndex, ink.isValid else { return false }
        let color = ink.rgb24
        var changes: [Cell: Delta] = [:]
        for cell in selection {
            guard ownsVisibleCell(cell, in: index), let old = layers[index].cells[cell] else { return false }
            if old.rgb24 == color { continue }
            var replacement = ink
            replacement.surface = old.surface
            changes[cell] = Delta(before: old, after: replacement)
        }
        return commit(changes, in: index, selecting: selection)
    }

    private func pruneSelection() {
        if !selection.isEmpty { select(selection) }
    }

    func canMoveSelection(by delta: Cell) -> Bool {
        let span = (1 - Cell.gridSize)..<Cell.gridSize
        guard pendingPaste == nil, tool == .select, visibleActiveLayerIndex != nil, !selection.isEmpty,
              delta != Cell(0, 0, 0), span.contains(delta.x), span.contains(delta.y), span.contains(delta.z) else {
            return false
        }
        let occupied = editingCells
        for cell in selection {
            let to = cell.offset(delta.x, delta.y, delta.z)
            guard to.inBounds, isEditableHeight(to.y) else { return false }
            if selection.contains(to) {
                // An overlapping source will be vacated, but other visible layers must remain clear.
                if layers.contains(where: { $0.id != activeLayerID && isLayerShownInEditor($0) && $0.cells[to] != nil }) {
                    return false
                }
            } else if occupied[to] != nil {
                return false
            }
        }
        return true
    }

    @discardableResult
    func moveSelection(by delta: Cell) -> Bool {
        guard canMoveSelection(by: delta), let index = visibleActiveLayerIndex else { return false }
        endStroke()
        let source = selection
        selection = relocate(source, by: delta, in: &layers[index].cells)
        record(.move(layer: activeLayerID, source: source, delta: delta))
        return true
    }

    private func relocate(_ source: Set<Cell>, by delta: Cell, in cells: inout [Cell: Ink]) -> Set<Cell> {
        var moved: [Cell: Ink] = [:]
        moved.reserveCapacity(source.count)
        // Extract every source first, so translations can overlap regardless of iteration order.
        for cell in source {
            moved[cell.offset(delta.x, delta.y, delta.z)] = cells.removeValue(forKey: cell)
        }
        cells.merge(moved) { _, incoming in incoming }
        return Set(moved.keys)
    }

    private func write(_ changes: [Cell: Delta], in cells: inout [Cell: Ink], forward: Bool) {
        for (cell, delta) in changes { cells[cell] = forward ? delta.after : delta.before }
    }

    func addLayer() {
        endStroke()
        guard layers.count < Self.layerLimit else { return }
        var number = layers.count + 1
        let names = Set(layers.map(\.name))
        while names.contains("Layer \(number)") { number += 1 }
        let layer = VoxelLayer(name: "Layer \(number)")
        let oldActive = activeLayerID
        let index = layers.count
        layers.append(layer)
        activeLayerID = layer.id
        record(.layer(layer, index: index, inserted: true, oldActive: oldActive, newActive: layer.id))
    }

    func removeActiveLayer() {
        endStroke()
        guard layers.count > 1, let index = layers.firstIndex(where: { $0.id == activeLayerID && !$0.isLocked }) else { return }
        let removed = layers.remove(at: index)
        activeLayerID = layers[min(index, layers.count - 1)].id
        record(.layer(removed, index: index, inserted: false, oldActive: removed.id, newActive: activeLayerID))
    }

    func renameLayer(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = layers.firstIndex(where: { $0.id == id && !$0.isLocked }),
              layers[index].name != trimmed else { return }
        endStroke()
        let previous = layers[index].name
        layers[index].name = trimmed
        record(.name(id, before: previous, after: trimmed))
    }

    func toggleLayer(_ id: UUID) {
        endStroke()
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        if isolatedLayerID != nil { isolatedLayerID = nil }
        layers[index].isVisible.toggle()
        pruneSelection()
        record(.visibility(id, layers[index].isVisible))
    }

    func toggleLayerLock(_ id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        endStroke()
        layers[index].isLocked.toggle()
        pruneSelection()
        record(.lock(id, layers[index].isLocked))
    }

    func toggleIsolation(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        if isolatedLayerID == id {
            isolatedLayerID = nil
        } else {
            activeLayerID = id
            isolatedLayerID = id
        }
    }

    func addPaletteColor(_ ink: Ink) {
        guard ink.isValid else { return }
        self.ink = ink
        guard !palette.contains(ink), palette.count < Self.paletteLimit else { return }
        endStroke()
        palette.append(ink)
        record(.palette(ink))
    }

    private func record(_ change: Change) {
        cancelPaste()
        let nextState = UUID()
        undoStack.append(Entry(change: change, before: currentState, after: nextState))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        currentState = nextState
        isDirty = currentState != savedState
    }

    func undo() {
        cancelPaste()
        endStroke()
        guard let entry = undoStack.popLast() else { return }
        replay(entry.change, forward: false)
        redoStack.append(entry)
        currentState = entry.before
        isDirty = currentState != savedState
    }

    func redo() {
        cancelPaste()
        endStroke()
        guard let entry = redoStack.popLast() else { return }
        replay(entry.change, forward: true)
        undoStack.append(entry)
        currentState = entry.after
        isDirty = currentState != savedState
    }

    private func replay(_ change: Change, forward: Bool) {
        switch change {
        case let .voxels(id, deltas, selectionBefore, selectionAfter):
            guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
            write(deltas, in: &layers[index].cells, forward: forward)
            if tool == .select, id == activeLayerID, let restored = forward ? selectionAfter : selectionBefore {
                selection = restored
            }
        case let .uniform(id, cells, before, after):
            guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
            setInk(forward ? after : before, for: cells, in: &layers[index].cells)
        case let .move(id, source, delta):
            guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
            let previous = forward ? source : Set(source.map { $0.offset(delta.x, delta.y, delta.z) })
            let direction = forward ? delta : Cell(-delta.x, -delta.y, -delta.z)
            let moved = relocate(previous, by: direction, in: &layers[i].cells)
            if tool == .select && activeLayerID == id { selection = moved }
        case let .layer(layer, index, inserted, oldActive, newActive):
            if inserted == forward {
                layers.insert(layer, at: index)
            } else {
                layers.remove(at: index)
            }
            activeLayerID = forward ? newActive : oldActive
        case let .visibility(id, visible):
            if let i = layers.firstIndex(where: { $0.id == id }) {
                layers[i].isVisible = forward ? visible : !visible
            }
        case let .lock(id, locked):
            if let i = layers.firstIndex(where: { $0.id == id }) {
                layers[i].isLocked = forward ? locked : !locked
            }
        case let .name(id, before, after):
            if let index = layers.firstIndex(where: { $0.id == id }) {
                layers[index].name = forward ? after : before
            }
        case let .palette(color):
            if forward {
                palette.append(color)
            } else {
                palette.removeLast()
            }
        }
        pruneSelection()
    }

    private func replaceLayers(_ newLayers: [VoxelLayer], activeID: UUID, title: String, palette: [Ink],
                               url: URL?, origin: Cell? = nil) {
        stroke = nil
        clearSelection()
        isolatedLayerID = nil
        mirrorX = false
        mirrorZ = false
        sliceEnabled = false
        sliceLevel = 0
        shapeDepth = 1
        undoStack.removeAll()
        redoStack.removeAll()
        layers = newLayers
        activeLayerID = activeID
        self.title = title
        projectID = UUID()
        self.palette = palette
        self.ink = palette[0]
        projectURL = url
        voxOrigin = origin
        currentState = UUID()
        savedState = currentState
        isDirty = false
    }

    func newProject() {
        guard shouldCloseProject() else { return }
        let base = VoxelLayer(name: "Layer 1")
        replaceLayers([base], activeID: base.id, title: "Untitled", palette: Self.defaultPalette, url: nil)
    }

    func loadDemo() {
        guard shouldCloseProject() else { return }
        let demo = DemoScene.layers()
        replaceLayers(demo, activeID: demo.last!.id, title: "Northern Lighthouse", palette: Self.defaultPalette,
                      url: nil)
    }

    func shouldCloseProject() -> Bool {
        endStroke()
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(title)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private var projectType: UTType { UTType(filenameExtension: "vxl") ?? .data }

    private var voxType: UTType { UTType(filenameExtension: "vox") ?? .data }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType, voxType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            if url.pathExtension.lowercased() == "vox" {
                try importVOX(from: url)
            } else {
                try loadProject(from: url)
            }
        } catch {
            show(error, title: "Couldn’t open the project")
        }
    }

    func importVOX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [voxType]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try importVOX(from: url)
        } catch {
            show(error, title: "Couldn’t import the VOX file")
        }
    }

    func importVOX(from url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let scene = try MagicaVoxel.decode(data)
        guard shouldCloseProject() else { return }
        let active = scene.layers.last(where: { $0.isVisible }) ?? scene.layers[0]
        replaceLayers(scene.layers, activeID: active.id, title: url.deletingPathExtension().lastPathComponent,
                      palette: scene.palette, url: nil, origin: scene.origin)
        // An imported document never inherits its source URL as a native save destination.
        savedState = UUID()
        isDirty = true
    }

    func exportVOX() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [voxType]
        panel.nameFieldStringValue = title + ".vox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportVOX(to: url)
        } catch {
            show(error, title: "Couldn’t export the VOX file")
        }
    }

    func exportVOX(to url: URL) throws {
        let data = try MagicaVoxel.encode(layers: layers, palette: palette, origin: voxOrigin)
        try data.write(to: url, options: .atomic)
    }

    func loadProject(from url: URL) throws {
        try loadProject(from: url, confirmReplacement: shouldCloseProject)
    }

    func loadProject(from url: URL, confirmReplacement: () throws -> Bool) throws {
        func read() throws -> (ProjectFile, [VoxelLayer]) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 256 * 1024 * 1024 else { throw ProjectError.tooLarge }
            let file = try JSONDecoder().decode(ProjectFile.self, from: data)
            return (file, try file.validatedLayers())
        }

        var (file, newLayers) = try read()
        let previousSave = savedState
        guard try confirmReplacement() else { return }
        if previousSave != savedState, let savedURL = projectURL {
            // Save As can replace the incoming file while the close dialog is open.
            func fileID(_ url: URL) -> NSObjectProtocol? {
                let resolved = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
                return try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            }
            let savedID = fileID(savedURL), incomingID = fileID(url)
            if savedID == nil || incomingID == nil || savedID?.isEqual(incomingID) == true {
                (file, newLayers) = try read()
            }
        }
        replaceLayers(newLayers, activeID: file.activeLayerID, title: file.title, palette: file.palette,
                      url: url, origin: file.voxOrigin)
    }

    @discardableResult
    func saveProject(asNew: Bool = false) -> Bool {
        let url: URL
        if !asNew, let projectURL { url = projectURL }
        else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [projectType]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = title + ".vxl"
            guard panel.runModal() == .OK, let selected = panel.url else { return false }
            url = selected
        }
        do {
            try saveProject(to: url)
            return true
        } catch {
            show(error, title: "Couldn’t save the project")
            return false
        }
    }

    func saveProject(to url: URL) throws {
        guard url.pathExtension.lowercased() != "vox" else { throw ProjectError.nativeExtension }
        endStroke()
        let name = url.deletingPathExtension().lastPathComponent
        let file = ProjectFile(
            version: ProjectFile.currentVersion, title: name, palette: palette, activeLayerID: activeLayerID,
            layers: layers.map { layer in
                let voxels = layer.cells.map { ProjectFile.Voxel(cell: $0.key, ink: $0.value) }
                return ProjectFile.Layer(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                                         isLocked: layer.isLocked ? true : nil, voxels: voxels)
            }, voxOrigin: voxOrigin
        )
        let data = try JSONEncoder().encode(file)
        guard data.count <= 256 * 1024 * 1024 else { throw ProjectError.tooLarge }
        try data.write(to: url, options: .atomic)
        projectURL = url
        title = name
        savedState = currentState
        isDirty = false
    }

    private func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func exportOBJ() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "obj") ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title + ".obj"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportOBJ(to: url)
        } catch {
            show(error, title: "Couldn’t export the model")
        }
    }

    func exportOBJ(to url: URL) throws {
        let cells = visibleCells
        guard !cells.isEmpty else { throw ProjectError.emptyExport }
        let faces: [(neighbor: Cell, corners: [Cell])] = [
            (Cell(1, 0, 0),  [Cell(1, 0, 0), Cell(1, 1, 0), Cell(1, 1, 1), Cell(1, 0, 1)]),
            (Cell(-1, 0, 0), [Cell(0, 0, 1), Cell(0, 1, 1), Cell(0, 1, 0), Cell(0, 0, 0)]),
            (Cell(0, 1, 0),  [Cell(0, 1, 1), Cell(1, 1, 1), Cell(1, 1, 0), Cell(0, 1, 0)]),
            (Cell(0, -1, 0), [Cell(0, 0, 0), Cell(1, 0, 0), Cell(1, 0, 1), Cell(0, 0, 1)]),
            (Cell(0, 0, 1),  [Cell(1, 0, 1), Cell(1, 1, 1), Cell(0, 1, 1), Cell(0, 0, 1)]),
            (Cell(0, 0, -1), [Cell(0, 0, 0), Cell(0, 1, 0), Cell(1, 1, 0), Cell(1, 0, 0)])
        ]
        var vertexIDs: [Cell: Int] = [:]
        var vertices = ""
        var surfaces: [String: String] = [:]
        for (cell, ink) in cells {
            let key = String(ink.hex.dropFirst())
            for face in faces where cells[cell.offset(face.neighbor.x, face.neighbor.y, face.neighbor.z)] == nil {
                var line = "f"
                for corner in face.corners {
                    let point = cell.offset(corner.x, corner.y, corner.z)
                    let index: Int
                    if let existing = vertexIDs[point] {
                        index = existing
                    } else {
                        index = vertexIDs.count + 1
                        vertexIDs[point] = index
                        vertices += "v \(point.x) \(point.y) \(point.z)\n"
                    }
                    line += " \(index)"
                }
                surfaces[key, default: ""] += line + "\n"
            }
        }
        let keys = surfaces.keys.sorted()
        let materials = keys.map { key in
            let ink = Ink(hex: key)
            return "newmtl c\(key)\nKd \(ink.r) \(ink.g) \(ink.b)\nillum 1\n"
        }.joined(separator: "\n")
        let materialData = Data(materials.utf8)
        let digest = SHA256.hash(data: materialData).map { String(format: "%02x", $0) }.joined()
        let folder = url.deletingLastPathComponent()
        var materialURL = folder.appendingPathComponent("voxel-materials-\(digest.prefix(16)).mtl")
        // Content-addressed companions let multiple OBJ exports share the same directory.
        if FileManager.default.fileExists(atPath: materialURL.path),
           (try? Data(contentsOf: materialURL)) != materialData {
            materialURL = folder.appendingPathComponent("voxel-materials-\(UUID().uuidString).mtl")
        }
        let created = !FileManager.default.fileExists(atPath: materialURL.path)
        if created { try materialData.write(to: materialURL, options: .withoutOverwriting) }
        var model = "mtllib \(materialURL.lastPathComponent)\no Voxels\n" + vertices + "s off\n"
        for key in keys { model += "usemtl c\(key)\n" + surfaces[key]! }
        do {
            try Data(model.utf8).write(to: url, options: .atomic)
        } catch {
            if created { try? FileManager.default.removeItem(at: materialURL) }
            throw error
        }
    }
}

extension EditorModel {
    @discardableResult
    func duplicateSelection() -> Bool {
        guard pendingPaste == nil, tool == .select, let index = visibleActiveLayerIndex,
              let bounds = BrushBox(enclosing: selection) else { return false }
        let size = bounds.size
        let offsets = [Cell(size.x, 0, 0), Cell(-size.x, 0, 0), Cell(0, 0, size.z),
                       Cell(0, 0, -size.z), Cell(0, size.y, 0), Cell(0, -size.y, 0)]
        let occupied = editingCells
        for offset in offsets {
            guard bounds.min.offset(offset).inBounds, bounds.max.offset(offset).inBounds,
                  isEditableHeight(bounds.max.y + offset.y),
                  selection.allSatisfy({ occupied[$0.offset(offset)] == nil }) else { continue }
            var edits: [Cell: Delta] = [:]
            edits.reserveCapacity(selection.count)
            for cell in selection {
                edits[cell.offset(offset)] = Delta(before: nil, after: layers[index].cells[cell])
            }
            return commit(edits, in: index, selecting: Set(edits.keys))
        }
        return false
    }

    @discardableResult
    func rotateSelection(around axis: VoxelAxis) -> Bool {
        guard pendingPaste == nil, tool == .select, let index = visibleActiveLayerIndex,
              let bounds = BrushBox(enclosing: selection) else { return false }
        let occupied = editingCells
        let otherLayers = layers.filter { isLayerShownInEditor($0) && $0.id != activeLayerID }
        var destinations: [Cell: Ink] = [:]
        destinations.reserveCapacity(selection.count)
        for source in selection {
            let target = bounds.rotated(source, around: axis)
            guard target.inBounds, isEditableHeight(target.y) else { return false }
            if target != source {
                if selection.contains(target) {
                    guard !otherLayers.contains(where: { $0.cells[target] != nil }) else { return false }
                } else if occupied[target] != nil {
                    return false
                }
            }
            destinations[target] = layers[index].cells[source]
        }
        let rotated = Set(destinations.keys)
        var edits: [Cell: Delta] = [:]
        for source in selection.subtracting(rotated) {
            edits[source] = Delta(before: layers[index].cells[source], after: nil)
        }
        for (target, ink) in destinations where layers[index].cells[target] != ink {
            edits[target] = Delta(before: layers[index].cells[target], after: ink)
        }
        if edits.isEmpty { return true }
        return commit(edits, in: index, selecting: rotated)
    }

    @discardableResult
    func addShape(tool: EditTool, from: Cell, to: Cell, normal: Cell = Cell(0, 1, 0)) -> Bool {
        guard let index = visibleActiveLayerIndex,
              let shape = VoxelShape(tool: tool, from: from, to: to, normal: normal),
              shape.fitsOperationLimit, isEditableHeight(shape.bounds.max.y) else { return false }
        let occupied = editingCells
        var cells = Set<Cell>()
        shape.forEachCell { cell in
            if occupied[cell] == nil { cells.insert(cell) }
        }
        return applyUniformEdit(to: cells, in: index, before: nil)
    }

    @discardableResult
    func floodFill(at seed: Cell) -> Bool {
        guard let index = visibleActiveLayerIndex, ownsVisibleCell(seed, in: index),
              let original = layers[index].cells[seed], ink != original else { return false }
        var region: Set<Cell> = [seed]
        var pending = [seed]
        while let cell = pending.popLast() {
            for direction in Cell.neighbors {
                let neighbor = cell.offset(direction)
                if !region.contains(neighbor), layers[index].cells[neighbor] == original,
                   ownsVisibleCell(neighbor, in: index) {
                    region.insert(neighbor)
                    pending.append(neighbor)
                }
            }
        }
        return applyUniformEdit(to: region, in: index, before: original)
    }

    private func setInk(_ ink: Ink?, for region: Set<Cell>, in cells: inout [Cell: Ink]) {
        for cell in region { cells[cell] = ink }
    }

    private func applyUniformEdit(to cells: Set<Cell>, in index: Int, before: Ink?) -> Bool {
        guard !cells.isEmpty else { return false }
        endStroke()
        setInk(ink, for: cells, in: &layers[index].cells)
        record(.uniform(layers[index].id, cells, before: before, after: ink))
        return true
    }

    func extrusionFace(at seed: Cell, normal: Cell) -> Set<Cell> {
        guard let index = visibleActiveLayerIndex, Cell.neighbors.contains(normal) else { return [] }
        let surface = viewportCells
        func exposed(_ cell: Cell) -> Bool {
            ownsVisibleCell(cell, in: index) && surface[cell.offset(normal)] == nil
        }
        guard exposed(seed) else { return [] }
        let tangents = Cell.neighbors.filter { $0.x * normal.x + $0.y * normal.y + $0.z * normal.z == 0 }
        var result: Set<Cell> = [seed]
        var pending = [seed]
        while let cell = pending.popLast() {
            for direction in tangents {
                let neighbor = cell.offset(direction)
                if !result.contains(neighbor), exposed(neighbor) {
                    result.insert(neighbor)
                    pending.append(neighbor)
                }
            }
        }
        return result
    }

    func canExtrude(_ face: Set<Cell>, normal: Cell, depth: Int) -> Bool {
        guard let index = visibleActiveLayerIndex, let first = face.first,
              Cell.neighbors.contains(normal), (1..<Cell.gridSize).contains(depth),
              face.count <= Self.maxShapeCells / depth else { return false }
        let occupied = editingCells
        for source in face {
            guard ownsVisibleCell(source, in: index),
                  (normal.x == 0 || source.x == first.x), (normal.y == 0 || source.y == first.y),
                  (normal.z == 0 || source.z == first.z) else { return false }
            let end = source.offset(normal, by: depth)
            guard end.inBounds, isEditableHeight(end.y) else { return false }
            for distance in 1...depth where occupied[source.offset(normal, by: distance)] != nil { return false }
        }
        return true
    }

    @discardableResult
    func extrude(_ face: Set<Cell>, normal: Cell, depth: Int) -> Bool {
        guard canExtrude(face, normal: normal, depth: depth), let index = visibleActiveLayerIndex else { return false }
        var edits: [Cell: Delta] = [:]
        edits.reserveCapacity(face.count * depth)
        for source in face {
            let ink = layers[index].cells[source]
            for distance in 1...depth {
                edits[source.offset(normal, by: distance)] = Delta(before: nil, after: ink)
            }
        }
        return commit(edits, in: index)
    }

    private func commit(_ changes: [Cell: Delta], in index: Int, selecting selected: Set<Cell>? = nil) -> Bool {
        guard !changes.isEmpty else { return false }
        endStroke()
        let previous = selected == nil ? nil : selection
        write(changes, in: &layers[index].cells, forward: true)
        if let selected { selection = selected }
        record(.voxels(layers[index].id, changes, selectionBefore: previous, selectionAfter: selected))
        return true
    }
}

extension EditorModel {
    func selectionFragment() -> VoxelFragment? {
        guard pendingPaste == nil, tool == .select, let index = visibleActiveLayerIndex,
              selection.count <= VoxelFragment.maxCells, let box = BrushBox(enclosing: selection) else { return nil }
        var cells: [Cell: Ink] = [:]
        cells.reserveCapacity(selection.count)
        for source in selection {
            guard ownsVisibleCell(source, in: index), let ink = layers[index].cells[source] else { return nil }
            cells[source.offset(-box.min.x, -box.min.y, -box.min.z)] = ink
        }
        return VoxelFragment(origin: box.min, cells: cells)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        guard pendingPaste == nil, tool == .select, let index = visibleActiveLayerIndex, !selection.isEmpty else {
            return false
        }
        var changes: [Cell: Delta] = [:]
        changes.reserveCapacity(selection.count)
        for cell in selection {
            guard ownsVisibleCell(cell, in: index), let ink = layers[index].cells[cell] else { return false }
            changes[cell] = Delta(before: ink, after: nil)
        }
        return commit(changes, in: index, selecting: [])
    }

    @discardableResult
    func beginPaste(_ fragment: VoxelFragment) -> Bool {
        guard visibleActiveLayerIndex != nil else { return false }
        endStroke()
        cancelPaste()
        tool = .select
        pendingPaste = fragment
        updatePasteAnchor(fragment.origin)
        return true
    }

    func updatePasteAnchor(_ anchor: Cell?) {
        guard let fragment = pendingPaste, anchor != pasteAnchor else { return }
        pasteAnchor = anchor
        pasteAllowed = anchor.map { fits(fragment, at: $0) } ?? false
    }

    private func fits(_ fragment: VoxelFragment, at anchor: Cell) -> Bool {
        guard anchor.inBounds, visibleActiveLayerIndex != nil else { return false }
        let last = anchor.offset(fragment.size).offset(-1, -1, -1)
        guard last.inBounds, isEditableHeight(last.y) else { return false }
        let occupied = editingCells
        // On a sparse destination, hover checks should scale with the smaller of the two collections.
        if occupied.count < fragment.cells.count {
            return occupied.keys.allSatisfy { fragment.cells[$0.offset(-anchor.x, -anchor.y, -anchor.z)] == nil }
        }
        return fragment.cells.keys.allSatisfy { occupied[anchor.offset($0)] == nil }
    }

    func cancelPaste() {
        guard pendingPaste != nil else { return }
        pendingPaste = nil
        pasteAnchor = nil
        pasteAllowed = false
    }

    @discardableResult
    func commitPaste() -> Bool {
        guard let fragment = pendingPaste, let anchor = pasteAnchor, let index = visibleActiveLayerIndex,
              fits(fragment, at: anchor) else { return false }
        var changes: [Cell: Delta] = [:]
        changes.reserveCapacity(fragment.cells.count)
        for (offset, ink) in fragment.cells {
            changes[anchor.offset(offset)] = Delta(before: nil, after: ink)
        }
        cancelPaste()
        return commit(changes, in: index, selecting: Set(changes.keys))
    }
}
