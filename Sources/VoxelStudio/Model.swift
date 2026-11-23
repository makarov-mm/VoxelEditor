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

    var hex: String {
        func byte(_ value: Float) -> Int {
            value.isFinite ? Int((min(1, max(0, value)) * 255).rounded()) : 0
        }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var color: Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b))
    }

    fileprivate var isValid: Bool {
        [r, g, b].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum EditTool: String, CaseIterable {
    case add, paint, erase, pick
}

struct VoxelLayer: Identifiable {
    var id = UUID()
    var name: String
    var isVisible = true
    var cells: [Cell: Ink] = [:]
}

private enum ProjectError: LocalizedError {
    case invalidProject, unsupportedVersion, tooLarge, emptyExport, nativeExtension

    var errorDescription: String? {
        switch self {
        case .nativeExtension: return "Save the native project as .vxl or use Export VOX for a MagicaVoxel file."
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
            return VoxelLayer(id: source.id, name: source.name, isVisible: source.isVisible, cells: cells)
        }
    }
}

final class EditorModel: ObservableObject {
    static let layerLimit = 128
    static let paletteLimit = 256

    static let defaultPalette = [
        "E96555", "BF5045", "F5BD62", "F4E6CA",
        "D8BB84", "CCBDA1", "926D50", "314552",
        "A4AE76", "C1C797", "6E916F", "4F7467",
        "538F8D", "82BCBA", "D4EBDA", "697B82"
    ].map { Ink(hex: $0) }

    @Published private(set) var layers: [VoxelLayer] {
        didSet {
            merged = nil
            revision &+= 1
        }
    }
    @Published var activeLayerID: UUID
    @Published var tool: EditTool = .add
    @Published var ink = Ink(hex: "E96555")
    @Published var showGrid = true
    @Published var showEdges = false
    @Published var brushSize = 1
    @Published private(set) var title = "Northern Lighthouse"
    @Published private(set) var isDirty = false
    @Published private(set) var palette = EditorModel.defaultPalette
    @Published private(set) var revision = 0
    @Published private(set) var projectID = UUID()

    private var merged: [Cell: Ink]?
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
        case voxels(UUID, [Cell: Delta])
        case layer(VoxelLayer, index: Int, inserted: Bool, oldActive: UUID, newActive: UUID)
        case visibility(UUID, Bool)
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

    var voxelCount: Int { visibleCells.count }
    var canUndo: Bool { !undoStack.isEmpty || stroke?.changes.isEmpty == false }
    var canRedo: Bool { !redoStack.isEmpty && stroke?.changes.isEmpty != false }

    func beginStroke() {
        endStroke()
        stroke = Stroke(layer: activeLayerID)
    }

    func endStroke() {
        guard let finished = stroke else { return }
        stroke = nil
        let changes = finished.changes.filter { $0.value.before != $0.value.after }
        if !changes.isEmpty { record(.voxels(finished.layer, changes)) }
        else { isDirty = currentState != savedState }
    }

    func brushBounds(hit: Cell?, adjacent: Cell?) -> (min: Cell, max: Cell)? {
        guard let center = tool == .add ? adjacent : hit, center.inBounds else { return nil }
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
        let y = extents(center.y, normal: hit.map { center.y - $0.y } ?? 1, limits: Cell.verticalRange)
        let z = extents(center.z, normal: hit.map { center.z - $0.z } ?? 0, limits: Cell.horizontalRange)
        return (Cell(x.lowerBound, y.lowerBound, z.lowerBound), Cell(x.upperBound, y.upperBound, z.upperBound))
    }

    func apply(hit: Cell?, adjacent: Cell?) {
        if tool == .pick {
            if let hit, let color = visibleCells[hit] { ink = color }
            return
        }
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID && $0.isVisible }),
              let bounds = brushBounds(hit: hit, adjacent: adjacent) else { return }

        if let activeStroke = stroke, activeStroke.layer != activeLayerID { endStroke() }
        let singleClick = stroke == nil
        if singleClick { beginStroke() }
        defer { if singleClick { endStroke() } }

        let visible = visibleCells
        var edits: [Cell: Delta] = [:]
        for x in bounds.min.x...bounds.max.x {
            for y in bounds.min.y...bounds.max.y {
                for z in bounds.min.z...bounds.max.z {
                    let cell = Cell(x, y, z)
                    let previous = layers[index].cells[cell]
                    if tool == .add {
                        guard visible[cell] == nil else { continue }
                    } else {
                        guard previous != nil, !layers.dropFirst(index + 1).contains(where: {
                            $0.isVisible && $0.cells[cell] != nil
                        }) else { continue }
                    }
                    let next: Ink? = tool == .erase ? nil : ink
                    if previous != next { edits[cell] = Delta(before: previous, after: next) }
                }
            }
        }
        guard !edits.isEmpty else { return }
        for (cell, change) in edits {
            if stroke?.changes[cell] != nil { stroke?.changes[cell]?.after = change.after }
            else { stroke?.changes[cell] = change }
        }
        write(edits, in: &layers[index].cells, forward: true)
        isDirty = true
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
        guard layers.count > 1, let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        let removed = layers.remove(at: index)
        activeLayerID = layers[min(index, layers.count - 1)].id
        record(.layer(removed, index: index, inserted: false, oldActive: removed.id, newActive: activeLayerID))
    }

    func renameLayer(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].name != trimmed else { return }
        endStroke()
        let previous = layers[index].name
        layers[index].name = trimmed
        record(.name(id, before: previous, after: trimmed))
    }

    func toggleLayer(_ id: UUID) {
        endStroke()
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].isVisible.toggle()
        record(.visibility(id, layers[index].isVisible))
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
        let nextState = UUID()
        undoStack.append(Entry(change: change, before: currentState, after: nextState))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        currentState = nextState
        isDirty = currentState != savedState
    }

    func undo() {
        endStroke()
        guard let entry = undoStack.popLast() else { return }
        replay(entry.change, forward: false)
        redoStack.append(entry)
        currentState = entry.before
        isDirty = currentState != savedState
    }

    func redo() {
        endStroke()
        guard let entry = redoStack.popLast() else { return }
        replay(entry.change, forward: true)
        undoStack.append(entry)
        currentState = entry.after
        isDirty = currentState != savedState
    }

    private func replay(_ change: Change, forward: Bool) {
        switch change {
        case let .voxels(id, deltas):
            guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
            write(deltas, in: &layers[index].cells, forward: forward)
        case let .layer(layer, index, inserted, oldActive, newActive):
            if inserted == forward { layers.insert(layer, at: index) }
            else { layers.remove(at: index) }
            activeLayerID = forward ? newActive : oldActive
        case let .visibility(id, visible):
            if let i = layers.firstIndex(where: { $0.id == id }) {
                layers[i].isVisible = forward ? visible : !visible
            }
        case let .name(id, before, after):
            if let index = layers.firstIndex(where: { $0.id == id }) {
                layers[index].name = forward ? after : before
            }
        case let .palette(color):
            if forward { palette.append(color) }
            else { palette.removeLast() }
        }
    }

    private func replaceLayers(_ newLayers: [VoxelLayer], activeID: UUID, title: String, palette: [Ink], url: URL?, origin: Cell? = nil) {
        stroke = nil
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
        replaceLayers(demo, activeID: demo.last!.id, title: "Northern Lighthouse", palette: Self.defaultPalette, url: nil)
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
            if url.pathExtension.lowercased() == "vox" { try importVOX(from: url) }
            else { try loadProject(from: url) }
        }
        catch { show(error, title: "Couldn’t open the project") }
    }

    func importVOX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [voxType]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importVOX(from: url) }
        catch { show(error, title: "Couldn’t import the VOX file") }
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
        do { try exportVOX(to: url) }
        catch { show(error, title: "Couldn’t export the VOX file") }
    }

    func exportVOX(to url: URL) throws {
        let data = try MagicaVoxel.encode(layers: layers, palette: palette, origin: voxOrigin)
        try data.write(to: url, options: .atomic)
    }

    func loadProject(from url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 256 * 1024 * 1024 else { throw ProjectError.tooLarge }
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)
        let newLayers = try file.validatedLayers()
        guard shouldCloseProject() else { return }
        replaceLayers(newLayers, activeID: file.activeLayerID, title: file.title, palette: file.palette, url: url, origin: file.voxOrigin)
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
        do { try saveProject(to: url); return true }
        catch { show(error, title: "Couldn’t save the project"); return false }
    }

    func saveProject(to url: URL) throws {
        guard url.pathExtension.lowercased() != "vox" else { throw ProjectError.nativeExtension }
        endStroke()
        let name = url.deletingPathExtension().lastPathComponent
        let file = ProjectFile(
            version: ProjectFile.currentVersion, title: name, palette: palette, activeLayerID: activeLayerID,
            layers: layers.map { layer in
                let voxels = layer.cells.map { ProjectFile.Voxel(cell: $0.key, ink: $0.value) }
                return ProjectFile.Layer(id: layer.id, name: layer.name, isVisible: layer.isVisible, voxels: voxels)
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
        do { try exportOBJ(to: url) }
        catch { show(error, title: "Couldn’t export the model") }
    }

    func exportOBJ(to url: URL) throws {
        let cells = visibleCells
        guard !cells.isEmpty else { throw ProjectError.emptyExport }
        let faces: [(neighbor: Cell, corners: [Cell])] = [
            (Cell(1,0,0),  [Cell(1,0,0), Cell(1,1,0), Cell(1,1,1), Cell(1,0,1)]),
            (Cell(-1,0,0), [Cell(0,0,1), Cell(0,1,1), Cell(0,1,0), Cell(0,0,0)]),
            (Cell(0,1,0),  [Cell(0,1,1), Cell(1,1,1), Cell(1,1,0), Cell(0,1,0)]),
            (Cell(0,-1,0), [Cell(0,0,0), Cell(1,0,0), Cell(1,0,1), Cell(0,0,1)]),
            (Cell(0,0,1),  [Cell(1,0,1), Cell(1,1,1), Cell(0,1,1), Cell(0,0,1)]),
            (Cell(0,0,-1), [Cell(0,0,0), Cell(0,1,0), Cell(1,1,0), Cell(1,0,0)])
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
                    if let existing = vertexIDs[point] { index = existing }
                    else {
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
        do { try Data(model.utf8).write(to: url, options: .atomic) }
        catch {
            if created { try? FileManager.default.removeItem(at: materialURL) }
            throw error
        }
    }
}
