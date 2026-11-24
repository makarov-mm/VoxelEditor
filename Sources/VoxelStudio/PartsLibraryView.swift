import SwiftUI

struct PartsLibraryView: View {
    @ObservedObject var model: EditorModel
    @StateObject private var library = PartsLibrary()
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var linked = false
    @ViewState private var removal: LibraryPart?
    @ViewState private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Parts Library").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !model.selection.isEmpty && model.pendingPaste == nil {
                HStack {
                    TextField("Part name", text: $name)
                        .onSubmit { if canSave { saveSelection() } }
                    Button("Save Selection") { saveSelection() }.disabled(!canSave)
                }
            }
            Divider()
            if library.parts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 28))
                    Text("Select voxels in the editor to save your first part.")
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Place as", selection: $linked) {
                    Text("Voxel Stamp").tag(false)
                    Text("Linked Object").tag(true)
                }.pickerStyle(.segmented)
                .help("Voxel stamps add independent cells. Linked objects share edits in this project.")
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 12)], spacing: 10) {
                        ForEach(library.parts) { part in
                            Button { stamp(part) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Group {
                                        if let preview = library.thumbnail(for: part) {
                                            Image(nsImage: preview).resizable().scaledToFit()
                                        } else {
                                            Image(systemName: "cube")
                                        }
                                    }.frame(maxWidth: .infinity).frame(height: 87)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(StudioStyle.rail))
                                    Text(part.name).font(.headline).lineLimit(1)
                                    Text("\(part.count.formatted()) voxels").font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(linked ? "Place a linked instance of \(part.name)" : "Stamp \(part.name)")
                                .accessibilityLabel(linked ? "Place linked object \(part.name)" : "Stamp \(part.name)")
                                .contextMenu { Button("Delete…", role: .destructive) { removal = part } }
                        }
                    }.padding(2)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 500, height: 380)
        .onAppear { perform { try library.reload() } }
        .alert("Delete “\(removal?.name ?? "")” from the library?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { part in
            Button("Delete", role: .destructive) { perform { try library.remove(part) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            model.selection.count <= VoxelFragment.maxCells
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveSelection() {
        guard let fragment = model.selectionFragment() else {
            message = "Select editable voxels to save a part."
            return
        }
        perform {
            try library.save(fragment, name: name)
            name = ""
        }
    }

    private func stamp(_ part: LibraryPart) {
        do {
            let fragment = try library.fragment(for: part)
            let started = linked
                ? model.beginLinkedStamp(fragment, partID: part.id, name: part.name)
                : model.beginPaste(fragment, stampName: part.name)
            guard started else {
                message = "Choose a visible, unlocked layer for stamping."
                return
            }
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
