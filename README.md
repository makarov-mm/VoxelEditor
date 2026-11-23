# VoxelEditor

Forma is a native voxel editor for macOS 13 and later, written in Swift with SwiftUI, AppKit, and Metal. The interface and viewport follow the Mac’s light or dark appearance. When Metal is unavailable, the viewport uses Core Graphics.

## Run

Open **build/Forma.app**, or build it from this folder with Xcode 15 or later (or the corresponding Command Line Tools).

```sh
./build-app.sh
open build/Forma.app
```

The build script creates a universal, ad-hoc-signed application for Apple Silicon and Intel. Open `Package.swift` in Xcode to develop the app. `swift run Forma` starts the editor and `swift test` runs the format tests. The editor has no external package dependencies.

## Draw

The editor opens with **Northern Lighthouse**, an editable scene with five layers. Press **⌘N** for a blank grid. Select a layer, choose a palette color, and click or drag across the floor or an existing face. Paint and erase affect the active layer. The eyedropper samples any visible layer. Undo reverses a whole stroke.

| Action | Control |
| --- | --- |
| Add, paint, erase, eyedropper | `V`, `B`, `E`, `I` |
| Brush size (1–8) | `[` and `]` |
| Orbit | Right-drag or `⌥` + drag |
| Pan | `⇧` + drag |
| Zoom | Scroll or pinch |
| Frame the scene | `F` |
| Toggle the floor grid or voxel edges | `G` or `W` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |

Watch a flowering cactus take shape from the first voxel to the final camera orbit, then open the finished model to edit it. [Drawing demo (MP4)](Media/Drawing-demo.mp4) · [Desert Bloom model (VOX)](Media/Desert-Bloom.vox)

## Open and save models

- **MagicaVoxel → Forma.** Use **File → Open…** (`⌘O`) or **File → Import MagicaVoxel (.vox)…** (`⇧⌘I`). Opening a `.vox` creates an editable project. Each scene object gets a layer, with its transform applied to the voxel positions.
- **Forma → MagicaVoxel.** Choose **File → Export MagicaVoxel (.vox)…** and open the result in MagicaVoxel. All layers are exported, including hidden ones. The file carries palette colors, layer names, visibility, and supported material metadata.
- **Native projects.** Use **Save** (`⌘S`) to keep working in `.vxl`, Forma’s versioned JSON format. Older Forma projects still open.
- **Meshes.** **File → Export Wavefront OBJ…** writes the visible surface and a companion `.mtl` with its colors. Keep those files together.

The VOX reader accepts versions 150 and 200 and the writer produces version 150. Scenes can span up to 256 cells on each axis, with up to 128 editable objects and two million imported or exported voxels. VOX permits 255 occupied palette entries. If an export would exceed that limit, the editor reports it before writing.

Forma edits static geometry. For animated scene nodes it imports their earliest frame. The viewport shows opaque RGB colors. Export rebuilds a static scene. Keep the original MagicaVoxel project for its animation tracks, cameras, and render settings.
