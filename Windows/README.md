# Forma for Windows

A native x64 build of the Forma voxel editor using C++/WinRT, WinUI 3 and Direct3D 11. The project uses the Visual Studio 2026 v145 toolset with `/std:c++latest` and the Windows 11 SDK 10.0.26100.0.

## Run

Extract the complete release ZIP and open `Forma.exe`. Keep the adjacent runtime files with the executable. You can also pass the path of a `.vxl` project or `.vox` scene to the executable.

## Build

Install Visual Studio 2026 with Desktop development with C++, the x64 v145 tools, and Windows SDK 10.0.26100.0. From the Windows source directory, run the following command in PowerShell.

```powershell
.\build.ps1 -Test
```

The script restores the pinned SDK and C++/WinRT packages from NuGet, builds the x64 application and runs the editor checks using the original scenes in `..\Media`. Use `-MediaDirectory` to select another fixture directory. The executable and its app-local dependencies are in `bin\x64\Release`. After the first restore, open `Forma.vcxproj` in Visual Studio to edit or debug.

## Editing

Forma opens with the five-layer Northern Lighthouse. Use **File → New** for an empty project. Right-drag to orbit, Shift-drag to pan, scroll to zoom and press **F** to fit the scene. Open a layer in the inspector, change its name with Enter, and use the color swatches or **Choose color** to set the active ink.

| Action | Control |
| --- | --- |
| Add, paint, erase, eyedropper, select | V, B, E, I, S |
| Line, rectangle, box, extrude, flood fill | L, R, O, X, K |
| Change brush size | [ or ] |
| Toggle cut, lower or raise cut | Y, comma, period |
| Floor grid and voxel edges | G, W |
| Select region, add to selection | Drag, Ctrl-drag |
| Move selection | Drag its face, arrow keys, Page Up / Down |
| Copy, cut, paste, duplicate | Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+D |
| Confirm placement, cancel | Enter or click, Esc |
| Undo and redo | Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z |
| Open, save, save as | Ctrl+O, Ctrl+S, Ctrl+Shift+S |
| Export scene PNG | Ctrl+Shift+P |

Use **File** to export MagicaVoxel, OBJ with its companion MTL, or a PNG from the current camera. Projects preserve the full scene across a horizontal cut. VOX import reads versions 150 and 200. Export writes version 150 and preserves layer visibility and supported material dictionaries.

