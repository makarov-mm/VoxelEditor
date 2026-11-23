# Forma — macOS voxel editor

Forma is a native Swift and Metal editor for building, painting, and editing voxel models on a 256 × 256 × 256 grid. Organize a scene into layers, sample colors directly from a model, and exchange `.vox` files with MagicaVoxel. The canvas and inspector follow the Mac’s light or dark appearance.

**See it in action.** A 35-second demo shows how to build a flowering cactus from an empty grid, paint its details, and orbit the finished model. [Watch the demo (MP4)](Media/Drawing-demo.mp4) · [Get the finished model (VOX)](Media/Desert-Bloom.vox)

## Build and run

The app runs on macOS 13 or later. To build from source, use Xcode 15 or later, or the corresponding Xcode Command Line Tools. There are no external package dependencies.

```sh
git clone https://github.com/makarov-mm/VoxelEditor.git
cd VoxelEditor
./build-app.sh
open build/Forma.app
```

The script builds a universal `Forma.app` for Apple Silicon and Intel and signs it locally. You can copy the bundle to Applications.

## Start drawing

The editor opens with **Northern Lighthouse**, a five-layer scene you can edit immediately. To start from scratch, press **⌘N**, choose a color in the inspector, and click the floor to place your first voxel. Click an exposed face to build outward. Drag to draw a stroke, then press **⌘Z** to undo the whole stroke.

| Action | Control |
| --- | --- |
| Add / paint / erase / sample color | `V` / `B` / `E` / `I` |
| Decrease / increase brush size | `[` / `]` (1–8 voxels) |
| Orbit | Right-drag or `⌥` + drag |
| Pan | `⇧` + drag |
| Zoom | Scroll or pinch |
| Fit the scene in the viewport | `F` |
| Toggle floor grid / voxel edges | `G` / `W` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |

Choose the active layer in the inspector before painting or erasing. The eyedropper can sample any visible layer.

## File formats

| Format | Open | Save or export | Contents |
| --- | --- | --- | --- |
| Forma project (`.vxl`) | **File → Open…** | **Save** (`⌘S`) or **Save As…** | Editable layers, visibility, voxels, and palette in versioned JSON |
| MagicaVoxel (`.vox`) | **File → Open…** or **Import MagicaVoxel (.vox)…** | **File → Export MagicaVoxel (.vox)…** | Static models, placement, colors, and supported material metadata |
| Wavefront (`.obj` + `.mtl`) | — | **File → Export Wavefront OBJ…** | Mesh of the visible surface and its color materials. Keep the two files together. |

Opening a `.vox` creates an editable Forma project. Use **⌘S** to keep a native copy, or **Export MagicaVoxel (.vox)…** to take the edited model back to MagicaVoxel. VOX export includes hidden layers and preserves their visibility.

Forma reads VOX versions 150 and 200 and writes version 150. A scene can span 256 cells on each axis, with up to 128 objects, two million voxels, and 255 occupied palette entries for VOX exchange. Animated scene nodes open at their earliest frame. Keep the original MagicaVoxel file for animation tracks, cameras, and render settings.

## Development

Open `Package.swift` in Xcode, or use Swift Package Manager from the repository root.

```sh
swift run Forma   # Launch the editor
swift test        # Run the MagicaVoxel import and export tests
```

The interface uses SwiftUI and AppKit. The viewport uses MetalKit with a Core Graphics fallback when Metal is unavailable. The format tests cover palette and coordinate round trips, scene transforms, hidden layers, malformed files, and native saves after import.

## License

Forma is available under the [MIT License](LICENSE).
