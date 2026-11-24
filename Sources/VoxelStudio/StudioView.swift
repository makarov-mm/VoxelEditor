import AppKit
import SwiftUI

final class StudioUI: ObservableObject {
    private static let fragmentType = NSPasteboard.PasteboardType("studio.forma.voxel.fragment.v1")
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @Published var showingHelp = false
    @Published var showingParts = false
    @Published var selectionNotice: String?

    func canPaste(into model: EditorModel) -> Bool {
        model.pendingPaste == nil && model.editableActiveLayer != nil &&
            pasteboard.availableType(from: [Self.fragmentType]) != nil
    }

    func copySelection(_ model: EditorModel, cutting: Bool = false) {
        guard model.pendingPaste == nil, !model.selection.isEmpty else { return }
        guard let fragment = model.selectionFragment() else {
            selectionNotice = model.selection.count > VoxelFragment.maxCells
                ? "Copy a smaller selection (up to \(VoxelFragment.maxCells.formatted()) voxels)."
                : "Select editable voxels on the active layer to copy."
            return
        }
        do {
            let data = try fragment.encoded()
            let item = NSPasteboardItem()
            guard item.setData(data, forType: Self.fragmentType) else {
                selectionNotice = "The clipboard could not prepare these voxels. Try copying again."
                return
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else {
                selectionNotice = "The clipboard is unavailable. Try copying again."
                return
            }
            if cutting { _ = model.deleteSelection() }
            selectionNotice = nil
        } catch {
            selectionNotice = "Copy a smaller selection and try again. " + error.localizedDescription
        }
    }

    func startPaste(in model: EditorModel) {
        guard canPaste(into: model) else { return }
        guard let data = pasteboard.data(forType: Self.fragmentType) else {
            selectionNotice = "The copied voxels could not be read. Copy the fragment again."
            return
        }
        do {
            let fragment = try VoxelFragment.decode(data)
            selectionNotice = model.beginPaste(fragment) ? nil : "Choose a visible, unlocked layer to paste into."
        } catch {
            selectionNotice = error.localizedDescription
        }
    }

    func duplicate(_ model: EditorModel) {
        selectionNotice = model.duplicateSelection() ? nil : "There is no room for a copy beside this selection."
    }

    func selectByColor(in model: EditorModel) {
        selectionNotice = nil
        model.selectByColor()
    }

    func recolorSelection(in model: EditorModel) {
        selectionNotice = model.recolorSelection() ? nil : "The selected voxels already use the active color."
    }

    func rotate(_ axis: VoxelAxis, in model: EditorModel) {
        selectionNotice = model.rotateSelection(around: axis)
            ? nil : "Rotation blocked by an occupied voxel, the grid edge, or the slice limit."
    }

    func nudge(_ delta: Cell, in model: EditorModel) {
        selectionNotice = model.moveSelection(by: delta)
            ? nil : "Move blocked by an occupied voxel, the grid edge, or the slice limit."
    }
}

private let viewOptions = [("iso", "Isometric"), ("front", "Front"), ("top", "Top"), ("right", "Right")]

struct StudioView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var camera: OrbitCamera
    @ObservedObject var ui: StudioUI

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            HStack(spacing: 0) {
                rail.frame(width: 58)
                Rule(vertical: true)
                workspace
                Rule(vertical: true)
                Inspector(model: model, ui: ui).frame(width: 256)
            }
            Rule()
            status
        }.foregroundStyle(StudioStyle.ink).background(StudioStyle.paper)
            .sheet(isPresented: $ui.showingParts) { PartsLibraryView(model: model) }
            .onChange(of: model.projectID) { _ in camera.reset() }
            .onChange(of: model.ink) { _ in ui.selectionNotice = nil }
            .onChange(of: model.selection) { _ in ui.selectionNotice = nil }
            .onChange(of: model.revision) { _ in ui.selectionNotice = nil }
            .tint(StudioStyle.green)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandCube().frame(width: 25, height: 29)
            Text("Forma").font(.system(size: 25, weight: .bold, design: .rounded)).tracking(-1.5)
            Rule(vertical: true).frame(height: 21).padding(.horizontal, 2)
            Text("VOXEL STUDIO").font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2).foregroundStyle(StudioStyle.muted)
            Spacer(minLength: 10)
            HStack(spacing: 1) {
                IconControl(symbol: "arrow.uturn.backward", hint: "Undo (⌘Z)") { model.undo() }
                    .disabled(!model.canUndo)
                IconControl(symbol: "arrow.uturn.forward", hint: "Redo (⇧⌘Z)") { model.redo() }
                    .disabled(!model.canRedo)
            }
            Rule(vertical: true).frame(height: 19)
            Button { ui.showingParts = true } label: {
                Label("Parts", systemImage: "square.grid.2x2").padding(.horizontal, 6).frame(height: 30)
            }.buttonStyle(StudioButtonStyle()).help("Open the parts library")
            Menu {
                Button("New Project…") { model.newProject() }
                Button("Open Project…") { model.openProject() }
                Button("Open Demo Scene…") { model.loadDemo() }
                Divider()
                Button("Save As…") { model.saveProject(asNew: true) }
                Divider()
                Button("Import MagicaVoxel (.vox)…") { model.importVOX() }
                Button("Export MagicaVoxel (.vox)…") { model.exportVOX() }
                    .disabled(!model.layers.contains { !$0.cells.isEmpty })
                Button("Export Scene PNG…") { camera.exportPNG() }
                Button("Export OBJ…") { model.exportOBJ() }.disabled(model.voxelCount == 0)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 13))
                    Text("File").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Project menu")
            Button { model.saveProject() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .medium))
                    Text("Save").font(.system(size: 12, weight: .semibold))
                }.padding(.horizontal, 13).frame(height: 30)
                    .foregroundStyle(StudioStyle.primaryLabel)
                    .background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.ink))
            }.buttonStyle(.plain).help("Save project (⌘S)")
        }.padding(.horizontal, 18).frame(height: 54).background(StudioStyle.paper)
    }

    private var rail: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 610
            let size: CGFloat = compact ? 29 : 37
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: compact ? 2 : 4) {
                        toolButtons([.add, .paint, .erase, .pick, .fill], size: size)
                        railDivider
                        toolButtons([.line, .rectangle, .box, .cylinder, .extrude, .select], size: size)
                        railDivider
                        IconControl(symbol: "grid", hint: "Grid (G)", size: size, font: 16, selected: model.showGrid) {
                            model.showGrid.toggle()
                        }
                        IconControl(symbol: "cube.transparent", hint: "Voxel edges (W)", size: size, font: 17,
                                    selected: model.showEdges) { model.showEdges.toggle() }
                    }.frame(maxWidth: .infinity)
                }
                IconControl(symbol: "questionmark.circle", hint: "Controls", size: size, font: 16) {
                    ui.showingHelp.toggle()
                }
                    .popover(isPresented: $ui.showingHelp, arrowEdge: .trailing) { HelpCard() }
            }.padding(.vertical, compact ? 5 : 10).frame(maxHeight: .infinity)
        }.background(StudioStyle.rail)
    }

    private var railDivider: some View { Rule().frame(width: 23).padding(.vertical, 3) }

    private func toolButtons(_ tools: [EditTool], size: CGFloat) -> some View {
        ForEach(tools, id: \.self) { tool in
            IconControl(symbol: tool.symbol, hint: "\(tool.label) (\(tool.shortcut))", size: size, font: 17,
                        selected: model.tool == tool) { model.tool = tool }
        }
    }

    private var workspace: some View {
        ZStack {
            VoxelViewport(model: model, camera: camera)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(model.title).lineLimit(1).truncationMode(.middle)
                                .font(.system(size: 23, weight: .semibold)).tracking(-0.7)
                            if model.isDirty {
                                Circle().fill(Color(rgb: 0xAD7946)).frame(width: 6, height: 6).help("Unsaved changes")
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "cube").font(.system(size: 10))
                            Text("\(Cell.gridSize) × \(Cell.gridSize) × \(Cell.gridSize)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            if model.sliceEnabled {
                                Text("·")
                                Text("Slice Y ≤ \(model.sliceLevel)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            }
                        }.foregroundStyle(StudioStyle.secondary)
                    }.allowsHitTesting(false)
                    Spacer(minLength: 10)
                    viewMenu
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Button { ui.showingHelp = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "computermouse").font(.system(size: 11))
                            Text("⌥ + drag").font(.system(size: 10, weight: .medium))
                            Text("Orbit").font(.system(size: 10))
                        }.foregroundStyle(StudioStyle.secondary).padding(.vertical, 4)
                    }.buttonStyle(.plain).help("Show controls")
                    Spacer()
                    HStack(spacing: 0) {
                        IconControl(symbol: "minus", hint: "Zoom out", size: 28, font: 10) { camera.zoomOut() }
                        Text("\(camera.zoomPercent)%").font(.system(size: 10, weight: .medium, design: .monospaced))
                            .frame(minWidth: 43).accessibilityLabel("Zoom \(camera.zoomPercent) percent")
                        IconControl(symbol: "plus", hint: "Zoom in", size: 28, font: 10) { camera.zoomIn() }
                        Rule(vertical: true).frame(height: 13).padding(.horizontal, 3)
                        IconControl(symbol: "viewfinder", hint: "Frame scene (F)", size: 28, font: 13) {
                            camera.frameScene()
                        }
                    }.padding(2).modifier(FloatingSurface())
                }
            }.padding(.horizontal, 22).padding(.vertical, 18)
        }.clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewMenu: some View {
        Menu {
            ForEach(viewOptions, id: \.0) { key, name in
                Button { camera.orient(key) } label: {
                    if camera.viewKey == key { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube").font(.system(size: 11))
                Text(viewOptions.first { $0.0 == camera.viewKey }?.1 ?? "Free orbit")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.padding(.horizontal, 9).frame(height: 27).modifier(FloatingSurface())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Camera view")
    }

    private var pasteHint: String {
        if model.stampName != nil { return "Click to stamp a copy · Esc finishes" }
        guard model.pasteAnchor != nil else { return "Move the pointer to a face or the grid · Esc cancels" }
        return model.pasteAllowed ? "Click or press Return to place · Esc cancels"
            : "Position blocked · Move to empty space inside the editable grid"
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(StudioStyle.green).frame(width: 5, height: 5)
            if model.pendingPaste != nil {
                Text(model.stampName == nil ? "Paste" : "Stamp").fontWeight(.medium)
                Text(pasteHint).lineLimit(1)
            } else if let notice = ui.selectionNotice {
                Text(notice).lineLimit(1).help(notice)
            } else if let readout = camera.gestureReadout {
                Text(readout).fontWeight(.medium).monospacedDigit().lineLimit(1)
            } else {
                Text(model.tool.label).fontWeight(.medium)
                Text("·").foregroundStyle(StudioStyle.muted)
                Text(model.tool.instruction).foregroundStyle(StudioStyle.muted).lineLimit(1)
            }
            Spacer()
            if model.tool == .select && model.pendingPaste == nil {
                Text("\(model.selection.count.formatted()) selected").monospacedDigit()
                Rule(vertical: true).frame(height: 12).padding(.horizontal, 3)
            }
            Image(systemName: "cube").font(.system(size: 10))
            Text("\(model.viewportCells.count.formatted()) voxels")
                .monospacedDigit().help("Visible voxels")
            Rule(vertical: true).frame(height: 12).padding(.horizontal, 3)
            Text(camera.rendererName).font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioStyle.muted)
        }.font(.system(size: 10)).foregroundStyle(StudioStyle.secondary)
            .padding(.horizontal, 15).frame(height: 26).background(StudioStyle.paper)
    }
}

private struct FloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 7).fill(StudioStyle.paper.opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioStyle.rule))
            .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
    }
}

private struct HelpCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Controls").font(.system(size: 17, weight: .semibold)).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    row("Draw", "Click or drag")
                    row("Orbit", "⌥ + drag or right-drag")
                    row("Pan", "⇧ + drag")
                    row("Zoom", "Scroll or pinch")
                    row("Frame scene", "F")
                    Rule()
                    ForEach(EditTool.allCases, id: \.self) { row($0.label, $0.shortcut) }
                    row("Brush size / shape depth", "[   ]")
                    row("Toggle selected voxel", "⌘ + click")
                    row("Add to selection", "⌘ + box drag")
                    row("Nudge selection or paste X / Z", "← → / ↑ ↓")
                    row("Nudge selection or paste Y", "Page Up / Down")
                    row("Cut / copy / paste voxels", "⌘X / ⌘C / ⌘V")
                    row("Place pasted voxels", "Click or Return")
                    row("Cancel placement", "Esc")
                    row("Delete selection", "Delete")
                    row("Duplicate selection", "⌘D")
                    row("Grid / edges", "G / W")
                    row("Slice view", "Y")
                    row("Lower / raise slice", ",   .")
                }
            }.frame(maxHeight: 380)
        }.padding(18).frame(width: 282).foregroundStyle(StudioStyle.ink).background(StudioStyle.paper)
    }

    private func row(_ action: String, _ shortcut: String) -> some View {
        HStack {
            Text(action).font(.system(size: 12))
            Spacer()
            Text(shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.secondary)
        }
    }
}
