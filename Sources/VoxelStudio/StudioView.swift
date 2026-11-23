import AppKit
import SwiftUI

final class StudioUI: ObservableObject {
    @Published var showingHelp = false
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
                Inspector(model: model).frame(width: 256)
            }
            Rule()
            status
        }.foregroundStyle(StudioStyle.ink).background(StudioStyle.paper)
            .onChange(of: model.projectID) { _ in camera.reset() }
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
                IconControl(symbol: "arrow.uturn.backward", hint: "Undo (⌘Z)") { model.undo() }.disabled(!model.canUndo)
                IconControl(symbol: "arrow.uturn.forward", hint: "Redo (⇧⌘Z)") { model.redo() }.disabled(!model.canRedo)
            }
            Rule(vertical: true).frame(height: 19)
            Menu {
                Button("New Project…") { model.newProject() }
                Button("Open Project…") { model.openProject() }
                Button("Open Demo Scene…") { model.loadDemo() }
                Divider()
                Button("Save As…") { model.saveProject(asNew: true) }
                Divider()
                Button("Import MagicaVoxel (.vox)…") { model.importVOX() }
                Button("Export MagicaVoxel (.vox)…") { model.exportVOX() }.disabled(!model.layers.contains { !$0.cells.isEmpty })
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
                    .foregroundStyle(StudioStyle.primaryLabel).background(RoundedRectangle(cornerRadius: 6).fill(StudioStyle.ink))
            }.buttonStyle(.plain).help("Save project (⌘S)")
        }.padding(.horizontal, 18).frame(height: 54).background(StudioStyle.paper)
    }

    private var rail: some View {
        VStack(spacing: 7) {
            ForEach(EditTool.allCases, id: \.self) { tool in
                IconControl(symbol: tool.symbol, hint: "\(tool.label) (\(tool.shortcut))", size: 40, font: 18,
                            selected: model.tool == tool) { model.tool = tool }
            }
            Rule().frame(width: 24).padding(.vertical, 5)
            IconControl(symbol: "grid", hint: "Grid (G)", size: 40, font: 16, selected: model.showGrid) { model.showGrid.toggle() }
            IconControl(symbol: "cube.transparent", hint: "Voxel edges (W)", size: 40, font: 17,
                        selected: model.showEdges) { model.showEdges.toggle() }
            Spacer(minLength: 12)
            IconControl(symbol: "questionmark.circle", hint: "Controls", size: 36, font: 17) { ui.showingHelp.toggle() }
                .popover(isPresented: $ui.showingHelp, arrowEdge: .trailing) { HelpCard() }
        }.padding(.vertical, 12).frame(maxHeight: .infinity).frame(width: 58).background(StudioStyle.rail)
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
                            Text("\(Cell.gridSize) × \(Cell.gridSize) × \(Cell.gridSize)").font(.system(size: 10, weight: .medium, design: .monospaced))
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
                        IconControl(symbol: "viewfinder", hint: "Frame scene (F)", size: 28, font: 13) { camera.reset() }
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

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(StudioStyle.green).frame(width: 5, height: 5)
            Text(model.tool.label).fontWeight(.medium)
            Text("·").foregroundStyle(StudioStyle.muted)
            Text(model.tool.instruction).foregroundStyle(StudioStyle.muted).lineLimit(1)
            Spacer()
            Image(systemName: "cube").font(.system(size: 10))
            Text("\(model.voxelCount.formatted(.number.locale(.current))) voxels")
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
        VStack(alignment: .leading, spacing: 11) {
            Text("Controls").font(.system(size: 17, weight: .semibold)).padding(.bottom, 3)
            row("Draw", "Click or drag")
            row("Orbit", "⌥ + drag or right-drag")
            row("Pan", "⇧ + drag")
            row("Zoom", "Scroll or pinch")
            row("Frame scene", "F")
            Rule()
            ForEach(EditTool.allCases, id: \.self) { row($0.label, $0.shortcut) }
            row("Brush size", "[   ]")
            row("Grid / edges", "G / W")
            Rule()
            Text("Select the layer you want to paint or erase in the inspector.")
                .font(.system(size: 11)).foregroundStyle(StudioStyle.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 272).foregroundStyle(StudioStyle.ink).background(StudioStyle.paper)
    }
    private func row(_ action: String, _ shortcut: String) -> some View {
        HStack {
            Text(action).font(.system(size: 12))
            Spacer()
            Text(shortcut).font(.system(size: 11, weight: .medium)).foregroundStyle(StudioStyle.secondary)
        }
    }
}
