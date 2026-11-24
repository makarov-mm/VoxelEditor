import AppKit
import Combine
import SwiftUI

@main
struct FormaApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = StudioDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class StudioDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = EditorModel()
    let camera = OrbitCamera()
    let ui = StudioUI()
    private var window: NSWindow?
    private var subscriptions = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var approvedClose = false
    private var recovery: RecoveryController?
    private var readyToOpen = false
    private var initialURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1250, height: 840)
        let start = NSRect(x: 0, y: 0, width: min(1240, available.width - 48),
                           height: min(790, available.height - 65))
        let window = NSWindow(contentRect: start, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        self.window = window
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 850, height: 565)
        window.title = model.title
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(StudioStyle.paper)
        window.contentView = NSHostingView(rootView: StudioView(model: model, camera: camera, ui: ui))
        window.center()
        window.setFrameAutosaveName("Forma.Editor.Window")
        model.$title.sink { [weak window] in window?.title = $0 }.store(in: &subscriptions)
        model.$isDirty.sink { [weak window] in window?.isDocumentEdited = $0 }.store(in: &subscriptions)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRecovery()
        readyToOpen = true
        if let initialURL {
            self.initialURL = nil
            model.openProject(at: initialURL)
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if readyToOpen { model.openProject(at: url) }
        else { initialURL = url }
    }

    private func startRecovery() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("studio.forma.voxel/Recovery", isDirectory: true)
            var store = try RecoveryStore(directory: directory)
            if let date = store.savedAt {
                let alert = NSAlert()
                alert.messageText = "Restore your last editing session?"
                let timestamp = date.formatted(Date.FormatStyle(date: .long, time: .standard).locale(Locale(identifier: "en")))
                alert.informativeText = "Forma saved a recovery draft on " + timestamp
                    + ". Restore it as an unsaved project."
                alert.addButton(withTitle: "Restore")
                alert.addButton(withTitle: "Keep for Later").keyEquivalent = "\u{1b}"
                alert.addButton(withTitle: "Discard Draft")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    do {
                        try model.restoreDraft(from: store.draftURL)
                    } catch {
                        let failure = NSAlert()
                        failure.messageText = "Couldn’t restore the draft"
                        failure.informativeText = error.localizedDescription + "\n" + store.draftURL.path
                        failure.runModal()
                        store = try RecoveryStore(directory: directory, includeExisting: false)
                    }
                case .alertThirdButtonReturn:
                    try store.discard()
                default:
                    store = try RecoveryStore(directory: directory, includeExisting: false)
                }
            }
            recovery = RecoveryController(model: model, store: store) { [weak ui] error in
                ui?.recoveryError = error
            }
        } catch {
            ui.recoveryError = error.localizedDescription
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        approvedClose = model.shouldCloseProject()
        return approvedClose
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        approvedClose || model.shouldCloseProject() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        recovery?.stop(discard: true)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window?.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if model.pendingPaste != nil {
            switch event.keyCode {
            case 53:
                model.cancelPaste()
                return true
            case 36, 76:
                if !model.commitPaste() { NSSound.beep() }
                return true
            case 51, 117: return true
            default: break
            }
        }
        if model.tool == .select, model.pendingPaste != nil || !model.selection.isEmpty {
            let delta: Cell?
            switch event.keyCode {
            case 123: delta = Cell(-1, 0, 0)
            case 124: delta = Cell(1, 0, 0)
            case 125: delta = Cell(0, 0, 1)
            case 126: delta = Cell(0, 0, -1)
            case 116: delta = Cell(0, 1, 0)
            case 121: delta = Cell(0, -1, 0)
            case 51, 117:
                _ = model.deleteSelection()
                return true
            case 53 where !(window?.firstResponder is StudioViewportSurface):
                model.clearSelection()
                return true
            default: delta = nil
            }
            if let delta {
                if let fragment = model.pendingPaste {
                    let anchor = model.pasteAnchor ?? fragment.origin
                    model.updatePasteAnchor(anchor.offset(delta))
                } else {
                    ui.nudge(delta, in: model)
                }
                return true
            }
        }
        // Physical positions stay accessible across keyboard layouts.
        switch event.keyCode {
        case 1: model.tool = .select
        case 9: model.tool = .add
        case 11: model.tool = .paint
        case 14: model.tool = .erase
        case 34: model.tool = .pick
        case 37: model.tool = .line
        case 15: model.tool = .rectangle
        case 31: model.tool = .box
        case 8: model.tool = .cylinder
        case 7: model.tool = .extrude
        case 40: model.tool = .fill
        case 16: model.sliceEnabled.toggle()
        case 43 where model.sliceEnabled: lowerSlice()
        case 47 where model.sliceEnabled: raiseSlice()
        case 5: model.showGrid.toggle()
        case 13: model.showEdges.toggle()
        case 3: camera.frameScene()
        case 33 where model.tool.usesShapeDepth: model.shapeDepth = max(1, model.shapeDepth - 1)
        case 30 where model.tool.usesShapeDepth: model.shapeDepth = min(Cell.gridSize, model.shapeDepth + 1)
        case 33: model.brushSize = max(1, model.brushSize - 1)
        case 30: model.brushSize = min(8, model.brushSize + 1)
        default: return false
        }
        return true
    }

    private func configureMenus() {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let root = NSMenuItem()
            bar.addItem(root)
            let sub = NSMenu(title: title)
            root.submenu = sub
            return sub
        }
        @discardableResult
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                  modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
            result.keyEquivalentModifierMask = modifiers
            result.target = target
            menu.addItem(result)
            return result
        }
        let app = menu("Forma")
        item(app, "About Forma", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Hide Forma", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
             modifiers: [.command, .option], target: NSApp)
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Quit Forma", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("File")
        item(file, "New Project…", #selector(newProject), "n", target: self)
        item(file, "Open…", #selector(openProject), "o", target: self)
        item(file, "Open Demo Scene…", #selector(demo), target: self)
        file.addItem(.separator())
        item(file, "Save", #selector(save), "s", target: self)
        item(file, "Save As…", #selector(saveAs), "s", modifiers: [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "Import MagicaVoxel (.vox)…", #selector(importVox), "i",
             modifiers: [.command, .shift], target: self)
        item(file, "Export MagicaVoxel (.vox)…", #selector(exportVox), target: self)
        item(file, "Export Scene PNG…", #selector(exportPng), "p", modifiers: [.command, .shift], target: self)
        item(file, "Export Wavefront OBJ…", #selector(exportObj), "e", modifiers: [.command, .shift], target: self)
        file.addItem(.separator())
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        item(edit, "Undo", #selector(undoEdit), "z", target: self)
        item(edit, "Redo", #selector(redoEdit), "z", modifiers: [.command, .shift], target: self)
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Delete Voxels", #selector(deleteVoxels), target: self)
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        item(edit, "Select by Color", #selector(selectByColor), target: self)
        item(edit, "Deselect Voxels", #selector(deselectVoxels), target: self)
        edit.addItem(.separator())
        item(edit, "Duplicate Selection", #selector(duplicateSelection), "d", target: self)
        item(edit, "Recolor Selection", #selector(recolorSelection), target: self)
        for axis in VoxelAxis.allCases {
            let title = "Rotate 90° Around \(axis.rawValue.uppercased())"
            item(edit, title, #selector(rotateSelection(_:)), target: self).representedObject = axis.rawValue
        }
        let scene = menu("Scene")
        item(scene, "Show Scene Inspector", #selector(showSceneInspector), target: self)
        item(scene, "Create Object from Selection…", #selector(createSceneObject), target: self)
        item(scene, "New Group…", #selector(newSceneGroup), target: self)
        let tools = menu("Tools")
        for tool in EditTool.allCases {
            item(tools, tool.label, #selector(chooseTool(_:)), tool.shortcut.lowercased(), modifiers: [],
                 target: self).representedObject = tool.rawValue
        }
        let view = menu("View")
        item(view, "Show Grid", #selector(grid), target: self)
        item(view, "Show Voxel Edges", #selector(edges), target: self)
        item(view, "Frame Scene", #selector(fit), target: self)
        view.addItem(.separator())
        item(view, "Slice View", #selector(toggleSlice), "y", modifiers: [], target: self)
        item(view, "Lower Slice", #selector(lowerSlice), ",", modifiers: [], target: self)
        item(view, "Raise Slice", #selector(raiseSlice), ".", modifiers: [], target: self)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let windows = menu("Window")
        item(windows, "Parts Library…", #selector(showParts), target: self)
        item(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windows
        let help = menu("Help")
        item(help, "Forma Controls", #selector(helpCard), "/", modifiers: [.command, .shift], target: self)
        NSApp.mainMenu = bar
    }

    @objc private func newProject() { model.newProject() }
    @objc private func openProject() { model.openProject() }
    @objc private func demo() { model.loadDemo() }
    @objc private func save() { model.saveProject() }
    @objc private func saveAs() { model.saveProject(asNew: true) }
    @objc private func importVox() { model.importVOX() }
    @objc private func exportVox() { model.exportVOX() }
    @objc private func exportPng() { camera.exportPNG() }
    // AppKit routes these standard actions to text editors and system panels before the delegate.
    @objc func cut(_ sender: Any?) {
        guard editingCanvas else { return }
        ui.copySelection(model, cutting: true)
    }

    @objc func copy(_ sender: Any?) {
        guard editingCanvas else { return }
        ui.copySelection(model)
    }

    @objc func paste(_ sender: Any?) {
        guard editingCanvas else { return }
        ui.startPaste(in: model)
    }

    @objc private func deleteVoxels() {
        guard editingCanvas, model.pendingPaste == nil else { return }
        _ = model.deleteSelection()
    }

    @objc func selectAll(_ sender: Any?) {
        guard editingCanvas, model.pendingPaste == nil else { return }
        model.selectAllOnActiveLayer()
    }
    @objc private func deselectVoxels() { model.clearSelection() }
    @objc private func selectByColor() {
        guard editingCanvas, model.pendingPaste == nil else { return }
        ui.selectByColor(in: model)
    }
    @objc private func recolorSelection() {
        guard editingCanvas, model.pendingPaste == nil, !model.selection.isEmpty else { return }
        ui.recolorSelection(in: model)
    }
    @objc private func duplicateSelection() { ui.duplicate(model) }
    @objc private func rotateSelection(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let axis = VoxelAxis(rawValue: name) {
            ui.rotate(axis, in: model)
        }
    }
    @objc private func chooseTool(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let tool = EditTool(rawValue: name) { model.tool = tool }
    }
    @objc private func toggleSlice() { model.sliceEnabled.toggle() }
    @objc private func lowerSlice() { model.sliceLevel = max(Cell.verticalRange.lowerBound, model.sliceLevel - 1) }
    @objc private func raiseSlice() { model.sliceLevel = min(Cell.verticalRange.upperBound, model.sliceLevel + 1) }

    private var editingCanvas: Bool {
        NSApp.keyWindow === window && window?.attachedSheet == nil && NSApp.modalWindow == nil &&
            !(window?.firstResponder is NSTextView)
    }

    @objc private func exportObj() { model.exportOBJ() }
    @objc private func undoEdit() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo() }
        else { model.undo() }
    }
    @objc private func redoEdit() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo() }
        else { model.redo() }
    }
    @objc private func grid() { model.showGrid.toggle() }
    @objc private func edges() { model.showEdges.toggle() }
    @objc private func fit() { camera.frameScene() }
    @objc private func showSceneInspector() { ui.showingScene = true }
    @objc private func createSceneObject() { ui.sceneNaming = SceneNameRequest(.createObject) }
    @objc private func newSceneGroup() {
        ui.sceneNaming = SceneNameRequest(.createGroup(ui.inspectedGroupID))
    }
    @objc private func showParts() { ui.showingParts = true }
    @objc private func helpCard() { ui.showingHelp = true }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoEdit):
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canUndo ?? false }
            return model.canUndo
        case #selector(redoEdit):
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canRedo ?? false }
            return model.canRedo
        case #selector(showParts), #selector(showSceneInspector): return editingCanvas
        case #selector(newSceneGroup): return editingCanvas && model.pendingPaste == nil
        case #selector(createSceneObject):
            return editingCanvas && model.pendingPaste == nil && !model.selection.isEmpty
        case #selector(paste(_:)):
            return editingCanvas && ui.canPaste(into: model)
        case #selector(selectAll(_:)), #selector(selectByColor):
            return editingCanvas && model.pendingPaste == nil &&
                model.editableActiveLayer?.cells.isEmpty == false
        case #selector(cut(_:)), #selector(copy(_:)), #selector(deleteVoxels),
             #selector(deselectVoxels), #selector(duplicateSelection), #selector(recolorSelection), #selector(rotateSelection(_:)):
            return editingCanvas && model.pendingPaste == nil && !model.selection.isEmpty
        case #selector(chooseTool(_:)):
            menuItem.state = menuItem.representedObject as? String == model.tool.rawValue ? .on : .off
            return editingCanvas
        case #selector(toggleSlice):
            menuItem.state = model.sliceEnabled ? .on : .off
            return editingCanvas
        case #selector(lowerSlice):
            return editingCanvas && model.sliceEnabled && model.sliceLevel > Cell.verticalRange.lowerBound
        case #selector(raiseSlice):
            return editingCanvas && model.sliceEnabled && model.sliceLevel < Cell.verticalRange.upperBound
        case #selector(exportObj): return model.voxelCount > 0
        case #selector(exportVox): return model.layers.contains { !$0.cells.isEmpty }
        case #selector(grid): menuItem.state = model.showGrid ? .on : .off
        case #selector(edges): menuItem.state = model.showEdges ? .on : .off
        default: break
        }
        return true
    }
}
