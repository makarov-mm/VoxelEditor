import SwiftUI

private struct CoordinateFields {
    var x: String
    var y: String
    var z: String

    init(_ cell: Cell = Cell(0, 0, 0)) {
        x = String(cell.x)
        y = String(cell.y)
        z = String(cell.z)
    }

    var cell: Cell? {
        guard let x = Int(x), let y = Int(y), let z = Int(z) else { return nil }
        return Cell(x, y, z)
    }
}

struct SceneTransformControls: View {
    @ObservedObject var model: EditorModel
    let object: SceneObject
    @ViewState private var offset = CoordinateFields()
    @ViewState private var pivot = CoordinateFields()
    @ViewState private var customPivot = false
    @ViewState private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move").font(.headline)
            HStack(spacing: 3) {
                step("X", by: Cell(1, 0, 0))
                step("Y", by: Cell(0, 1, 0))
                step("Z", by: Cell(0, 0, 1))
            }
            fields($offset, purpose: "Offset")
            Button("Apply Offset") {
                if let delta = validOffset { move(by: delta) }
            }.disabled(validOffset == nil).help("Move the object by these grid offsets")
            Rule().padding(.vertical, 3)
            Text("Rotate").font(.headline)
            Picker("Pivot", selection: $customPivot) {
                Text("Object Center").tag(false)
                Text("Grid Cell").tag(true)
            }.onChange(of: customPivot) { useCell in
                if useCell { pivot = CoordinateFields(center()) }
            }
            if customPivot { fields($pivot, purpose: "Pivot") }
            HStack {
                Text("Turn 90°").foregroundStyle(.secondary)
                Spacer()
                ForEach(VoxelAxis.allCases, id: \.self) { axis in
                    Button(axis.rawValue.uppercased()) { rotate(around: axis) }
                        .accessibilityLabel("Rotate object 90 degrees around \(axis.rawValue.uppercased())")
                }
            }.disabled(customPivot && pivot.cell?.inBounds != true)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var validOffset: Cell? {
        guard let delta = offset.cell, delta != Cell(0, 0, 0),
              [delta.x, delta.y, delta.z].allSatisfy({ (-Cell.gridSize..<Cell.gridSize).contains($0) }) else {
            return nil
        }
        return delta
    }

    private func fields(_ coordinates: Binding<CoordinateFields>, purpose: String) -> some View {
        HStack(spacing: 5) {
            field("X", value: coordinates.x, purpose: purpose)
            field("Y", value: coordinates.y, purpose: purpose)
            field("Z", value: coordinates.z, purpose: purpose)
        }
    }

    private func field(_ axis: String, value: Binding<String>, purpose: String) -> some View {
        HStack(spacing: 2) {
            Text(axis).font(.caption).foregroundStyle(.secondary)
            TextField(axis, text: value).monospacedDigit().accessibilityLabel("\(purpose) \(axis)")
        }.frame(maxWidth: .infinity)
    }

    private func step(_ axis: String, by delta: Cell) -> some View {
        HStack(spacing: 1) {
            IconControl(symbol: "minus", hint: "Move object −\(axis)", size: 21, font: 9) {
                move(by: Cell(-delta.x, -delta.y, -delta.z))
            }
            Text(axis).font(.caption.monospaced())
            IconControl(symbol: "plus", hint: "Move object +\(axis)", size: 21, font: 9) { move(by: delta) }
        }.frame(maxWidth: .infinity).overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioStyle.rule))
    }

    private func move(by delta: Cell) {
        notice = model.moveObject(object.id, by: delta) ? nil : "The move is blocked. Check the grid bounds, occupied cells and layer locks."
    }

    private func rotate(around axis: VoxelAxis) {
        guard let center = customPivot ? pivot.cell : center(), center.inBounds else { return }
        notice = model.rotateObject(object.id, around: axis, pivot: center) ? nil : "The turn is blocked. Check the pivot, grid bounds, occupied cells and layer locks."
    }

    private func center() -> Cell {
        guard let bounds = model.objectBounds(object.id) else {
            return object.transform.offset.inBounds ? object.transform.offset : Cell(0, 0, 0)
        }
        let span = bounds.size.offset(-1, -1, -1)
        return bounds.min.offset(span.x / 2, span.y / 2, span.z / 2)
    }
}
