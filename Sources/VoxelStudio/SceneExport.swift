import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum SceneExportError: LocalizedError {
    case noViewport, emptyViewport, bitmapAllocation, encoding

    var errorDescription: String? {
        switch self {
        case .noViewport: return "Open an editor window and try again."
        case .emptyViewport: return "Resize the editor window to show the scene and try again."
        case .bitmapAllocation: return "There is insufficient memory to render this image."
        case .encoding: return "The scene could not be encoded as a PNG image."
        }
    }
}

@MainActor
extension OrbitCamera {
    func exportPNG() {
        do {
            guard let title = viewport?.projectTitle else { throw SceneExportError.noViewport }
            let panel = NSSavePanel()
            panel.title = "Export Scene as PNG"
            panel.prompt = "Export"
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".png"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try exportPNG(to: destination)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t export the scene"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func exportPNG(to url: URL) throws {
        guard let viewport else { throw SceneExportError.noViewport }
        let bounds = viewport.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw SceneExportError.emptyViewport
        }

        let scale = min(2, 4096 / max(bounds.width, bounds.height))
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SceneExportError.bitmapAllocation
        }
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        viewport.drawScene(in: context, includeEditorOverlays: false)

        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw SceneExportError.encoding
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw SceneExportError.encoding }
        try (bytes as Data).write(to: url, options: .atomic)
    }
}
