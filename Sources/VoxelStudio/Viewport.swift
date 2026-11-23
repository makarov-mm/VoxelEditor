import AppKit
import MetalKit
import SwiftUI
import simd

private typealias V3 = SIMD3<Float>
private typealias V4 = SIMD4<Float>

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
        case "front": yaw = 0; pitch = 0
        case "top": yaw = 0; pitch = .pi / 2
        case "right": yaw = .pi / 2; pitch = 0
        default: yaw = 0.63; pitch = 0.48
        }
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

    func makeNSView(context: Context) -> StudioViewportSurface {
        StudioViewportSurface(model: model, camera: camera)
    }

    func updateNSView(_ nsView: StudioViewportSurface, context: Context) {
        nsView.synchronize(model: model, camera: camera)
    }
}

private struct SceneProjection {
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

    func planePoint(_ p: CGPoint) -> V3 {
        target + right * Float(p.x - size.width * 0.5) / scale
            + up * Float(p.y - size.height * 0.5) / scale
    }
}

private struct VoxelFace {
    var base: V4
    var color: V4
    var ao: V4
    var extent = V4(repeating: 1)
}

private let normalOffsets = [SIMD3<Int>(1,0,0), SIMD3<Int>(-1,0,0),
                             SIMD3<Int>(0,1,0), SIMD3<Int>(0,-1,0),
                             SIMD3<Int>(0,0,1), SIMD3<Int>(0,0,-1)]
private let corners = [SIMD2<Int>(0,0), SIMD2<Int>(1,0), SIMD2<Int>(1,1), SIMD2<Int>(0,1)]
private let basisU = [SIMD3<Int>(0,0,1), SIMD3<Int>(0,0,1), SIMD3<Int>(1,0,0), SIMD3<Int>(1,0,0), SIMD3<Int>(1,0,0), SIMD3<Int>(1,0,0)]
private let basisV = [SIMD3<Int>(0,1,0), SIMD3<Int>(0,1,0), SIMD3<Int>(0,0,1), SIMD3<Int>(0,0,1), SIMD3<Int>(0,1,0), SIMD3<Int>(0,1,0)]
private let faceLight: [Float] = [0.79, 0.87, 1.04, 0.65, 0.96, 0.83]

private func cell(_ p: SIMD3<Int>) -> Cell { Cell(p.x, p.y, p.z) }
private func float3(_ p: SIMD3<Int>) -> V3 { V3(Float(p.x), Float(p.y), Float(p.z)) }
private func origin(_ f: VoxelFace) -> V3 { V3(f.base.x, f.base.y, f.base.z) }

private func vertices(_ face: VoxelFace) -> [V3] {
    let side = Int(face.base.w)
    let extent = V3(face.extent.x, face.extent.y, face.extent.z)
    let start = origin(face) + (side % 2 == 0 ? float3(normalOffsets[side]) * extent : .zero)
    let u = float3(basisU[side]) * extent, v = float3(basisV[side]) * extent
    return [start, start + u, start + u + v, start + v]
}

private struct SceneGeometry {
    var faces: [VoxelFace] = []
    var centers: [V3] = []
    var shadow = [UInt8]()
    let shadowSize: Int
    let shadowOrigin: SIMD2<Float>
    let shadowSpan: Float

    init(_ voxels: [Cell: Ink]) {
        // Keep the shadow texture around the projected geometry even for off-center models.
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for c in voxels.keys {
            let center = SIMD2(Float(c.x) + Float(c.y) * 0.31, Float(c.z) - Float(c.y) * 0.19)
            lo = simd_min(lo, center)
            hi = simd_max(hi, center + 1)
        }
        if voxels.isEmpty { lo = .zero; hi = .zero }
        shadowSpan = max(8, max(hi.x - lo.x, hi.y - lo.y) + 8)
        shadowOrigin = (lo + hi - SIMD2(repeating: shadowSpan)) * 0.5
        shadowSize = max(20, min(640, Int(ceil(shadowSpan * 2))))
        let side = shadowSize
        var shadowField = [Float](repeating: 0, count: side * side)
        let resolution = Float(side) / shadowSpan
        centers.reserveCapacity(min(65_536, voxels.count))
        faces.reserveCapacity(min(131_072, voxels.count * 2))
        for (c, ink) in voxels {
            let xyz = SIMD3(c.x, c.y, c.z)
            let p = float3(xyz)
            let firstFace = faces.count
            let rgb = V4(ink.r, ink.g, ink.b, 1)
            for faceID in 0..<6 {
                let n = xyz &+ normalOffsets[faceID]
                guard voxels[cell(n)] == nil else { continue }
                var ao = V4(repeating: 1)
                for j in 0..<4 {
                    let u = basisU[faceID] &* (corners[j].x * 2 - 1)
                    let v = basisV[faceID] &* (corners[j].y * 2 - 1)
                    let a = voxels[cell(n &+ u)] != nil, b = voxels[cell(n &+ v)] != nil
                    let d = voxels[cell(n &+ u &+ v)] != nil
                    let level = a && b ? 3 : (a ? 1 : 0) + (b ? 1 : 0) + (d ? 1 : 0)
                    ao[j] = 1 - Float(level) * 0.045
                }
                faces.append(VoxelFace(base: V4(p, Float(faceID)), color: rgb, ao: ao))
            }
            guard faces.count > firstFace else { continue }
            centers.append(p + 0.5)
            // Project each cell onto the ground in the opposite direction to the key light.
            let sx = (p.x + p.y * 0.31 - shadowOrigin.x) * resolution
            let sz = (p.z - p.y * 0.19 - shadowOrigin.y) * resolution
            let value = max(0.4, 1 - p.y * 0.012)
            let x0 = max(0, min(side - 1, Int(floor(sx)))), x1 = max(x0, min(side - 1, Int(ceil(sx + resolution))))
            let z0 = max(0, min(side - 1, Int(floor(sz)))), z1 = max(z0, min(side - 1, Int(ceil(sz + resolution))))
            for z in z0...z1 {
                for x in x0...x1 {
                    let i = z * side + x
                    shadowField[i] = max(shadowField[i], value)
                }
            }
        }
        let weights: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
        var horizontal = shadowField
        for y in 0..<side {
            for x in 2..<(side - 2) {
                let i = y * side + x
                horizontal[i] = (0..<5).reduce(0) { $0 + shadowField[i + $1 - 2] * weights[$1] }
            }
        }
        shadow = [UInt8](repeating: 0, count: side * side)
        for y in 2..<(side - 2) {
            for x in 0..<side {
                let i = y * side + x
                let value = (0..<5).reduce(Float(0)) { $0 + horizontal[i + ($1 - 2) * side] * weights[$1] }
                shadow[i] = UInt8(clamping: Int((value * 255).rounded()))
            }
        }
    }
}

private struct PickResult {
    var hit: Cell?
    var adjacent: Cell?
}

private func pickCell(at point: CGPoint, projection: SceneProjection, voxels: [Cell:Ink]) -> PickResult {
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
        if min(a,b) > near {
            near = min(a,b)
            entryNormal = .zero
            entryNormal[axis] = ray[axis] > 0 ? -1 : 1
        }
        far = min(far, max(a,b))
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
        let p = start + ray * (-start.y / ray.y)
        if p.x >= low.x, p.x < high.x, p.z >= low.z, p.z < high.z {
            return PickResult(hit: nil, adjacent: Cell(Int(floor(p.x)), 0, Int(floor(p.z))))
        }
    }
    return PickResult()
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

private let selectionTint = V4(0.12, 0.68, 0.91, 0.46)
private let validMoveTint = V4(0.24, 0.91, 0.59, 0.53)
private let invalidMoveTint = V4(1.00, 0.25, 0.20, 0.58)

final class StudioViewportSurface: NSView {
    private var model: EditorModel
    private var camera: OrbitCamera
    private var voxels: [Cell: Ink] = [:]
    private var scene = SceneGeometry([:])
    private var revision: Int?
    private var requestedFrame: Int?
    private var baseTarget = V3.zero
    private var fit = SIMD2<Float>(30, 30)
    private var metalView: MTKView?
    private var painter: MetalPainter?
    private var softwareShadow: CGImage?
    private var tracking: NSTrackingArea?
    private var hoverPoint: CGPoint?
    private var strokeVoxels: [Cell:Ink]?
    private var lastStrokePoint: CGPoint?
    private let marquee = NSView()
    private var selectionDrag: SelectionDrag?
    private var displayedSelection = Set<Cell>()
    private var selectionFaces = [VoxelFace]()
    fileprivate var moveOffset = Cell(0,0,0)
    fileprivate var moveAllowed = false
    fileprivate var hasMovePreview: Bool { moveOffset != Cell(0,0,0) }
    fileprivate var moveTint: V4 { moveAllowed ? validMoveTint : invalidMoveTint }
    private enum Gesture { case paint, orbit, pan, select }
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
        self.model = model
        self.camera = camera
        if gesture == .select && (model.tool != .select || revision != model.revision ||
                                  selectionDrag?.layerID != model.activeLayerID || displayedSelection != model.selection ||
                                  requestedFrame != camera.framing) {
            cancelSelectionDrag()
        }
        if revision != model.revision {
            revision = model.revision
            voxels = model.visibleCells
            scene = SceneGeometry(voxels)
            softwareShadow = nil
            painter?.update(scene)
        }
        updateSelectionShell()
        if requestedFrame != camera.framing {
            requestedFrame = camera.framing
            frameScene()
        }
        redraw()
    }

    private func updateSelectionShell() {
        let cells = model.tool == .select ? model.selection : []
        guard cells != displayedSelection else { return }
        displayedSelection = cells
        selectionFaces.removeAll(keepingCapacity: !cells.isEmpty)
        for c in cells {
            let pos = SIMD3(c.x,c.y,c.z)
            for (side, n) in normalOffsets.enumerated() where !cells.contains(cell(pos &+ n)) {
                selectionFaces.append(VoxelFace(base: V4(float3(pos), Float(side)), color: selectionTint,
                                                ao: V4(repeating: 1), extent: V4(1,1,1,2)))
            }
        }
        painter?.setSelection(selectionFaces)
    }

    private func frameScene() {
        guard !scene.centers.isEmpty else {
            baseTarget = .zero
            fit = SIMD2(32, 28)
            return
        }
        let a = camera.axes
        var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
        for p in scene.centers {
            let v = V3(simd_dot(p, a.right), simd_dot(p, a.up), simd_dot(p, a.eye))
            lo = simd_min(lo,v)
            hi = simd_max(hi,v)
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

    fileprivate var gridEnabled: Bool { model.showGrid }
    fileprivate var edgesEnabled: Bool { model.showEdges }

    fileprivate var hoverFaces: [VoxelFace] {
        guard let point = hoverPoint, gesture != .orbit, gesture != .pan, gesture != .select else { return [] }
        let pick = pickCell(at: point, projection: projection, voxels: strokeVoxels ?? voxels)
        let color: V4
        switch model.tool {
        case .add, .paint: color = V4(model.ink.r, model.ink.g, model.ink.b, 0.34)
        case .erase: color = V4(0.96,0.28,0.23,0.36)
        case .pick: color = V4(0.95,0.94,0.85,0.3)
        case .select: return []
        }
        return model.brushBoxes(hit: pick.hit, adjacent: pick.adjacent).flatMap { box in
            let c = box.min
            let extent = V4(Float(box.max.x - c.x + 1), Float(box.max.y - c.y + 1), Float(box.max.z - c.z + 1), 0)
            return (0..<6).map { side in
                VoxelFace(base: V4(Float(c.x), Float(c.y), Float(c.z), Float(side)),
                          color: color, ao: V4(repeating: 1), extent: extent)
            }
        }
    }

    private func redraw() {
        if let view = metalView { view.setNeedsDisplay(view.bounds) } else { needsDisplay = true }
    }

    override func layout() {
        super.layout()
        metalView?.frame = bounds
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseMoved(with e: NSEvent) { hoverPoint = point(e); redraw() }
    override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseExited(with e: NSEvent) { hoverPoint = nil; redraw() }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.modifierFlags.contains(.shift) { gesture = .pan }
        else if e.modifierFlags.contains(.option) { gesture = .orbit }
        else if model.tool == .select {
            let start = point(e)
            let pick = pickCell(at: start, projection: projection, voxels: voxels)
            let additive = e.modifierFlags.contains(.command)
            var moveAxis: Int?
            if !additive, let hit = pick.hit, let adjacent = pick.adjacent, model.selection.contains(hit) {
                moveAxis = hit.x != adjacent.x ? 0 : hit.y != adjacent.y ? 1 : 2
            }
            selectionDrag = SelectionDrag(start: start, hit: pick.hit, additive: additive,
                                          layerID: model.activeLayerID, moveAxis: moveAxis, projection: projection)
            gesture = .select
            redraw()
        } else {
            gesture = .paint
            strokeVoxels = voxels
            model.beginStroke()
            applyStroke(at: point(e))
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        if gesture == .select { cancelSelectionDrag() }
        gesture = e.modifierFlags.contains(.shift) ? .pan : .orbit
        redraw()
    }
    override func otherMouseDown(with e: NSEvent) {
        if gesture == .select { cancelSelectionDrag() }
        gesture = .pan
        redraw()
    }

    private func applyStroke(at p: CGPoint) {
        let from = lastStrokePoint ?? p
        let d = hypot(p.x - from.x, p.y - from.y)
        let steps = min(256, max(1, Int(ceil(d / max(2, CGFloat(projection.scale) * 0.33)))))
        let projection = self.projection
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let q = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
            let hit = pickCell(at: q, projection: projection, voxels: strokeVoxels ?? voxels)
            model.apply(hit: hit.hit, adjacent: hit.adjacent)
        }
        lastStrokePoint = p
        hoverPoint = p
        synchronize(model: model, camera: camera)
    }

    private func updateSelectionDrag(at p: CGPoint) {
        guard var drag = selectionDrag else { return }
        guard drag.moved || hypot(p.x - drag.start.x, p.y - drag.start.y) >= 3 else { return }
        drag.moved = true
        selectionDrag = drag
        if let axis = drag.moveAxis {
            let proj = drag.projection
            let screenDelta = proj.planePoint(p) - proj.planePoint(drag.start)
            // Intersect both pointer rays with the starting face plane. Its normal coordinate stays fixed.
            guard abs(proj.eye[axis]) > 0.00001 else { return }
            var world = screenDelta - proj.eye * (screenDelta[axis] / proj.eye[axis])
            world[axis] = 0
            let delta = Cell(Int(world.x.rounded()), Int(world.y.rounded()), Int(world.z.rounded()))
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
        } else if let layer = model.layers.first(where: { $0.id == model.activeLayerID && $0.isVisible }) {
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
        moveOffset = Cell(0,0,0)
        moveAllowed = false
        marquee.isHidden = true
        if gesture == .select { gesture = nil }
    }

    override func cancelOperation(_ sender: Any?) {
        if gesture == .select { cancelSelectionDrag() }
        else if model.tool == .select { model.clearSelection() }
        else { super.cancelOperation(sender); return }
        synchronize(model: model, camera: camera)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, model.tool == .select { cancelOperation(self) }
        else { super.keyDown(with: e) }
    }

    override func mouseDragged(with e: NSEvent) {
        switch gesture {
        case .paint: applyStroke(at: point(e))
        case .select: updateSelectionDrag(at: point(e))
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
        if gesture == .paint { model.endStroke() }
        if gesture == .select { finishSelection(at: point(e)) }
        lastStrokePoint = nil
        strokeVoxels = nil
        gesture = nil
        hoverPoint = bounds.contains(point(e)) ? point(e) : nil
        redraw()
    }
    override func rightMouseUp(with e: NSEvent) { mouseUp(with: e) }
    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }
    override func scrollWheel(with e: NSEvent) {
        if gesture == .select { cancelSelectionDrag() }
        let amount = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.009 : 0.12)
        camera.zoom(by: exp(max(-1, min(1, amount))))
        redraw()
    }
    override func magnify(with e: NSEvent) {
        if gesture == .select { cancelSelectionDrag() }
        camera.zoom(by: max(0.5, 1 + Float(e.magnification)))
        redraw()
    }

    private func makeShadowImage() -> CGImage? {
        let count = scene.shadowSize
        var pixels = [UInt8]()
        pixels.reserveCapacity(count * count * 4)
        for a in scene.shadow {
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
            let o = scene.shadowOrigin, end = o + scene.shadowSpan
            let p = projection.project(V3(o.x,0,end.y)), u = projection.project(V3(end.x,0,end.y)), v = projection.project(V3(o.x,0,o.y))
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a:u.x-p.x, b:u.y-p.y, c:v.x-p.x, d:v.y-p.y, tx:p.x, ty:p.y))
            ctx.draw(image, in: CGRect(x:0, y:0, width:1, height:1))
            ctx.restoreGState()
        }
        if model.showGrid, projection.eye.y > 0.02 {
            let lower = Cell.horizontalRange.lowerBound, upper = Cell.horizontalRange.upperBound + 1
            let step = projection.gridStep
            let majorStep = step * 4
            for major in [false,true] {
                ctx.beginPath()
                for i in stride(from: lower, through: upper, by: step) where i.isMultiple(of: majorStep) == major {
                    let f = Float(i)
                    ctx.move(to: projection.project(V3(f,0,Float(lower))))
                    ctx.addLine(to: projection.project(V3(f,0,Float(upper))))
                    ctx.move(to: projection.project(V3(Float(lower),0,f)))
                    ctx.addLine(to: projection.project(V3(Float(upper),0,f)))
                }
                ctx.setLineWidth(major ? 0.72 : 0.52)
                let grid = colors.grid
                ctx.setStrokeColor(red: CGFloat(grid.x), green: CGFloat(grid.y), blue: CGFloat(grid.z),
                                   alpha: major ? 0.23 : 0.13)
                ctx.strokePath()
            }
        }
        // Painter's order is exact for axis-aligned grid faces viewed orthographically.
        var geometry = scene.faces
        var invalidPreview = [VoxelFace]()
        if includeEditorOverlays {
            geometry.append(contentsOf: selectionFaces)
            geometry.append(contentsOf: hoverFaces)
            if hasMovePreview {
                let delta = V4(Float(moveOffset.x), Float(moveOffset.y), Float(moveOffset.z), 0)
                let preview = selectionFaces.map { f -> VoxelFace in
                    var ghost = f
                    ghost.base += delta
                    ghost.color = moveTint
                    return ghost
                }
                if moveAllowed { geometry.append(contentsOf: preview) }
                else { invalidPreview = preview }
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
                let edge = face.extent.w == 2 ? face.color : isHover ? colors.hoverEdge : V4(0.15,0.17,0.17,1)
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
    private var instances: MTLBuffer?
    private var count = 0
    private var shadow: MTLTexture?
    private var shadowMap = V4.zero

    init(device: MTLDevice, view: MTKView) throws {
        let error = NSError(domain: "VoxelStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Metal resource unavailable"])
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

    func update(_ scene: SceneGeometry) {
        count = scene.faces.count
        if scene.faces.isEmpty { instances = nil }
        else {
            instances = scene.faces.withUnsafeBytes {
                guard let start = $0.baseAddress else { return nil }
                return device.makeBuffer(bytes: start, length: $0.count, options: .storageModeShared)
            }
        }
        let n = scene.shadowSize
        shadowMap = V4(scene.shadowOrigin.x, scene.shadowOrigin.y, scene.shadowSpan, 0)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        // Older command buffers can keep reading the previous snapshot while editing.
        let texture = device.makeTexture(descriptor: desc)
        scene.shadow.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0,0,n,n), mipmapLevel: 0, withBytes: start, bytesPerRow: n)
        }
        shadow = texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay(view.bounds) }

    func draw(in view: MTKView) {
        guard let surface, let shadow, view.bounds.width > 0, view.bounds.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let p = surface.projection
        let colors = surface.colors
        var u = MetalUniforms(right: V4(p.right, Float(p.size.width) / (2 * p.scale)),
                              up: V4(p.up, Float(p.size.height) / (2 * p.scale)),
                              eye: V4(p.eye, 0), target: V4(p.target, 0),
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
        if let instances, count > 0 {
            enc.setVertexBuffer(instances, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        let hover = surface.hoverFaces
        if !hover.isEmpty {
            enc.setDepthStencilState(hoverDepth)
            hover.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    enc.setVertexBytes(base, length: bytes.count, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: hover.count)
                }
            }
        }
        if let selectedInstances, selectedCount > 0 {
            enc.setDepthStencilState(hoverDepth)
            enc.setVertexBuffer(selectedInstances, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: selectedCount)
            if surface.hasMovePreview {
                let d = surface.moveOffset
                u.overlayOffset = V4(Float(d.x),Float(d.y),Float(d.z),0)
                u.overlayTint = surface.moveTint
                enc.setVertexBytes(&u, length: MemoryLayout<MetalUniforms>.stride, index: 1)
                enc.setDepthStencilState(surface.moveAllowed ? hoverDepth : throughDepth)
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
                                 const device Face *faces [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Face f = faces[iid];
        uint side = uint(f.base.w);
        uint corner = indices[vid];
        float2 uv = uv4[corner];
        float3 offset = side < 2 ? float3(0,uv.y,uv.x)
                      : side < 4 ? float3(uv.x,0,uv.y) : float3(uv,0);
        if (side % 2 == 0) offset += normals[side];
        float3 world = f.base.xyz + offset * f.extent.xyz + u.overlayOffset.xyz;
        if (u.overlayTint.a > 0.0) f.color = u.overlayTint;
        float3 p = world - u.target.xyz;
        float depth = dot(world - float3(0,u.volume.z,0),u.eye.xyz)/u.volume.w;
        VertexOut out;
        out.position = float4(dot(p,u.right.xyz)/u.right.w, dot(p,u.up.xyz)/u.up.w,
                              0.5-depth-(f.color.a < 1.0 ? 0.00004 : 0.0), 1.0);
        out.color = float4(saturate(f.color.rgb * lighting[side] * f.ao[corner]),f.color.a);
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
        p -= u.eye.xyz*(p.y/u.eye.y);
        constexpr sampler sampleShadow(coord::normalized,address::clamp_to_edge,filter::linear);
        float shade = shadow.sample(sampleShadow,(p.xz-u.shadowMap.xy)/u.shadowMap.z).r;
        background *= (1.0 - 0.16 * shade);
        float minor = grid_line(p.xz/u.flags.w,0.33*u.flags.z);
        float major = grid_line(p.xz/(4.0*u.flags.w),0.45*u.flags.z);
        bool inGrid = all(p.xz >= u.volume.x) && all(p.xz <= u.volume.y);
        float grid = inGrid ? max(minor*0.13,major*0.23) * u.flags.x : 0.0;
        return float4(mix(background,u.grid.rgb,grid),1.0);
    }
    """
}
