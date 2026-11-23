import SwiftUI

struct Inspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ui: StudioUI
    @ViewState private var editingColor = false
    @ViewState private var customColor = Color.white
    @ViewState private var renamedLayer: UUID?
    @ViewState private var newName = ""
    @ViewState private var askingToDelete = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 8)
    private var activeLayer: VoxelLayer? { model.layers.first { $0.id == model.activeLayerID } }

    private var renaming: Binding<Bool> {
        Binding(get: { renamedLayer != nil }, set: { if !$0 { renamedLayer = nil } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium))
                Text("Inspector").font(.system(size: 15, weight: .semibold))
            }.foregroundStyle(StudioStyle.ink).padding(.horizontal, 18).frame(height: 48)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let fragment = model.pendingPaste {
                        pasteControls(fragment)
                    } else {
                        brush
                    }
                    Rule()
                    sliceSection
                    Rule()
                    if model.tool != .select && model.tool != .extrude {
                        colorSection
                        Rule()
                    }
                    layerSection
                }
            }
        }.background(StudioStyle.paper)
        .alert("Layer Name", isPresented: renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let id = renamedLayer { model.renameLayer(id, to: newName) }
                renamedLayer = nil
            }
            Button("Cancel", role: .cancel) { renamedLayer = nil }
        }
        .confirmationDialog("Delete “\(activeLayer?.name ?? "")”?", isPresented: $askingToDelete,
                            titleVisibility: .visible) {
            Button("Delete Layer", role: .destructive) { model.removeActiveLayer() }
        }
    }

    private func heading(_ name: String) -> some View {
        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioStyle.ink)
    }

    private var brush: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Tool")
                Spacer()
                Text(model.tool.shortcut).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioStyle.muted).padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(StudioStyle.rule))
            }
            HStack(spacing: 8) {
                Image(systemName: model.tool.symbol).font(.system(size: 15, weight: .medium))
                Text(model.tool.label).font(.system(size: 13, weight: .medium))
            }.foregroundStyle(StudioStyle.green)
            if model.tool == .select {
                SelectionControls(model: model, ui: ui)
            } else if model.tool == .box {
                DimensionStepper(title: "Depth", value: $model.shapeDepth, range: 1...Cell.gridSize)
                    .help("Thickness measured outward from the starting face ([ and ])")
            } else if [.add, .paint, .erase].contains(model.tool) {
                HStack {
                    Text("Brush size").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    Spacer()
                    HStack(spacing: 0) {
                        IconControl(symbol: "minus", hint: "Decrease brush size ([)", size: 23, font: 9) {
                            model.brushSize = max(1, model.brushSize - 1)
                        }.disabled(model.brushSize <= 1)
                        Text("\(model.brushSize)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced)).frame(minWidth: 19)
                        IconControl(symbol: "plus", hint: "Increase brush size (])", size: 23, font: 9) {
                            model.brushSize = min(8, model.brushSize + 1)
                        }.disabled(model.brushSize >= 8)
                    }.padding(2).overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioStyle.rule))
                }
                HStack(spacing: 5) {
                    Text("Mirror").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                    Spacer()
                    mirrorAxis("X", enabled: $model.mirrorX)
                    mirrorAxis("Z", enabled: $model.mirrorZ)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }

    private func pasteControls(_ fragment: VoxelFragment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Paste voxels", systemImage: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioStyle.green)
            let count = fragment.cells.count
            Text("\(count.formatted()) \(count == 1 ? "voxel" : "voxels")")
                .font(.system(size: 12)).monospacedDigit()
            if let p = model.pasteAnchor {
                Text("X \(p.x)   Y \(p.y)   Z \(p.z)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioStyle.secondary)
            }
            if model.pasteAnchor != nil && !model.pasteAllowed {
                Text("Choose an empty position within the grid and current slice.")
                    .font(.caption).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                Button("Place") { _ = model.commitPaste() }.disabled(!model.pasteAllowed)
                    .help("Place the voxels at the preview position (Return)")
                Button("Cancel") { model.cancelPaste() }.help("Cancel placement (Esc)")
            }.controlSize(.small)
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }

    private var sliceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $model.sliceEnabled) {
                HStack(spacing: 7) {
                    Image(systemName: "square.3.layers.3d").foregroundStyle(StudioStyle.green)
                    heading("Slice view")
                }
            }.toggleStyle(.switch).controlSize(.small)
                .help("Hide voxels above the chosen height (Y)")
            if model.sliceEnabled {
                DimensionStepper(title: "Top level (Y)", value: $model.sliceLevel, range: Cell.verticalRange)
                Slider(value: Binding(get: { Double(model.sliceLevel) },
                                      set: { model.sliceLevel = Int($0.rounded()) }),
                       in: Double(Cell.verticalRange.lowerBound)...Double(Cell.verticalRange.upperBound), step: 1)
                    .controlSize(.small).accessibilityLabel("Slice height").help("Lower or raise the slice (, and .)")
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func mirrorAxis(_ axis: String, enabled: Binding<Bool>) -> some View {
        Toggle(isOn: enabled) {
            Text(axis).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(width: 19)
        }.toggleStyle(.button).controlSize(.small)
            .accessibilityLabel("Mirror \(axis)")
            .help("Mirror brush strokes across the \(axis) = 0 plane")
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            heading("Active color")
            Button {
                customColor = model.ink.color
                editingColor = true
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5).fill(model.ink.color).frame(width: 39, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioStyle.swatchBorder.opacity(0.55)))
                    Text(model.ink.hex.uppercased()).font(.system(size: 13, weight: .medium, design: .monospaced))
                    Spacer()
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(StudioStyle.muted)
                }.padding(6).frame(maxWidth: .infinity).padding(.trailing, 5)
            }.buttonStyle(StudioButtonStyle()).overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioStyle.rule))
                .help("Edit color")
            HStack {
                heading("Palette")
                Spacer()
                IconControl(symbol: "plus", hint: "Add a palette color", size: 23, font: 11) {
                    customColor = model.ink.color
                    editingColor = true
                }
            }.padding(.top, 4)
            if model.palette.count > 40 {
                ScrollView(.vertical) { swatches.padding(1) }.frame(height: 137)
            } else {
                swatches
            }
        }.padding(.horizontal, 18).padding(.vertical, 16)
        .popover(isPresented: $editingColor, arrowEdge: .leading) {
            ColorEditor(initial: model.ink, color: $customColor) { ink in
                model.addPaletteColor(ink)
                model.ink = ink
                editingColor = false
            }
        }
    }

    private var swatches: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(model.palette.enumerated()), id: \.offset) { _, ink in
                Button { model.ink = ink } label: {
                    RoundedRectangle(cornerRadius: 4).fill(ink.color).aspectRatio(1, contentMode: .fit)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(StudioStyle.swatchBorder.opacity(0.65)))
                        .overlay {
                            if model.ink == ink {
                                RoundedRectangle(cornerRadius: 4).inset(by: 1.5).stroke(.white, lineWidth: 2)
                                RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.82), lineWidth: 1.3)
                            }
                        }
                }.buttonStyle(.plain).help(ink.hex).accessibilityLabel("Choose color \(ink.hex)")
            }
        }
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                heading("Layers")
                Text("\(model.layers.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioStyle.muted).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(StudioStyle.rail)).overlay(Capsule().stroke(StudioStyle.rule))
                Spacer()
                IconControl(symbol: "minus", hint: "Delete active layer", size: 23, font: 11) {
                    askingToDelete = true
                }.disabled(model.layers.count <= 1)
                IconControl(symbol: "plus", hint: "New layer", size: 23, font: 11) { model.addLayer() }
            }.padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(model.layers.reversed()) { layer in
                let selected = layer.id == model.activeLayerID
                HStack(spacing: 2) {
                    Button { model.activeLayerID = layer.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.3.layers.3d").font(.system(size: 15))
                                .foregroundStyle(selected ? StudioStyle.green : StudioStyle.muted)
                            Text(layer.name).lineLimit(1)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Select “\(layer.name)”")
                    IconControl(symbol: layer.isVisible ? "eye" : "eye.slash",
                                hint: layer.isVisible ? "Hide layer" : "Show layer", size: 28, font: 12) {
                        model.toggleLayer(layer.id)
                    }.padding(.trailing, 4)
                }.foregroundStyle(StudioStyle.ink).opacity(layer.isVisible ? 1 : 0.55)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.pale : .clear))
                    .contextMenu {
                        Button("Rename…") {
                            newName = layer.name
                            renamedLayer = layer.id
                        }
                        Button(layer.isVisible ? "Hide" : "Show") { model.toggleLayer(layer.id) }
                        Button("Delete…", role: .destructive) {
                            model.activeLayerID = layer.id
                            askingToDelete = true
                        }.disabled(model.layers.count <= 1)
                    }
            }
        }.padding(.horizontal, 10).padding(.vertical, 13)
    }
}

private struct SelectionControls: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ui: StudioUI

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.selection.count.formatted()) selected").monospacedDigit()
                Spacer()
                Button("All") { model.selectAllOnActiveLayer() }.help("Select all voxels on this layer (⌘A)")
                Button("Clear") { model.clearSelection() }.disabled(model.selection.isEmpty)
                    .help("Clear selection (Esc)")
            }.font(.system(size: 11)).controlSize(.small)
            Text("Move one voxel").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            HStack(spacing: 5) {
                nudgeAxis("X", direction: Cell(1, 0, 0))
                nudgeAxis("Y", direction: Cell(0, 1, 0))
                nudgeAxis("Z", direction: Cell(0, 0, 1))
            }.disabled(model.selection.isEmpty)
            HStack(spacing: 5) {
                Text("Rotate 90°").font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
                Spacer()
                ForEach(VoxelAxis.allCases, id: \.self) { axis in
                    let label = axis.rawValue.uppercased()
                    Button(label) { ui.rotate(axis, in: model) }
                        .controlSize(.small).accessibilityLabel("Rotate 90° around \(label)")
                        .help("Rotate the selection 90° around \(label)")
                }
            }.disabled(model.selection.isEmpty)
            HStack(spacing: 6) {
                Button("Cut") { ui.copySelection(model, cutting: true) }.help("Cut selected voxels (⌘X)")
                Button("Copy") { ui.copySelection(model) }.help("Copy selected voxels (⌘C)")
                Button("Delete") { _ = model.deleteSelection() }.help("Delete selected voxels (Delete)")
            }.controlSize(.small).disabled(model.selection.isEmpty)
            Button { ui.duplicate(model) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }.controlSize(.small).disabled(model.selection.isEmpty)
                .help("Place a copy beside the selection (⌘D)")
            if let notice = ui.selectionNotice {
                Text(notice).font(.caption).foregroundStyle(StudioStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func nudgeAxis(_ axis: String, direction: Cell) -> some View {
        HStack(spacing: 1) {
            IconControl(symbol: "minus", hint: "Move −\(axis)", size: 21, font: 9) {
                ui.nudge(Cell(-direction.x, -direction.y, -direction.z), in: model)
            }
            Text(axis).font(.system(size: 11, weight: .medium, design: .monospaced))
            IconControl(symbol: "plus", hint: "Move +\(axis)", size: 21, font: 9) {
                ui.nudge(direction, in: model)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioStyle.rule))
    }
}

private struct DimensionStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(StudioStyle.secondary)
            Spacer()
            TextField(title, value: Binding(get: { value },
                                            set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                      format: .number.grouping(.never))
                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .font(.system(size: 11, design: .monospaced)).frame(width: 44)
                .accessibilityLabel(title)
            Stepper(title, value: $value, in: range).labelsHidden().controlSize(.small)
        }
    }
}

private struct ColorEditor: View {
    let initial: Ink
    @Binding var color: Color
    let accept: (Ink) -> Void
    @ViewState private var hex = ""
    private var valid: Bool {
        hex.range(of: "^#?[A-Fa-f0-9]{6}$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voxel color").font(.headline)
            ColorPicker("Choose color", selection: $color, supportsOpacity: false)
            TextField("#RRGGBB", text: $hex).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { if valid { accept(Ink(hex: hex)) } }
            Button("Apply") { accept(Ink(hex: hex)) }
                .disabled(!valid).buttonStyle(.borderedProminent).tint(StudioStyle.accentFill)
        }.padding(16).frame(width: 220)
            .onAppear { hex = initial.hex }
            .onChange(of: color) { value in
                guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                hex = Ink(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent)).hex
            }
    }
}
