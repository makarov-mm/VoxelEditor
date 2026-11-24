import SwiftUI

struct SceneNameRequest: Identifiable {
    enum Action {
        case createObject, createGroup(UUID?), renameObject(UUID), renameGroup(UUID)
    }

    let id = UUID()
    let action: Action
    let initialName: String

    init(_ action: Action, name: String = "") {
        self.action = action
        initialName = name
    }

    var title: String {
        switch action {
        case .createObject: return "Create Object from Selection"
        case .createGroup: return "New Group"
        case .renameObject: return "Rename Object"
        case .renameGroup: return "Rename Group"
        }
    }
}

struct SceneNameSheet: View {
    let request: SceneNameRequest
    @ObservedObject var model: EditorModel
    @ObservedObject var ui: StudioUI
    @ViewState private var name: String
    @ViewState private var error: String?
    @FocusState private var focused: Bool

    init(request: SceneNameRequest, model: EditorModel, ui: StudioUI) {
        self.request = request
        self.model = model
        self.ui = ui
        _name = ViewState(initialValue: request.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.headline)
            TextField("Name", text: $name).focused($focused).onSubmit(submit)
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { ui.sceneNaming = nil }.keyboardShortcut(.cancelAction)
                Button(request.initialName.isEmpty ? "Create" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }.padding(20).frame(width: 320).onAppear { focused = true }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        switch request.action {
        case .createObject:
            guard model.createObjectFromSelection(name: trimmed) else {
                error = "Select editable voxels and make room for an object layer."
                return
            }
            ui.inspectedGroupID = nil
        case let .createGroup(parent):
            guard let id = model.createGroup(name: trimmed, parentID: parent) else {
                error = "The group could not be created."
                return
            }
            ui.inspectedGroupID = id
        case let .renameObject(id):
            guard trimmed == request.initialName || model.renameObject(id, to: trimmed) else {
                error = "The object could not be renamed."
                return
            }
        case let .renameGroup(id):
            guard trimmed == request.initialName || model.renameGroup(id, to: trimmed) else {
                error = "The group could not be renamed."
                return
            }
        }
        ui.showingScene = true
        ui.sceneNaming = nil
    }
}

struct SceneTreeRow: Identifiable {
    enum Node: Hashable {
        case group(UUID), object(UUID), layer(UUID)
    }
    let id: Node
    let name: String
    let depth: Int

    static func rows(layout: SceneLayout, layers: [VoxelLayer], collapsed: Set<UUID> = []) -> [Self] {
        let children = Dictionary(grouping: layout.groups, by: \.parentID)
        let members = Dictionary(grouping: layout.objects, by: \.groupID)
        let objectLayers = Set(layout.objects.flatMap(\.layerIDs))
        var result = [Self]()
        var stack = [Self]()
        func appendChildren(of parent: UUID?, depth: Int) {
            for object in (members[parent] ?? []).reversed() {
                stack.append(Self(id: .object(object.id), name: object.name, depth: depth))
            }
            for group in (children[parent] ?? []).reversed() {
                stack.append(Self(id: .group(group.id), name: group.name, depth: depth))
            }
        }
        appendChildren(of: nil, depth: 0)
        while let row = stack.popLast() {
            result.append(row)
            if case let .group(id) = row.id, !collapsed.contains(id) {
                appendChildren(of: id, depth: row.depth + 1)
            }
        }
        for layer in layers.reversed() where !objectLayers.contains(layer.id) {
            result.append(Self(id: .layer(layer.id), name: layer.name, depth: 0))
        }
        return result
    }

    static func possibleParents(layout: SceneLayout, moving groupID: UUID?) -> [Self] {
        let all = rows(layout: layout, layers: [])
        var skippedDepth: Int?
        return all.filter { row in
            guard case let .group(id) = row.id else { return false }
            if let depth = skippedDepth, row.depth <= depth { skippedDepth = nil }
            if id == groupID { skippedDepth = row.depth }
            return skippedDepth == nil
        }
    }
}

struct SceneInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var ui: StudioUI
    @ViewState private var collapsed = Set<UUID>()
    @ViewState private var removingObject: SceneObject?
    @ViewState private var notice: String?

    private var selectedGroup: SceneGroup? {
        model.sceneLayout.groups.first { $0.id == ui.inspectedGroupID }
    }

    private var selectedNode: SceneTreeRow.Node {
        if let group = selectedGroup { return .group(group.id) }
        if let object = model.activeSceneObject { return .object(object.id) }
        return .layer(model.activeLayerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scene Hierarchy").font(.headline)
                Spacer()
                Menu {
                    Button("Object from Selection…") { ui.sceneNaming = SceneNameRequest(.createObject) }
                        .disabled(model.selection.isEmpty || model.pendingPaste != nil)
                    Button("New Group…") { ui.sceneNaming = SceneNameRequest(.createGroup(nil)) }
                } label: { Image(systemName: "plus") }
                    .fixedSize().menuStyle(.borderlessButton).help("Add an object or group")
                    .accessibilityLabel("Add to scene")
            }.padding(.horizontal, 14).frame(height: 36)
            tree
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let group = selectedGroup {
                        groupDetails(group)
                    } else if let object = model.activeSceneObject {
                        objectDetails(object)
                    } else if let layer = model.layers.first(where: { $0.id == model.activeLayerID }) {
                        Label(layer.name, systemImage: "square.3.layers.3d").font(.headline)
                        Button("Edit Layer") { ui.showingScene = false }
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }.controlSize(.small)
        .alert("Delete “\(removingObject?.name ?? "")”?", isPresented: Binding(
            get: { removingObject != nil }, set: { if !$0 { removingObject = nil } }
        ), presenting: removingObject) { object in
            Button("Delete Object", role: .destructive) {
                notice = model.removeObject(object.id) ? nil : "Unlock the object’s layers before deleting it."
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the selected object and its layers from the scene.")
        }
        .onAppear { revealSelection() }
        .onChange(of: selectedNode) { _ in
            notice = nil
            revealSelection()
        }
        .onChange(of: model.projectID) { _ in collapsed.removeAll() }
    }

    private var tree: some View {
        let rows = SceneTreeRow.rows(layout: model.sceneLayout, layers: model.layers, collapsed: collapsed)
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in treeRow(row).id(row.id) }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            .onChange(of: selectedNode) { id in reader.scrollTo(id) }
            .onAppear { reader.scrollTo(selectedNode) }
        }.frame(height: CGFloat(min(7, max(2, rows.count))) * 27 + 8)
    }

    private func treeRow(_ row: SceneTreeRow) -> some View {
        let selected = selectedNode == row.id
        return HStack(spacing: 4) {
            if case let .group(id) = row.id {
                Button {
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                } label: {
                    Image(systemName: collapsed.contains(id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 24)
                }.buttonStyle(.plain)
                    .accessibilityLabel(collapsed.contains(id) ? "Expand \(row.name)" : "Collapse \(row.name)")
            }
            Button {
                switch row.id {
                case let .group(id): ui.inspectedGroupID = id
                case let .object(id):
                    ui.inspectedGroupID = nil
                    model.selectObject(id)
                case let .layer(id):
                    ui.inspectedGroupID = nil
                    model.activeLayerID = id
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: row.id)).foregroundStyle(StudioStyle.green)
                    Text(row.name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).help(row.name)
        }.padding(.leading, 7 + CGFloat(min(7, row.depth)) * 10).padding(.trailing, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? StudioStyle.pale : .clear))
    }

    private func symbol(for node: SceneTreeRow.Node) -> String {
        switch node {
        case .group: return "folder"
        case .object: return "cube"
        case .layer: return "square.3.layers.3d"
        }
    }

    @ViewBuilder private func groupDetails(_ group: SceneGroup) -> some View {
        HStack {
            Label(group.name, systemImage: "folder").font(.headline).lineLimit(1)
            Spacer()
            Button("Rename…") { ui.sceneNaming = SceneNameRequest(.renameGroup(group.id), name: group.name) }
        }
        parentMenu(current: group.parentID, excluding: group.id) { destination in
            model.setGroupParent(group.id, to: destination)
        }
        HStack {
            Button("Add Subgroup…") { ui.sceneNaming = SceneNameRequest(.createGroup(group.id)) }
            Button("Ungroup") {
                if model.ungroup(group.id) {
                    ui.inspectedGroupID = group.parentID
                } else {
                    notice = "The group could not be removed."
                }
            }.help("Remove this group and keep its contents under the parent")
        }
    }

    @ViewBuilder private func objectDetails(_ object: SceneObject) -> some View {
        HStack {
            Label(object.name, systemImage: "cube").font(.headline).lineLimit(1)
            Spacer()
            Button("Rename…") { ui.sceneNaming = SceneNameRequest(.renameObject(object.id), name: object.name) }
        }
        parentMenu(current: object.groupID, excluding: nil) { destination in
            model.setObjectGroup(object.id, to: destination)
        }
        HStack {
            Menu("Duplicate") {
                Button("Independent Copy") { duplicate(object, linked: false) }
                Button("Linked Copy") { duplicate(object, linked: true) }
            }.fixedSize()
            Button("Make Unique") {
                notice = model.makeObjectUnique(object.id) ? nil : "This object could not be unlinked."
            }.disabled(!model.canMakeObjectUnique(object.id))
                .help("Give this object its own editable geometry")
        }
        let count = model.sceneLayout.objects.filter { $0.definitionID == object.definitionID }.count
        if count > 1 {
            Label("\(count) linked instances", systemImage: "link").font(.caption).foregroundStyle(.secondary)
        } else if object.libraryPartID != nil {
            Label("Linked to library part", systemImage: "link").font(.caption).foregroundStyle(.secondary)
        }
        Rule()
        SceneTransformControls(model: model, object: object).id(object.id)
        Rule()
        objectLayers(object)
        Rule()
        Button("Delete Object…", role: .destructive) { removingObject = object }
    }

    private func duplicate(_ object: SceneObject, linked: Bool) {
        notice = model.duplicateObject(object.id, linked: linked) ? nil : "There is no room to duplicate this object."
    }

    private func parentMenu(current: UUID?, excluding: UUID?, move: @escaping (UUID?) -> Bool) -> some View {
        let options = SceneTreeRow.possibleParents(layout: model.sceneLayout, moving: excluding)
        let groupName = model.sceneLayout.groups.first { $0.id == current }?.name ?? "Scene Root"
        return HStack {
            Text("Parent").foregroundStyle(.secondary)
            Menu(groupName) {
                Button("Scene Root") { self.move(to: nil, using: move) }.disabled(current == nil)
                ForEach(options) { row in
                    if case let .group(id) = row.id {
                        Button(String(repeating: "  ", count: min(7, row.depth)) + row.name) {
                            self.move(to: id, using: move)
                        }.disabled(current == id)
                    }
                }
            }.help("Move to a different group")
        }
    }

    private func move(to parent: UUID?, using operation: (UUID?) -> Bool) {
        guard operation(parent) else {
            notice = "The scene item could not be moved into that group."
            return
        }
        notice = nil
        revealAncestors(startingAt: parent)
    }

    private func revealSelection() {
        revealAncestors(startingAt: selectedGroup?.parentID ?? (selectedGroup == nil ? model.activeSceneObject?.groupID : nil))
    }

    private func revealAncestors(startingAt parent: UUID?) {
        var next = parent
        let parents = Dictionary(uniqueKeysWithValues: model.sceneLayout.groups.map { ($0.id, $0.parentID) })
        while let id = next {
            collapsed.remove(id)
            next = parents[id] ?? nil
        }
    }

    private func objectLayers(_ object: SceneObject) -> some View {
        let members = Set(object.layerIDs)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Object Layers").font(.headline)
                Spacer()
                IconControl(symbol: "plus", hint: "Add object layer", size: 23, font: 11) {
                    notice = model.addObjectLayer(to: object.id) ? nil : "The object layer could not be added."
                }
            }
            ForEach(model.layers.filter { members.contains($0.id) }.reversed()) { layer in
                Button { model.activeLayerID = layer.id } label: {
                    Label(layer.name, systemImage: layer.id == model.activeLayerID ? "checkmark.circle.fill" : "circle")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help("Choose layer \(layer.name)")
            }
            Button("Edit Voxels") { ui.showingScene = false }
                .help("Use the brush and selection tools on the chosen object layer")
        }
    }
}
