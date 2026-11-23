import SwiftUI

// Use the SwiftUI property wrapper that is also available on macOS 13.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

enum StudioStyle {
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Forma." + name)) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }

    static let ink = adaptive("ink", light: 0x273732, dark: 0xE0E8E0)
    static let secondary = adaptive("secondary", light: 0x57655C, dark: 0xB8C5BC)
    static let muted = adaptive("muted", light: 0x6E786F, dark: 0xA5B2A8)
    static let paper = adaptive("paper", light: 0xFAFAF6, dark: 0x242C29)
    static let rail = adaptive("rail", light: 0xF6F7F1, dark: 0x202723)
    static let rule = adaptive("rule", light: 0xDCDDD4, dark: 0x424E46)
    static let pale = adaptive("pale", light: 0xE7EDE1, dark: 0x35473B)
    static let green = adaptive("green", light: 0x42654D, dark: 0xB4D3AC)
    static let icon = adaptive("icon", light: 0x43584A, dark: 0xBED0C0)
    static let pressed = adaptive("pressed", light: 0xDCE2D5, dark: 0x495D4D)
    static let swatchBorder = adaptive("swatchBorder", light: 0xC6C8BE, dark: 0x67736A)
    static let primaryLabel = adaptive("primaryLabel", light: 0xFFFFFF, dark: 0x1E2A22)
    static let accentFill = adaptive("accentFill", light: 0x42654D, dark: 0x4D7057)
}

extension EditTool {
    var label: String {
        switch self {
        case .add: return "Add"
        case .paint: return "Paint"
        case .erase: return "Erase"
        case .pick: return "Eyedropper"
        case .select: return "Select"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .box: return "Box"
        case .extrude: return "Extrude"
        case .fill: return "Fill"
        }
    }

    var symbol: String {
        switch self {
        case .add: return "cube"
        case .paint: return "paintbrush.pointed"
        case .erase: return "eraser"
        case .pick: return "eyedropper"
        case .select: return "rectangle.dashed"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .box: return "cube.fill"
        case .extrude: return "arrow.up.and.line.horizontal.and.arrow.down"
        case .fill: return "drop.fill"
        }
    }

    var shortcut: String {
        switch self {
        case .add: return "V"
        case .paint: return "B"
        case .erase: return "E"
        case .pick: return "I"
        case .select: return "S"
        case .line: return "L"
        case .rectangle: return "R"
        case .box: return "O"
        case .extrude: return "X"
        case .fill: return "K"
        }
    }

    var instruction: String {
        switch self {
        case .add: return "Click a face or the grid to add voxels"
        case .paint: return "Click a voxel to paint it"
        case .erase: return "Click to erase voxels on the active layer"
        case .pick: return "Click a voxel to sample its color"
        case .select: return "Click or box-select voxels. Drag a selection to move it."
        case .line: return "Drag on the grid or a voxel face to draw a line."
        case .rectangle: return "Drag opposite corners of a filled rectangle."
        case .box: return "Set the depth, then drag the base of the box."
        case .extrude: return "Drag an exposed face outward to extend it."
        case .fill: return "Click to recolor connected voxels of the same color."
        }
    }
}

struct BrandCube: View {
    var body: some View {
        Canvas { context, size in
            func fill(_ points: [(CGFloat, CGFloat)], _ color: UInt32) {
                var path = Path()
                for (index, p) in points.enumerated() {
                    let pt = CGPoint(x: p.0 * size.width / 32, y: p.1 * size.height / 36)
                    if index == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                context.fill(path, with: .color(Color(rgb: color)))
            }
            fill([(16, 0), (32, 9), (16, 18), (0, 9)], 0xA7BE8F)
            fill([(0, 9), (16, 18), (16, 36), (0, 27)], 0x6E8B63)
            fill([(16, 18), (32, 9), (32, 27), (16, 36)], 0x354F43)
            fill([(16, 10), (23, 14), (16, 18), (9, 14)], 0xD3DDBD)
            fill([(9, 14), (16, 18), (16, 26), (9, 22)], 0xABC398)
            fill([(16, 18), (23, 14), (23, 22), (16, 26)], 0x79966C)
        }.accessibilityHidden(true)
    }
}

struct StudioButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        ButtonFace(configuration: configuration, selected: selected)
    }

    private struct ButtonFace: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @ViewState private var hover = false
        @Environment(\.isEnabled) var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(selected ? StudioStyle.green : StudioStyle.ink)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    configuration.isPressed ? StudioStyle.pressed :
                    selected ? StudioStyle.pale : hover && enabled ? StudioStyle.rule.opacity(0.62) : Color.clear))
                .opacity(enabled ? 1 : 0.34)
                .contentShape(Rectangle()).onHover { hover = $0 }
        }
    }
}

struct IconControl: View {
    let symbol: String
    let hint: String
    var size: CGFloat = 29
    var font: CGFloat = 14
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: font, weight: .medium))
                .frame(width: size, height: size)
        }.buttonStyle(StudioButtonStyle(selected: selected)).help(hint).accessibilityLabel(hint)
    }
}

struct Rule: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(StudioStyle.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}
