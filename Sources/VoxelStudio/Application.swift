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

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1250, height: 840)
        let start = NSRect(x: 0, y: 0, width: min(1240, available.width - 48), height: min(790, available.height - 65))
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
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.openProject(at: url) }
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
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window?.firstResponder is NSTextView),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        // Physical positions stay accessible across keyboard layouts.
        switch event.keyCode {
        case 9: model.tool = .add
        case 11: model.tool = .paint
        case 14: model.tool = .erase
        case 34: model.tool = .pick
        case 5: model.showGrid.toggle()
        case 13: model.showEdges.toggle()
        case 3: camera.reset()
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
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp)
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
        item(file, "Import MagicaVoxel (.vox)…", #selector(importVox), "i", modifiers: [.command, .shift], target: self)
        item(file, "Export MagicaVoxel (.vox)…", #selector(exportVox), target: self)
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
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = menu("View")
        item(view, "Show Grid", #selector(grid), target: self)
        item(view, "Show Voxel Edges", #selector(edges), target: self)
        item(view, "Frame Scene", #selector(fit), target: self)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let windows = menu("Window")
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
    @objc private func fit() { camera.reset() }
    @objc private func helpCard() { ui.showingHelp = true }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoEdit):
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canUndo ?? false }
            return model.canUndo
        case #selector(redoEdit):
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canRedo ?? false }
            return model.canRedo
        case #selector(exportObj): return model.voxelCount > 0
        case #selector(exportVox): return model.layers.contains { !$0.cells.isEmpty }
        case #selector(grid): menuItem.state = model.showGrid ? .on : .off
        case #selector(edges): menuItem.state = model.showEdges ? .on : .off
        default: break
        }
        return true
    }
}
