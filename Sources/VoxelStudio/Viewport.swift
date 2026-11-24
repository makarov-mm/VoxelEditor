import AppKit
import MetalKit
import SwiftUI
import simd

private enum GridVolume {
    static let low = V3(Float(Cell.horizontalRange.lowerBound), Float(Cell.verticalRange.lowerBound),
                        Float(Cell.horizontalRange.lowerBound))
    static let high = V3(Float(Cell.horizontalRange.upperBound + 1), Float(Cell.verticalRange.upperBound + 1),
                         Float(Cell.horizontalRange.upperBound + 1))
    static let center = (low + high) * 0.5
    static let depth = simd_length(high - low) + 4
}

private struct CanvasColors {
    let background, grid, hoverEdge: V4

    init(dark: Bool) {
        background = dark ? V4(0.111, 0.137, 0.128, 1) : V4(0.954, 0.951, 0.925, 1)
        grid = dark ? V4(0.50, 0.56, 0.52, 1) : V4(0.45, 0.46, 0.42, 1)
        hoverEdge = dark ? V4(0.90, 1, 0.94, 1) : V4(0.14, 0.17, 0.16, 1)
    }
}

final class OrbitCamera: ObservableObject {
    weak var viewport: StudioViewportSurface?
    @Published fileprivate(set) var gestureReadout: String?
    @Published private(set) var zoomPercent = 100
    @Published private(set) var viewKey = "iso"
    @Published fileprivate(set) var rendererName = "…"
    @Published fileprivate var yaw: Float = 0.63
    @Published fileprivate var pitch: Float = 0.48
    @Published fileprivate var pan = SIMD3<Float>.zero
    @Published fileprivate var framing = 0
    fileprivate var magnification: Float = 1

    func reset() { orient("iso") }
    func zoomIn() { zoom(by: 1.2) }
    func zoomOut() { zoom(by: 1 / 1.2) }

    func orient(_ view: String) {
        viewKey = ["front", "top", "right"].contains(view) ? view : "iso"
        switch view {
        case "front": (yaw, pitch) = (0, 0)
        case "top": (yaw, pitch) = (0, .pi / 2)
        case "right": (yaw, pitch) = (.pi / 2, 0)
        default: (yaw, pitch) = (0.63, 0.48)
        }
        frameScene()
    }

    func frameScene() {
        pan = .zero
        magnification = 1
        zoomPercent = 100
        framing += 1
    }

    fileprivate func zoom(by factor: Float) {
        magnification = min(Float(Cell.gridSize), max(0.02, magnification * factor))
        zoomPercent = Int((magnification * 100).rounded())
    }

    fileprivate func orbit(dx: CGFloat, dy: CGFloat) {
        if viewKey != "custom" { viewKey = "custom" }
        yaw -= Float(dx) * 0.009
        pitch = min(.pi * 0.495, max(0.035, pitch + Float(dy) * 0.008))
    }

    fileprivate var axes: (right: SIMD3<Float>, up: SIMD3<Float>, eye: SIMD3<Float>) {
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let eye = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        return (right, simd_cross(eye, right), eye)
    }
}

struct VoxelViewport: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var camera: OrbitCamera

    var objectMode = false
    var outlinesActiveObject = true
    var onScenePick: ((UUID) -> Void)?

    func makeNSView(context: Context) -> StudioViewportSurface {
        StudioViewportSurface(model: model, camera: camera)
    }

    func updateNSView(_ nsView: StudioViewportSurface, context: Context) {
        nsView.onScenePick = onScenePick
        nsView.outlinesActiveObject = outlinesActiveObject
        nsView.objectMode = objectMode
        nsView.synchronize(model: model, camera: camera)
    }
}

private struct SceneProjection: Equatable {
    let right: V3, up: V3, eye: V3, target: V3
    let scale: Float, size: CGSize

    var gridStep: Int {
        // Keep the ground readable when framing large imports or looking almost horizontally.
        let projectedSpacing = scale * max(0.02, eye.y)
        let exponent = min(7, max(0, ceil(log2(3.0 / max(0.001, projectedSpacing)))))
        return 1 << Int(exponent)
    }

    func project(_ p: V3) -> CGPoint {
        let delta = p - target
        return CGPoint(x: size.width * 0.5 + CGFloat(simd_dot(delta, right) * scale),
                       y: size.height * 0.5 + CGFloat(simd_dot(delta, up) * scale))
    }

    func dragOffset(from start: CGPoint, to point: CGPoint, onFaceAxis axis: Int) -> Cell? {
        guard abs(eye[axis]) > 0.00001 else { return nil }
        let motion = planePoint(point) - planePoint(start)
        // Intersect both pointer rays with the starting face plane.
        var world = motion - eye * (motion[axis] / eye[axis])
        world[axis] = 0
        return Cell(Int(world.x.rounded()), Int(world.y.rounded()), Int(world.z.rounded()))
    }

    func planePoint(_ p: CGPoint) -> V3 {
        target + right * Float(p.x - size.width * 0.5) / scale
            + up * Float(p.y - size.height * 0.5) / scale
    }
}

private struct PickResult {
    var hit: Cell?
    var adjacent: Cell?

    var normal: Cell {
        guard let hit, let adjacent else { return Cell(0, 1, 0) }
        return Cell(adjacent.x - hit.x, adjacent.y - hit.y, adjacent.z - hit.z)
    }
}

private func pickCell(at point: CGPoint, projection: SceneProjection, voxels: [Cell: Ink],
                      workLevel: Int) -> PickResult {
    let ray = -projection.eye
    let plane = projection.planePoint(point)
    let start = plane + ray * (simd_dot(GridVolume.center - plane, ray) - GridVolume.depth)
    let low = GridVolume.low, high = GridVolume.high
    var near: Float = 0, far = GridVolume.depth * 2
    var entryNormal = SIMD3<Int>.zero
    for axis in 0..<3 {
        if abs(ray[axis]) < 0.000001 {
            if start[axis] < low[axis] || start[axis] >= high[axis] { return PickResult() }
            continue
        }
        let a = (low[axis] - start[axis]) / ray[axis], b = (high[axis] - start[axis]) / ray[axis]
        if min(a, b) > near {
            near = min(a, b)
            entryNormal = .zero
            entryNormal[axis] = ray[axis] > 0 ? -1 : 1
        }
        far = min(far, max(a, b))
    }
    guard near < far else { return PickResult() }
    let first = start + ray * (near + 0.0001)
    var pos = SIMD3(Int(floor(first.x)), Int(floor(first.y)), Int(floor(first.z)))
    var step = SIMD3<Int>.zero
    var next = V3(repeating: .infinity), delta = V3(repeating: .infinity)
    for a in 0..<3 where abs(ray[a]) > 0.000001 {
        step[a] = ray[a] > 0 ? 1 : -1
        let boundary = Float(pos[a] + (step[a] > 0 ? 1 : 0))
        next[a] = (boundary - start[a]) / ray[a]
        delta[a] = abs(1 / ray[a])
    }
    for _ in 0..<(Cell.gridSize * 3 + 3) {
        if voxels[cell(pos)] != nil {
            return PickResult(hit: cell(pos), adjacent: cell(pos &+ entryNormal))
        }
        let a = next.x < next.y ? (next.x < next.z ? 0 : 2) : (next.y < next.z ? 1 : 2)
        if next[a] >= far - 0.00001 { break }
        pos[a] += step[a]
        next[a] += delta[a]
        entryNormal = .zero
        entryNormal[a] = -step[a]
    }
    if ray.y < -0.000001 {
        let p = start + ray * ((Float(workLevel) - start.y) / ray.y)
        if p.x >= low.x, p.x < high.x, p.z >= low.z, p.z < high.z {
            return PickResult(hit: nil, adjacent: Cell(Int(floor(p.x)), workLevel, Int(floor(p.z))))
        }
    }
    return PickResult()
}

private struct ModelingDrag {
    let tool: EditTool
    let start: CGPoint
    let anchor: Cell
    let normal: Cell
    let layerID: UUID
    let projection: SceneProjection
    let face: Set<Cell>
    var end: Cell?
    var depth = -1
    var wallThickness = 0
    var allowed = false
}

private func boxFace(_ box: BrushBox, side: Int, tint: V4) -> VoxelFace {
    let c = box.min
    let size = box.size
    return VoxelFace(base: V4(Float(c.x), Float(c.y), Float(c.z), Float(side)),
                     color: tint, ao: V4(repeating: 1), extent: V4(Float(size.x), Float(size.y), Float(size.z), 0))
}

private func boxFaces(_ box: BrushBox, tint: V4) -> [VoxelFace] {
    normalOffsets.indices.map { boxFace(box, side: $0, tint: tint) }
}

private struct SelectionDrag {
    let start: CGPoint
    let hit: Cell?
    let additive: Bool
    let layerID: UUID
    let moveAxis: Int?
    let projection: SceneProjection
    var moved = false
}

private struct ObjectDrag {
    let start: CGPoint
    let objectID, layerID, projectID: UUID
    let revision, interactionRevision: Int
    let faceAxis: Int
    let projection: SceneProjection
    let framing: Int
}

private struct ObjectOutlineKey: Equatable {
    let objectID, projectID: UUID
    let revision: Int
}

private let selectionTint = V4(0.12, 0.68, 0.91, 0.46)
private let validMoveTint = V4(0.24, 0.91, 0.59, 0.53)
private let invalidMoveTint = V4(1.00, 0.25, 0.20, 0.58)

final class StudioViewportSurface: NSView {
    private var model: EditorModel
    private var camera: OrbitCamera
    private var voxels: [Cell: Ink] = [:]
    private let meshCache = SceneMeshCache()
    private var scene = RenderScene(draws: [])
    private var revision: Int?
    private var requestedFrame: Int?
    private var baseTarget = V3.zero
    private var fit = SIMD2<Float>(30, 30)
    private var metalView: MTKView?
    private var painter: MetalPainter?
    private var softwareShadow: CGImage?
    private var tracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private var strokeVoxels: [Cell: Ink]?
    private var displayedWorkLevel = 0
    private var lastStrokePoint: CGPoint?
    private let marquee = NSView()
    private var modelingDrag: ModelingDrag?
    private var modelingFaces: [VoxelFace] = []
    private var selectionDrag: SelectionDrag?
    private var objectDrag: ObjectDrag?
    private var displayedOutline: ObjectOutlineKey?
    var hasObjectGesture: Bool { objectDrag != nil }
    var onScenePick: ((UUID) -> Void)?
    var outlinesActiveObject = true {
        didSet {
            guard oldValue != outlinesActiveObject else { return }
            if !outlinesActiveObject { cancelObjectDrag(duringViewUpdate: true) }
            updateSelectionShell()
            redraw()
        }
    }
    var objectMode = false {
        didSet {
            guard oldValue != objectMode else { return }
            cancelPointerGesture(duringViewUpdate: true)
            updateSelectionShell()
            window?.invalidateCursorRects(for: self)
            redraw()
        }
    }
    private var pressedFragment: VoxelFragment?
    private var displayedFragment: VoxelFragment?
    private var displayedSelection = Set<Cell>()
    private var selectionFaces = [VoxelFace]()
    fileprivate var moveOffset = Cell(0, 0, 0)
    fileprivate var moveAllowed = false
    fileprivate var hasMovePreview: Bool { moveOffset != Cell(0, 0, 0) }
    fileprivate var moveTint: V4 { moveAllowed ? validMoveTint : invalidMoveTint }
    fileprivate var previewingPaste: Bool { model.pendingPaste != nil }
    // Both renderers use the cached mesh, translated to the destination and optionally recolored.
    fileprivate var ghostPlacement: (offset: Cell, allowed: Bool, tint: V4?)? {
        if previewingPaste {
            guard let anchor = model.pasteAnchor else { return nil }
            return (anchor, model.pasteAllowed, model.pasteAllowed ? nil : invalidMoveTint)
        }
        guard hasMovePreview else { return nil }
        return (moveOffset, moveAllowed, moveTint)
    }
    private enum Gesture { case paint, orbit, pan, select, modeling, paste, object }
    var projectTitle: String { model.title }
    private var gesture: Gesture?
    override var acceptsFirstResponder: Bool { true }

    init(model: EditorModel, camera: OrbitCamera) {
        self.model = model
        self.camera = camera
        super.init(frame: .zero)
        if let device = MTLCreateSystemDefaultDevice() {
            let view = MTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .depth32Float
            view.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
            view.enableSetNeedsDisplay = true
            view.isPaused = true
            view.autoresizingMask = [.width, .height]
            do {
                let painter = try MetalPainter(device: device, view: view)
                self.painter = painter
                view.delegate = painter
                painter.surface = self
                view.frame = bounds
                addSubview(view)
                metalView = view
            } catch {
                NSLog("VoxelStudio Metal initialization: %@", error.localizedDescription)
            }
        }
        marquee.wantsLayer = true
        marquee.layer?.borderWidth = 1
        marquee.layer?.borderColor = NSColor.systemTeal.cgColor
        marquee.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.16).cgColor
        marquee.isHidden = true
        addSubview(marquee)
        camera.viewport = self
        let rendererName = painter == nil ? "Core Graphics" : "Metal"
        DispatchQueue.main.async { [weak camera] in camera?.rendererName = rendererName }
        synchronize(model: model, camera: camera)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ p: NSPoint) -> NSView? { super.hitTest(p) == nil ? nil : self }

    func synchronize(model: EditorModel, camera: OrbitCamera) {
        if self.model !== model {
            cancelPointerGesture(duringViewUpdate: true)
            revision = nil
        }
        self.model = model
        self.camera = camera
        if gesture == .paste && pressedFragment !== model.pendingPaste { cancelPasteGesture() }
        if gesture == .paint && (previewingPaste || !model.hasActiveStroke) {
            cancelPointerGesture()
        }
        if gesture == .select && (previewingPaste || model.tool != .select || revision != model.revision ||
                                  selectionDrag?.layerID != model.activeLayerID ||
                                  displayedSelection != model.selection ||
                                  requestedFrame != camera.framing || selectionDrag?.projection != projection) {
            cancelSelectionDrag()
        }
        if let drag = objectDrag, !isCurrent(drag) {
            cancelObjectDrag(duringViewUpdate: true)
        }
        if let drag = modelingDrag,
           previewingPaste || drag.tool != model.tool || drag.layerID != model.activeLayerID ||
           revision != model.revision || requestedFrame != camera.framing || drag.projection != projection {
            cancelModeling(duringViewUpdate: true)
        }
        if revision != model.revision {
            revision = model.revision
            let previousWasEmpty = voxels.isEmpty
            voxels = model.viewportCells
            if previousWasEmpty && voxels.isEmpty {
                baseTarget.y += Float(workLevel - displayedWorkLevel)
            }
            displayedWorkLevel = workLevel
            let next = meshCache.resolve(model, world: voxels)
            if next !== scene {
                scene = next
                softwareShadow = nil
                painter?.update(scene)
            }
        }
        updateSelectionShell()
        if requestedFrame != camera.framing {
            requestedFrame = camera.framing
            frameScene()
        }
        redraw()
    }

    private func updateSelectionShell() {
        let fragment = model.pendingPaste
        let cells = !objectMode && fragment == nil && model.tool == .select ? model.selection : []
        let object = objectMode && outlinesActiveObject && fragment == nil ? model.activeSceneObject : nil
        let outline = object.map { ObjectOutlineKey(objectID: $0.id, projectID: model.projectID, revision: model.revision) }
        guard outline != displayedOutline || fragment !== displayedFragment || cells != displayedSelection else { return }
        displayedOutline = outline
        displayedFragment = fragment
        displayedSelection = cells
        selectionFaces.removeAll(keepingCapacity: false)
        // Keep this mesh in local coordinates: moving a paste preview only changes its offset.
        func appendFaces(at c: Cell, tint: V4, occupied: (Cell) -> Bool) {
            let pos = SIMD3(c.x, c.y, c.z)
            for (side, n) in normalOffsets.enumerated() where !occupied(cell(pos &+ n)) {
                selectionFaces.append(VoxelFace(base: V4(float3(pos), Float(side)), color: tint,
                                                ao: V4(repeating: 1), extent: V4(1, 1, 1, 2)))
            }
        }
        if let fragment {
            for (c, ink) in fragment.cells {
                appendFaces(at: c, tint: V4(ink.r, ink.g, ink.b, 0.64)) { fragment.cells[$0] != nil }
            }
        } else if let object {
            let shown = model.layers.contains { object.layerIDs.contains($0.id) && model.isLayerShownInEditor($0) && !$0.cells.isEmpty }
            if shown, let bounds = model.objectBounds(object.id), !model.sliceEnabled || bounds.min.y <= model.sliceLevel {
                let tint = V4(0.12, 0.63, 0.87, 0.055)
                selectionFaces = boxFaces(bounds, tint: tint)
                for i in selectionFaces.indices { selectionFaces[i].extent.w = 2 }
            }
        } else {
            for c in cells { appendFaces(at: c, tint: selectionTint, occupied: cells.contains) }
        }
        painter?.setSelection(selectionFaces)
    }

    private func frameScene() {
        guard !scene.centers.isEmpty else {
            baseTarget = V3(0, Float(workLevel), 0)
            fit = SIMD2(32, 28)
            return
        }
        let a = camera.axes
        var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
        for p in scene.centers {
            let v = V3(simd_dot(p, a.right), simd_dot(p, a.up), simd_dot(p, a.eye))
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        let center = (hi + lo) * 0.5
        baseTarget = center.x * a.right + center.y * a.up + center.z * a.eye
        fit = SIMD2(max(9, hi.x - lo.x + 1.6), max(9, hi.y - lo.y + 1.7))
    }

    fileprivate var projection: SceneProjection {
        let a = camera.axes
        let s = min(Float(bounds.width) * 0.79 / fit.x, Float(bounds.height) * 0.72 / fit.y)
        return SceneProjection(right: a.right, up: a.up, eye: a.eye, target: baseTarget + camera.pan,
                               scale: max(0.01, s * camera.magnification), size: bounds.size)
    }

    fileprivate var colors: CanvasColors {
        CanvasColors(dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    fileprivate var workLevel: Int { model.sliceEnabled ? model.sliceLevel : 0 }

    private func pick(at point: CGPoint, using cells: [Cell: Ink]? = nil) -> PickResult {
        pickCell(at: point, projection: projection, voxels: cells ?? voxels, workLevel: workLevel)
    }

    fileprivate var gridEnabled: Bool { model.showGrid }
    fileprivate var edgesEnabled: Bool { model.showEdges }

    fileprivate var hoverFaces: [VoxelFace] {
        if previewingPaste || objectMode { return [] }
        if gesture == .modeling { return modelingFaces }
        guard model.tool == .pick || model.editableActiveLayer != nil else { return [] }
        guard let point = hoverPoint, gesture != .orbit, gesture != .pan, gesture != .select else { return [] }
        let pick = pick(at: point, using: strokeVoxels)
        let color: V4
        switch model.tool {
        case .add, .paint: color = V4(model.ink.r, model.ink.g, model.ink.b, 0.34)
        case .erase: color = V4(0.96, 0.28, 0.23, 0.36)
        case .pick: color = V4(0.95, 0.94, 0.85, 0.3)
        case .line, .rectangle, .box, .cylinder:
            guard let first = pick.adjacent, first.inBounds, model.isEditableHeight(first.y) else { return [] }
            return boxFaces(BrushBox(min: first, max: first), tint: validMoveTint)
        case .fill, .extrude:
            guard let c = pick.hit else { return [] }
            let n = pick.normal
            guard let side = normalOffsets.firstIndex(of: SIMD3(n.x, n.y, n.z)) else { return [] }
            return [VoxelFace(base: V4(Float(c.x), Float(c.y), Float(c.z), Float(side)),
                              color: validMoveTint, ao: V4(repeating: 1))]
        case .select: return []
        }
        return model.brushBoxes(hit: pick.hit, adjacent: pick.adjacent).flatMap { boxFaces($0, tint: color) }
    }

    private func redraw() {
        if let view = metalView {
            view.setNeedsDisplay(view.bounds)
        } else {
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        if let drag = objectDrag, drag.projection.size != bounds.size {
            cancelObjectDrag(duringViewUpdate: true)
        }
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: objectMode && !previewingPaste ? .arrow : .crosshair)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        hoverPoint = point(e)
        if gesture == nil { positionPaste(at: point(e)) }
        redraw()
    }

    private func positionPaste(at p: CGPoint) {
        guard let fragment = model.pendingPaste else { return }
        let hit = pick(at: p)
        guard bounds.contains(p), var anchor = hit.adjacent else {
            model.updatePasteAnchor(nil)
            return
        }
        // An outward-facing negative side touches the high end of the fragment's bounds.
        let n = hit.normal
        if n.x < 0 { anchor.x -= fragment.size.x - 1 }
        if n.y < 0 { anchor.y -= fragment.size.y - 1 }
        if n.z < 0 { anchor.z -= fragment.size.z - 1 }
        model.updatePasteAnchor(anchor)
    }

    override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }

    override func mouseExited(with e: NSEvent) {
        hoverPoint = nil
        redraw()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        cancelPointerGesture()
        synchronize(model: model, camera: camera)
        if e.modifierFlags.contains(.shift) { gesture = .pan }
        else if e.modifierFlags.contains(.option) { gesture = .orbit }
        else if let fragment = model.pendingPaste {
            pressedFragment = fragment
            gesture = .paste
            positionPaste(at: point(e))
            redraw()
        } else if objectMode {
            beginObjectDrag(at: point(e))
        } else if model.tool == .select {
            let start = point(e)
            let pick = pick(at: start)
            let additive = e.modifierFlags.contains(.command)
            if e.clickCount == 2, !additive, let hit = pick.hit {
                model.selectConnected(at: hit)
                synchronize(model: model, camera: camera)
                return
            }
            var moveAxis: Int?
            if !additive, let hit = pick.hit, let adjacent = pick.adjacent, model.selection.contains(hit) {
                moveAxis = hit.x != adjacent.x ? 0 : hit.y != adjacent.y ? 1 : 2
            }
            selectionDrag = SelectionDrag(start: start, hit: pick.hit, additive: additive,
                                          layerID: model.activeLayerID, moveAxis: moveAxis, projection: projection)
            gesture = .select
            redraw()
        } else if [.line, .rectangle, .box, .cylinder, .extrude].contains(model.tool) {
            beginModeling(at: point(e))
        } else if model.tool == .fill {
            if let hit = pick(at: point(e)).hit { _ = model.floodFill(at: hit) }
            synchronize(model: model, camera: camera)
        } else {
            guard bounds.intersection(visibleRect).contains(point(e)) else { return }
            gesture = .paint
            strokeVoxels = voxels
            model.beginStroke()
            applyStroke(at: point(e))
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        cancelPointerGesture()
        gesture = e.modifierFlags.contains(.shift) ? .pan : .orbit
        redraw()
    }

    override func otherMouseDown(with e: NSEvent) {
        cancelPointerGesture()
        gesture = .pan
        redraw()
    }

    private func applyStroke(at point: CGPoint) {
        guard model.hasActiveStroke else {
            cancelPointerGesture()
            synchronize(model: model, camera: camera)
            return
        }
        let previous = lastStrokePoint
        lastStrokePoint = point
        let canvas = bounds.intersection(visibleRect)
        hoverPoint = canvas.contains(point) ? point : nil
        guard previous != point,
              let (start, end) = clippedStroke(from: previous ?? point, to: point, in: canvas) else {
            redraw()
            return
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = Int(ceil(distance / max(2, CGFloat(projection.scale) * 0.33)))
        let first = steps > 0 && previous.map(canvas.contains) == true ? 1 : 0
        for index in first...steps {
            let fraction = CGFloat(index) / CGFloat(max(1, steps))
            let sample = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                 y: start.y + (end.y - start.y) * fraction)
            let hit = pick(at: sample, using: strokeVoxels)
            model.apply(hit: hit.hit, adjacent: hit.adjacent)
        }
        synchronize(model: model, camera: camera)
    }

    // AppKit keeps delivering drags outside this view until the button is released.
    private func clippedStroke(from start: CGPoint, to end: CGPoint, in rect: CGRect) -> (CGPoint, CGPoint)? {
        guard !rect.isEmpty else { return nil }
        if rect.contains(start) && rect.contains(end) { return (start, end) }
        var enter: CGFloat = 0, exit: CGFloat = 1
        func intersects(_ origin: CGFloat, _ delta: CGFloat, min lower: CGFloat, max upper: CGFloat) -> Bool {
            if delta == 0 { return origin >= lower && origin <= upper }
            let a = (lower - origin) / delta, b = (upper - origin) / delta
            enter = max(enter, min(a, b))
            exit = min(exit, max(a, b))
            return enter <= exit
        }
        let dx = end.x - start.x, dy = end.y - start.y
        guard intersects(start.x, dx, min: rect.minX, max: rect.maxX.nextDown),
              intersects(start.y, dy, min: rect.minY, max: rect.maxY.nextDown) else { return nil }
        func point(_ t: CGFloat) -> CGPoint { CGPoint(x: start.x + t * dx, y: start.y + t * dy) }
        return (point(enter), point(exit))
    }

    private func beginModeling(at p: CGPoint) {
        let pick = pick(at: p)
        guard model.editableActiveLayer != nil else {
            NSSound.beep()
            return
        }
        let anchor: Cell
        var face: Set<Cell> = []
        if model.tool == .extrude {
            guard let hit = pick.hit else { return }
            face = model.extrusionFace(at: hit, normal: pick.normal)
            guard !face.isEmpty else { return }
            anchor = hit
        } else {
            guard let start = pick.adjacent, start.inBounds, model.isEditableHeight(start.y) else { return }
            anchor = start
        }
        gesture = .modeling
        modelingDrag = ModelingDrag(tool: model.tool, start: p, anchor: anchor, normal: pick.normal,
                                    layerID: model.activeLayerID, projection: projection, face: face)
        updateModeling(at: p)
    }

    private func shapeEnd(for drag: ModelingDrag, at p: CGPoint) -> Cell {
        let n = drag.normal, axis = n.x != 0 ? 0 : n.y != 0 ? 1 : 2
        let anchor = SIMD3(drag.anchor.x, drag.anchor.y, drag.anchor.z)
        let normal = SIMD3(n.x, n.y, n.z)
        let projection = drag.projection
        let plane = projection.planePoint(p)
        // Intersect every pointer ray with the original face, even if it crosses other geometry.
        let coordinate = Float(anchor[axis] + (normal[axis] < 0 ? 1 : 0))
        guard abs(projection.eye[axis]) > 0.000001 else { return drag.anchor }
        let world = plane + projection.eye * ((coordinate - plane[axis]) / projection.eye[axis])
        var result = SIMD3(Int(floor(world.x)), Int(floor(world.y)), Int(floor(world.z)))
        let horizontal = Cell.horizontalRange, vertical = Cell.verticalRange
        result.x = min(horizontal.upperBound, max(horizontal.lowerBound, result.x))
        result.z = min(horizontal.upperBound, max(horizontal.lowerBound, result.z))
        result.y = min(model.sliceEnabled ? model.sliceLevel : vertical.upperBound, max(vertical.lowerBound, result.y))
        let thickness = drag.tool.usesShapeDepth ? min(Cell.gridSize, max(1, model.shapeDepth)) : 1
        result[axis] = anchor[axis] + normal[axis] * (thickness - 1)
        return cell(result)
    }

    private func updateModeling(at p: CGPoint) {
        guard var drag = modelingDrag else { return }
        if drag.tool == .extrude {
            let n = drag.normal
            let direction = V3(Float(n.x), Float(n.y), Float(n.z))
            let projected = SIMD2(simd_dot(direction, drag.projection.right), simd_dot(direction, drag.projection.up))
            let motion = SIMD2(Float(p.x - drag.start.x), Float(p.y - drag.start.y))
            let lengthSquared = simd_length_squared(projected)
            // A face seen head-on has no usable screen-space normal. Drag up to pull it toward the camera.
            let amount = lengthSquared < 0.04 ? motion.y : simd_dot(motion, projected) / lengthSquared
            let depth = min(Cell.gridSize, max(0, Int((amount / drag.projection.scale).rounded())))
            guard depth != drag.depth else { return }
            drag.depth = depth
            drag.allowed = depth > 0 && model.canExtrude(drag.face, normal: n, depth: depth)
            let tint = depth == 0 || drag.allowed ? validMoveTint : invalidMoveTint
            modelingFaces = extrusionPreview(drag.face, normal: n, depth: depth, tint: tint)
            let blocked = depth > 0 && !drag.allowed ? " · Blocked" : ""
            camera.gestureReadout = "Extrude · \(depth) \(depth == 1 ? "voxel" : "voxels")" + blocked
        } else {
            let end = shapeEnd(for: drag, at: p)
            let wall = drag.tool.usesShapeDepth ? model.effectiveWallThickness : 0
            guard drag.end != end || drag.wallThickness != wall else { return }
            drag.end = end
            drag.wallThickness = wall
            let a = drag.anchor
            let bounds = BrushBox(a, end)
            let previewProfile = drag.tool == .cylinder || (drag.tool == .box && wall > 0)
            let shape = previewProfile
                ? VoxelShape(profileFor: drag.tool, in: bounds, normal: drag.normal, wallThickness: wall)
                : VoxelShape(tool: drag.tool, from: a, to: end)
            drag.allowed = end.inBounds && model.isEditableHeight(end.y) && shape?.fitsOperationLimit == true
            let tint = drag.allowed ? validMoveTint : invalidMoveTint
            if drag.tool == .line, let shape {
                modelingFaces = shape.lineCells.flatMap { boxFaces(BrushBox(min: $0, max: $0), tint: tint) }
            } else if previewProfile, let shape {
                modelingFaces.removeAll(keepingCapacity: true)
                shape.forEachProfileFace { patch, normal in
                    if let side = normalOffsets.firstIndex(of: SIMD3(normal.x, normal.y, normal.z)) {
                        modelingFaces.append(boxFace(patch, side: side, tint: tint))
                    }
                }
            } else {
                modelingFaces = boxFaces(bounds, tint: tint)
            }
            let size = "\(bounds.size.x) × \(bounds.size.y) × \(bounds.size.z)"
            let blocked = drag.allowed ? "" : " · Blocked"
            camera.gestureReadout = "\(drag.tool.rawValue.capitalized) · \(size) (X × Y × Z)" + blocked
        }
        modelingDrag = drag
        redraw()
    }

    private func extrusionPreview(_ patch: Set<Cell>, normal: Cell, depth: Int, tint: V4) -> [VoxelFace] {
        let direction = SIMD3(normal.x, normal.y, normal.z)
        guard let front = normalOffsets.firstIndex(of: direction) else { return [] }
        var result: [VoxelFace] = []
        for source in patch {
            let position = SIMD3(source.x, source.y, source.z)
            let end = position &+ direction &* depth
            result.append(VoxelFace(base: V4(float3(end), Float(front)), color: tint, ao: V4(repeating: 1)))
            if depth == 0 { continue }
            let first = position &+ direction
            let base = float3(SIMD3(min(first.x, end.x), min(first.y, end.y), min(first.z, end.z)))
            let dimensions = V3(repeating: 1) + abs(float3(direction)) * Float(depth - 1)
            for (side, n) in normalOffsets.enumerated()
            where side / 2 != front / 2 && !patch.contains(cell(position &+ n)) {
                result.append(VoxelFace(base: V4(base, Float(side)), color: tint, ao: V4(repeating: 1),
                                        extent: V4(dimensions, 0)))
            }
        }
        return result
    }

    private func finishModeling(at p: CGPoint) {
        updateModeling(at: p)
        guard let drag = modelingDrag else { return }
        cancelModeling()
        guard drag.allowed else {
            if drag.tool != .extrude || drag.depth > 0 { NSSound.beep() }
            return
        }
        if drag.tool == .extrude {
            _ = model.extrude(drag.face, normal: drag.normal, depth: drag.depth)
        } else if let end = drag.end {
            _ = model.addShape(tool: drag.tool, from: drag.anchor, to: end, normal: drag.normal)
        }
        synchronize(model: model, camera: camera)
    }

    private func cancelModeling(duringViewUpdate: Bool = false) {
        modelingDrag = nil
        modelingFaces = []
        if gesture == .modeling { gesture = nil }
        if duringViewUpdate {
            // SwiftUI may be synchronizing the representable in this call.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.modelingDrag == nil, self.objectDrag == nil else { return }
                self.camera.gestureReadout = nil
            }
        } else { camera.gestureReadout = nil }
    }

    private func updateSelectionDrag(at p: CGPoint) {
        guard var drag = selectionDrag else { return }
        guard drag.moved || hypot(p.x - drag.start.x, p.y - drag.start.y) >= 3 else { return }
        drag.moved = true
        selectionDrag = drag
        if let axis = drag.moveAxis {
            guard let delta = drag.projection.dragOffset(from: drag.start, to: p, onFaceAxis: axis) else { return }
            if delta != moveOffset {
                moveOffset = delta
                moveAllowed = model.canMoveSelection(by: delta)
            }
        } else {
            marquee.frame = CGRect(x: min(p.x, drag.start.x), y: min(p.y, drag.start.y),
                                   width: abs(p.x - drag.start.x), height: abs(p.y - drag.start.y))
            marquee.isHidden = false
        }
        redraw()
    }

    private func finishSelection(at p: CGPoint) {
        updateSelectionDrag(at: p)
        guard let drag = selectionDrag else { return }
        let offset = moveOffset, allowed = moveAllowed, rect = marquee.frame
        cancelSelectionDrag()
        if !drag.moved {
            if let hit = drag.hit { model.select([hit], mode: drag.additive ? .toggle : .replace) }
            else if !drag.additive { model.clearSelection() }
        } else if drag.moveAxis != nil {
            if allowed { _ = model.moveSelection(by: offset) }
        } else if let layer = model.editableActiveLayer {
            var captured = Set<Cell>()
            for c in layer.cells.keys {
                let center = V3(Float(c.x) + 0.5, Float(c.y) + 0.5, Float(c.z) + 0.5)
                if rect.contains(drag.projection.project(center)) { captured.insert(c) }
            }
            model.select(captured, mode: drag.additive ? .add : .replace)
        }
        synchronize(model: model, camera: camera)
    }

    private func cancelSelectionDrag() {
        selectionDrag = nil
        moveOffset = Cell(0, 0, 0)
        moveAllowed = false
        marquee.isHidden = true
        if gesture == .select { gesture = nil }
    }

    private func beginObjectDrag(at point: CGPoint) {
        guard bounds.intersection(visibleRect).contains(point) else { return }
        let pick = pick(at: point)
        guard let hit = pick.hit, let layer = model.sceneLayer(at: hit) else { return }
        if model.activeLayerID != layer.id { model.activeLayerID = layer.id }
        onScenePick?(layer.id)
        guard objectMode, let object = model.activeSceneObject, model.activeLayerID == layer.id else {
            synchronize(model: model, camera: camera)
            return
        }
        let n = pick.normal
        objectDrag = ObjectDrag(start: point, objectID: object.id, layerID: layer.id, projectID: model.projectID,
                                revision: model.revision, interactionRevision: model.interactionRevision,
                                faceAxis: n.x != 0 ? 0 : n.y != 0 ? 1 : 2,
                                projection: projection, framing: camera.framing)
        gesture = .object
        synchronize(model: model, camera: camera)
    }

    private func isCurrent(_ drag: ObjectDrag) -> Bool {
        objectMode && !previewingPaste && drag.projectID == model.projectID && drag.revision == model.revision &&
            drag.layerID == model.activeLayerID && drag.interactionRevision == model.interactionRevision &&
            drag.projection == projection && drag.framing == camera.framing
    }

    private func updateObjectDrag(at point: CGPoint) {
        guard let drag = objectDrag else { return }
        guard isCurrent(drag) else { cancelObjectDrag(); redraw(); return }
        let offset: Cell
        if hypot(point.x - drag.start.x, point.y - drag.start.y) < 3 {
            offset = Cell(0, 0, 0)
        } else {
            guard let delta = drag.projection.dragOffset(from: drag.start, to: point, onFaceAxis: drag.faceAxis) else { return }
            offset = delta
        }
        guard offset != moveOffset else { return }
        moveOffset = offset
        moveAllowed = hasMovePreview && model.canMoveObject(drag.objectID, by: offset)
        if hasMovePreview {
            let blocked = moveAllowed ? "" : " · Blocked"
            camera.gestureReadout = "Move object · X \(offset.x)  Y \(offset.y)  Z \(offset.z)" + blocked
        } else {
            camera.gestureReadout = nil
        }
        redraw()
    }

    private func finishObjectDrag(at point: CGPoint) {
        updateObjectDrag(at: point)
        guard let drag = objectDrag else { return }
        let offset = moveOffset, allowed = moveAllowed
        cancelObjectDrag()
        if allowed { _ = model.moveObject(drag.objectID, by: offset) }
        synchronize(model: model, camera: camera)
    }

    private func cancelObjectDrag(duringViewUpdate: Bool = false) {
        guard objectDrag != nil else { return }
        objectDrag = nil
        gesture = nil
        moveOffset = Cell(0, 0, 0)
        moveAllowed = false
        if duringViewUpdate {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.objectDrag == nil, self.modelingDrag == nil else { return }
                if self.camera.gestureReadout != nil { self.camera.gestureReadout = nil }
            }
        } else if camera.gestureReadout != nil {
            camera.gestureReadout = nil
        }
    }

    private func cancelPasteGesture() {
        pressedFragment = nil
        if gesture == .paste { gesture = nil }
    }

    private func cancelPointerGesture(duringViewUpdate: Bool = false) {
        if gesture == .object { cancelObjectDrag(duringViewUpdate: duringViewUpdate) }
        if gesture == .paste { cancelPasteGesture() }
        if gesture == .select { cancelSelectionDrag() }
        if gesture == .modeling { cancelModeling(duringViewUpdate: duringViewUpdate) }
        if gesture == .paint {
            model.endStroke()
            strokeVoxels = nil
            lastStrokePoint = nil
            gesture = nil
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if previewingPaste {
            cancelPasteGesture()
            model.cancelPaste()
        } else if gesture == .modeling {
            cancelModeling()
        } else if objectMode {
            cancelObjectDrag()
        } else if gesture == .select {
            cancelSelectionDrag()
        } else if model.tool == .select {
            model.clearSelection()
        } else {
            super.cancelOperation(sender)
            return
        }
        synchronize(model: model, camera: camera)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, objectMode || previewingPaste || model.tool == .select || gesture == .modeling {
            cancelOperation(self)
        } else {
            super.keyDown(with: e)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if previewingPaste && (gesture == .select || gesture == .modeling || gesture == .paint) {
            synchronize(model: model, camera: camera)
        }
        switch gesture {
        case .object: updateObjectDrag(at: point(e))
        case .paint: applyStroke(at: point(e))
        case .select: updateSelectionDrag(at: point(e))
        case .paste:
            positionPaste(at: point(e))
            redraw()
        case .modeling: updateModeling(at: point(e))
        case .pan:
            let v = projection
            camera.pan -= (v.right * Float(e.deltaX) - v.up * Float(e.deltaY)) / v.scale
            redraw()
        case .orbit:
            camera.orbit(dx: e.deltaX, dy: e.deltaY)
            redraw()
        case nil: break
        }
    }

    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }

    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }

    override func mouseUp(with e: NSEvent) {
        // A keyboard command may have changed the active interaction since mouse-down.
        synchronize(model: model, camera: camera)
        if gesture == .paste {
            let canPlace = e.type == .leftMouseUp && pressedFragment === model.pendingPaste
            cancelPasteGesture()
            if canPlace {
                positionPaste(at: point(e))
                if !model.commitPaste() { NSSound.beep() }
            }
            synchronize(model: model, camera: camera)
        }
        if gesture == .modeling { finishModeling(at: point(e)) }
        if gesture == .paint {
            if e.type == .leftMouseUp { applyStroke(at: point(e)) }
            model.endStroke()
        }
        if gesture == .select { finishSelection(at: point(e)) }
        if gesture == .object {
            if e.type == .leftMouseUp { finishObjectDrag(at: point(e)) } else { cancelObjectDrag() }
        }
        lastStrokePoint = nil
        strokeVoxels = nil
        gesture = nil
        hoverPoint = bounds.contains(point(e)) ? point(e) : nil
        redraw()
    }

    override func rightMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func scrollWheel(with e: NSEvent) {
        cancelPointerGesture()
        let amount = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.009 : 0.12)
        camera.zoom(by: exp(max(-1, min(1, amount))))
        redraw()
    }

    override func magnify(with e: NSEvent) {
        cancelPointerGesture()
        camera.zoom(by: max(0.5, 1 + Float(e.magnification)))
        redraw()
    }

    private func makeShadowImage() -> CGImage? {
        let count = scene.ground.shadowSize
        var pixels = [UInt8]()
        pixels.reserveCapacity(count * count * 4)
        for a in scene.ground.shadow {
            pixels.append(contentsOf: [0, 0, 0, a / 6])
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: count, height: count, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: count * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard metalView == nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawScene(in: ctx, includeEditorOverlays: true)
    }

    func drawScene(in ctx: CGContext, includeEditorOverlays: Bool) {
        if !includeEditorOverlays { synchronize(model: model, camera: camera) }
        if softwareShadow == nil { softwareShadow = makeShadowImage() }
        let projection = self.projection
        let colors = self.colors
        let bg = colors.background
        ctx.setFillColor(red: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: 1)
        ctx.fill(bounds)
        if let image = softwareShadow, projection.eye.y > 0.0001 {
            let o = scene.ground.shadowOrigin, end = o + scene.ground.shadowSpan
            let p = projection.project(V3(o.x, 0, end.y))
            let u = projection.project(V3(end.x, 0, end.y))
            let v = projection.project(V3(o.x, 0, o.y))
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: u.x - p.x, b: u.y - p.y, c: v.x - p.x, d: v.y - p.y,
                                              tx: p.x, ty: p.y))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }
        if model.showGrid, projection.eye.y > 0.02 {
            let lower = Cell.horizontalRange.lowerBound, upper = Cell.horizontalRange.upperBound + 1
            let step = projection.gridStep
            let height = Float(workLevel)
            let majorStep = step * 4
            for major in [false, true] {
                ctx.beginPath()
                for i in stride(from: lower, through: upper, by: step) where i.isMultiple(of: majorStep) == major {
                    let f = Float(i)
                    ctx.move(to: projection.project(V3(f, height, Float(lower))))
                    ctx.addLine(to: projection.project(V3(f, height, Float(upper))))
                    ctx.move(to: projection.project(V3(Float(lower), height, f)))
                    ctx.addLine(to: projection.project(V3(Float(upper), height, f)))
                }
                ctx.setLineWidth(major ? 0.72 : 0.52)
                let grid = colors.grid
                ctx.setStrokeColor(red: CGFloat(grid.x), green: CGFloat(grid.y), blue: CGFloat(grid.z),
                                   alpha: major ? 0.23 : 0.13)
                ctx.strokePath()
            }
        }
        // Painter's order is exact for axis-aligned grid faces viewed orthographically.
        var geometry = scene.worldFaces()
        var invalidPreview = [VoxelFace]()
        if includeEditorOverlays {
            geometry.append(contentsOf: hoverFaces)
            if !previewingPaste { geometry.append(contentsOf: selectionFaces) }
            if let placement = ghostPlacement {
                let offset = placement.offset
                let delta = V4(Float(offset.x), Float(offset.y), Float(offset.z), 0)
                let preview = selectionFaces.map { f -> VoxelFace in
                    var ghost = f
                    ghost.base += delta
                    if let tint = placement.tint { ghost.color = tint }
                    return ghost
                }
                if placement.allowed {
                    geometry.append(contentsOf: preview)
                } else {
                    invalidPreview = preview
                }
            }
        }
        func visibleFaces(_ faces: [VoxelFace]) -> [VoxelFace] {
            faces.filter { face in
                simd_dot(float3(normalOffsets[Int(face.base.w)]), projection.eye) > 0.00001
            }.sorted { a, b in
                func depth(_ f: VoxelFace) -> Float {
                    let extent = V3(f.extent.x, f.extent.y, f.extent.z)
                    let center = origin(f) + (0.5 + float3(normalOffsets[Int(f.base.w)]) * 0.5) * extent
                    return simd_dot(center, projection.eye) + (f.color.w < 1 ? 0.018 : 0)
                }
                return depth(a) < depth(b)
            }
        }
        let faces = visibleFaces(geometry) + visibleFaces(invalidPreview)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(false)
        for face in faces {
            let side = Int(face.base.w), isHover = face.color.w < 1
            let points = vertices(face).map(projection.project)
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            let a = face.ao
            let light = CGFloat(faceLight[side] * (a.x+a.y+a.z+a.w) * 0.25)
            ctx.setFillColor(red: min(1, CGFloat(face.color.x) * light),
                             green: min(1, CGFloat(face.color.y) * light),
                             blue: min(1, CGFloat(face.color.z) * light), alpha: CGFloat(face.color.w))
            ctx.addPath(path)
            ctx.fillPath()
            if model.showEdges || isHover {
                ctx.addPath(path)
                ctx.setLineWidth(isHover ? 1.4 : 0.52)
                let edge = face.extent.w == 2 ? face.color : isHover ? colors.hoverEdge : V4(0.15, 0.17, 0.17, 1)
                ctx.setStrokeColor(red: CGFloat(edge.x), green: CGFloat(edge.y), blue: CGFloat(edge.z),
                                   alpha: isHover ? 0.94 : 0.2)
                ctx.strokePath()
            }
        }
    }
}

private struct MetalUniforms {
    var right: V4
    var up: V4
    var eye: V4
    var target: V4
    var flags, background, grid, hoverEdge, shadowMap, volume: V4
    var overlayOffset = V4.zero, overlayTint = V4.zero
}

private final class MetalPainter: NSObject, MTKViewDelegate {
    weak var surface: StudioViewportSurface?
    private let queue: MTLCommandQueue
    private let modelPipeline: MTLRenderPipelineState
    private let floorPipeline: MTLRenderPipelineState
    private let solidDepth: MTLDepthStencilState
    private let hoverDepth: MTLDepthStencilState
    private let throughDepth: MTLDepthStencilState
    private var selectedInstances: MTLBuffer?
    private var selectedCount = 0
    private let device: MTLDevice
    private var draws = [MeshDraw]()
    private var shadow: MTLTexture?
    private var shadowMap = V4.zero

    init(device: MTLDevice, view: MTKView) throws {
        let error = NSError(domain: "VoxelStudio", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Metal resource unavailable"])
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw error }
        self.queue = queue
        let lib = try device.makeLibrary(source: Self.shader, options: nil)
        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: vertex)
            desc.fragmentFunction = lib.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            desc.rasterSampleCount = view.sampleCount
            if blending {
                let attachment = desc.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        modelPipeline = try pipeline("face_vertex", "face_fragment", blending: true)
        floorPipeline = try pipeline("floor_vertex", "floor_fragment", blending: false)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        guard let solids = device.makeDepthStencilState(descriptor: depth) else { throw error }
        solidDepth = solids
        depth.isDepthWriteEnabled = false
        guard let overlays = device.makeDepthStencilState(descriptor: depth) else { throw error }
        hoverDepth = overlays
        depth.depthCompareFunction = .always
        guard let through = device.makeDepthStencilState(descriptor: depth) else { throw error }
        throughDepth = through
        super.init()
    }

    func setSelection(_ faces: [VoxelFace]) {
        selectedCount = faces.count
        selectedInstances = faces.withUnsafeBytes { bytes in
            guard !bytes.isEmpty, let start = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: start, length: bytes.count, options: .storageModeShared)
        }
    }

    func update(_ scene: RenderScene) {
        draws = scene.draws
        for draw in draws where draw.mesh.metalBuffer == nil {
            draw.mesh.metalBuffer = draw.mesh.faces.withUnsafeBytes { bytes in
                guard !bytes.isEmpty, let start = bytes.baseAddress else { return nil }
                return device.makeBuffer(bytes: start, length: bytes.count, options: .storageModeShared)
            }
        }
        let n = scene.ground.shadowSize
        shadowMap = V4(scene.ground.shadowOrigin.x, scene.ground.shadowOrigin.y, scene.ground.shadowSpan, 0)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n,
                                                            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        // Older command buffers can keep reading the previous snapshot while editing.
        let texture = device.makeTexture(descriptor: desc)
        scene.ground.shadow.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: start, bytesPerRow: n)
        }
        shadow = texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay(view.bounds) }

    func draw(in view: MTKView) {
        guard let surface, let shadow, view.bounds.width > 0, view.bounds.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let p = surface.projection
        let colors = surface.colors
        var u = MetalUniforms(right: V4(p.right, Float(p.size.width) / (2 * p.scale)),
                              up: V4(p.up, Float(p.size.height) / (2 * p.scale)),
                              eye: V4(p.eye, Float(surface.workLevel)), target: V4(p.target, 0),
                              flags: V4(surface.gridEnabled ? 1 : 0, surface.edgesEnabled ? 1 : 0,
                                        Float(view.drawableSize.width / max(1, view.bounds.width)), Float(p.gridStep)),
                              background: colors.background, grid: colors.grid, hoverEdge: colors.hoverEdge,
                              shadowMap: shadowMap,
                              volume: V4(GridVolume.low.x, GridVolume.high.x, GridVolume.center.y, GridVolume.depth))
        enc.setVertexBytes(&u, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<MetalUniforms>.stride, index: 1)
        enc.setRenderPipelineState(floorPipeline)
        enc.setFragmentTexture(shadow, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.setRenderPipelineState(modelPipeline)
        enc.setDepthStencilState(solidDepth)
        for draw in draws {
            guard let buffer = draw.mesh.metalBuffer else { continue }
            var placement = draw.placement
            enc.setVertexBytes(&placement, length: MemoryLayout<MeshPlacement>.stride, index: 2)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: draw.mesh.faces.count)
        }
        var identity = MeshPlacement.identity
        enc.setVertexBytes(&identity, length: MemoryLayout<MeshPlacement>.stride, index: 2)
        let hover = surface.hoverFaces
        if !hover.isEmpty {
            enc.setDepthStencilState(hoverDepth)
            hover.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    if bytes.count <= 4096 {
                        enc.setVertexBytes(base, length: bytes.count, index: 0)
                    } else if let buffer = device.makeBuffer(bytes: base, length: bytes.count,
                                                             options: .storageModeShared) {
                        enc.setVertexBuffer(buffer, offset: 0, index: 0)
                    } else { return }
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: hover.count)
                }
            }
        }
        if let selectedInstances, selectedCount > 0 {
            enc.setVertexBuffer(selectedInstances, offset: 0, index: 0)
            if !surface.previewingPaste {
                enc.setDepthStencilState(hoverDepth)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: selectedCount)
            }
            if let placement = surface.ghostPlacement {
                let d = placement.offset
                u.overlayOffset = V4(Float(d.x), Float(d.y), Float(d.z), 0)
                u.overlayTint = placement.tint ?? .zero
                enc.setVertexBytes(&u, length: MemoryLayout<MetalUniforms>.stride, index: 1)
                enc.setDepthStencilState(placement.allowed ? hoverDepth : throughDepth)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: selectedCount)
            }
        }
        enc.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4 right, up, eye, target, flags, background, grid, hoverEdge, shadowMap, volume, overlayOffset, overlayTint; };
    struct Placement { float4 x, y, z; uint4 sides0, sides1; };
    struct Face { float4 base, color, ao, extent; };
    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
        float facing;
        float selection;
    };
    struct GroundOut { float4 position [[position]]; float2 ndc; };
    constant float3 normals[] = {float3(1,0,0),float3(-1,0,0),float3(0,1,0),
                                 float3(0,-1,0),float3(0,0,1),float3(0,0,-1)};
    constant float lighting[] = {0.79,0.87,1.04,0.65,0.96,0.83};
    constant uint indices[] = {0,1,2,0,2,3};
    constant float2 uv4[] = {float2(0,0),float2(1,0),float2(1,1),float2(0,1)};

    vertex VertexOut face_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device Face *faces [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                                 constant Placement &placement [[buffer(2)]]) {
        Face f = faces[iid];
        uint localSide = uint(f.base.w);
        uint mapping = localSide < 4 ? placement.sides0[localSide] : placement.sides1[localSide - 4];
        uint side = mapping & 7u;
        uint corner = indices[vid];
        float2 uv = uv4[corner];
        float3 offset = side < 2 ? float3(0,uv.y,uv.x)
                      : side < 4 ? float3(uv.x,0,uv.y) : float3(uv,0);
        if (side % 2 == 0) offset += normals[side];
        float4 base = float4(f.base.xyz, 1.0);
        float3 placed = float3(dot(placement.x,base),dot(placement.y,base),dot(placement.z,base));
        // Model faces are unit squares. Extended overlays are already in world coordinates.
        float3 world = placed + offset * f.extent.xyz + u.overlayOffset.xyz;
        uint localCorner = (mapping >> (3u + 2u * corner)) & 3u;
        if (u.overlayTint.a > 0.0) f.color = u.overlayTint;
        float3 p = world - u.target.xyz;
        float depth = dot(world - float3(0,u.volume.z,0),u.eye.xyz)/u.volume.w;
        VertexOut out;
        out.position = float4(dot(p,u.right.xyz)/u.right.w, dot(p,u.up.xyz)/u.up.w,
                              0.5-depth-(f.color.a < 1.0 ? 0.00004 : 0.0), 1.0);
        out.color = float4(saturate(f.color.rgb * lighting[side] * f.ao[localCorner]),f.color.a);
        out.uv = uv;
        out.facing = dot(normals[side],u.eye.xyz);
        out.selection = f.extent.w;
        return out;
    }

    fragment float4 face_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (in.facing < 0.00001) discard_fragment();
        float2 pixel = max(fwidth(in.uv),float2(0.000001));
        float2 border = min(in.uv,1.0-in.uv) / pixel;
        bool hover = in.color.a < 1.0;
        float thickness = (hover ? 1.1 : 0.33) * u.flags.z;
        float edge = 1.0 - smoothstep(thickness * 0.25, thickness+0.5, min(border.x,border.y));
        float edgeAmount = hover ? 0.8 : 0.18*u.flags.y;
        float3 outline = in.selection == 2.0 ? in.color.rgb : hover ? u.hoverEdge.rgb : float3(0.14,0.17,0.16);
        return float4(mix(in.color.rgb,outline,edge*edgeAmount),
                      hover ? mix(in.color.a,0.98,edge) : 1.0);
    }

    vertex GroundOut floor_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
        GroundOut out;
        out.position = float4(p, 0.9999, 1.0);
        out.ndc = p;
        return out;
    }
    float grid_line(float2 p, float thickness) {
        float2 pixels = abs(fract(p-0.5)-0.5) / max(fwidth(p), float2(0.0001));
        return 1.0 - smoothstep(thickness * 0.2,thickness+0.5,min(pixels.x,pixels.y));
    }
    fragment float4 floor_fragment(GroundOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                   texture2d<float> shadow [[texture(0)]]) {
        float3 background = u.background.rgb;
        if (u.eye.y < 0.0001) return float4(background,1);
        float3 p = u.target.xyz + u.right.xyz * (in.ndc.x*u.right.w) + u.up.xyz*(in.ndc.y*u.up.w);
        float3 ground = p - u.eye.xyz * (p.y/u.eye.y);
        p -= u.eye.xyz * ((p.y-u.eye.w)/u.eye.y);
        constexpr sampler sampleShadow(coord::normalized,address::clamp_to_edge,filter::linear);
        float shade = shadow.sample(sampleShadow,(ground.xz-u.shadowMap.xy)/u.shadowMap.z).r;
        background *= (1.0 - 0.16 * shade);
        float minor = grid_line(p.xz/u.flags.w,0.33*u.flags.z);
        float major = grid_line(p.xz/(4.0*u.flags.w),0.45*u.flags.z);
        bool inGrid = all(p.xz >= u.volume.x) && all(p.xz <= u.volume.y);
        float grid = inGrid ? max(minor*0.13,major*0.23) * u.flags.x : 0.0;
        return float4(mix(background,u.grid.rgb,grid),1.0);
    }
    """
}
