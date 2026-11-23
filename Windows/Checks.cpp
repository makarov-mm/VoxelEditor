#include "Studio.h"
#include <fstream>
#include <format>
#include <stdexcept>
namespace forma
{
void Studio::selfTest(std::filesystem::path const &media, std::filesystem::path const &out)
{
    if (!std::filesystem::is_directory(out))
        throw std::runtime_error("Expected a test output directory.");
    auto expect = [](bool ok, const char *what) {
        if (!ok)
            throw std::runtime_error(what);
    };
    auto same = [&](Scene const &a, Scene const &b, bool native) {
        expect(a.layers.size() == b.layers.size(), "Layer count changed.");
        for (size_t k = 0; k < a.layers.size(); k++)
        {
            auto &x = a.layers[k];
            auto &y = b.layers[k];
            expect(x.name == y.name && x.visible == y.visible, "Layer metadata changed.");
            if (native)
                expect(x.id == y.id, "Layer ID changed.");
            size_t nx = 0, ny = 0;
            x.cells.each([&](Cell p, Ink const &i) {
                auto j = y.cells.get(p);
                expect(j != nullptr, "Missing voxel.");
                if (native)
                    expect(*j == i, "Native ink changed.");
                else
                {
                    expect(fabsf(j->r - i.r) < .0021f && fabsf(j->g - i.g) < .0021f &&
                               fabsf(j->b - i.b) < .0021f,
                           "VOX color changed.");
                    expect((!i.surface && !j->surface) ||
                               (i.surface && j->surface && *i.surface == *j->surface),
                           "VOX material changed.");
                }
                nx++;
            });
            y.cells.each([&](auto, auto &) { ny++; });
            expect(nx == ny, "Additional voxels.");
        }
    };
    resize();
    if (canvas.ActualWidth() <= 100 || canvas.ActualHeight() <= 100)
        throw std::runtime_error(std::format(
            "Window layout failed: root {:.0f} x {:.0f}, canvas {:.0f} x {:.0f}", root.ActualWidth(),
            root.ActualHeight(), canvas.ActualWidth(), canvas.ActualHeight()));
    auto point = canvas.TransformToVisual(root).TransformPoint(
        {float(canvas.ActualWidth() / 2), float(canvas.ActualHeight() / 2)});
    bool hitCanvas = false;
    for (auto const &hit : X::Media::VisualTreeHelper::FindElementsInHostCoordinates(point, root))
    {
        auto element = hit.as<X::DependencyObject>();
        while (element)
        {
            if (element == canvas)
            {
                hitCanvas = true;
                break;
            }
            element = X::Media::VisualTreeHelper::GetParent(element);
        }
    }
    expect(hitCanvas, "WinUI did not route pointer hit tests to the viewport.");
    expect(visible.size() == 3136, "Northern Lighthouse differs from the original scene.");
    auto demoCount = visible.size();
    viewport.png(out / L"Lighthouse.png");
    auto c = readProject(media / L"Keepers-Cottage.vxl");
    expect(c.layers.size() == 5, "Cottage is missing layers.");
    project(c);
    saveProject(c, out / L"Cottage.vxl");
    same(c, readProject(out / L"Cottage.vxl"), true);
    auto v = readVox(media / L"Desert-Bloom.vox");
    expect(!v.visible().empty(), "Desert Bloom is empty.");
    saveVox(v, out / L"Bloom.vox");
    same(v, readVox(out / L"Bloom.vox"), false);
    v.layers[0].visible = false;
    v.layers[0].name = "Hidden material";
    Ink glass = Ink::rgb(0x12abef);
    glass.surface = std::make_shared<Material>(
        137, std::map<std::string, std::string>{{"_type", "_glass"}, {"_ior", "1.4"}});
    v.layers[0].cells.put({-126, 1, 3}, glass);
    saveVox(v, out / L"Hidden.vox");
    same(v, readVox(out / L"Hidden.vox"), false);
    project(Scene{});
    editor.mirrorX = true;
    editor.begin();
    editor.brush({{}, Cell{0, 0, 0}, {0, 1, 0}});
    editor.end();
    expect(editor.scene().visible().size() == 2, "Mirrored brush failed.");
    editor.undo();
    expect(editor.scene().visible().empty(), "Stroke undo failed.");
    editor.redo();
    editor.mirrorX = false;
    editor.begin();
    editor.ink = glass;
    editor.fill({0, 0, 0});
    editor.end();
    expect(*editor.scene().layers[0].cells.get({-1, 0, 0}) == glass, "Flood fill failed.");
    editor.selectAll();
    editor.begin();
    expect(editor.transform({0, 1, 0}), "Move failed.");
    editor.end();
    auto fragment = parseFragment(fragmentBytes(editor.scene().visible()));
    expect(fragment == editor.scene().visible(), "Clipboard round trip failed.");
    editor.tool = Tool::Box;
    editor.depth = 3;
    editor.begin();
    editor.apply(editor.shape({3, 0, 3}, {4, 0, 5}, {0, 1, 0}));
    editor.end();
    expect(editor.scene().visible().size() == 20, "Box shape failed.");
    auto extruded = editor.extrusion({4, 0, 5}, {1, 0, 0}, 2);
    expect(extruded.size() == 18, "Extrusion failed.");
    refresh();
    orient(0);
    auto xy = viewport.camera.screen({4, 2, 5});
    expect(viewport.camera.pick(xy.first, xy.second, visible, 0).hit.has_value(),
           "Viewport picking failed.");
    setSlice(true, 0);
    expect(visible.size() == 6, "Horizontal slice failed.");
    saveObj(editor.scene(), out / L"Scene.obj");
    viewport.png(out / L"Slice.png");
    expect(std::filesystem::file_size(out / L"Scene.mtl") > 0 &&
               std::filesystem::file_size(out / L"Lighthouse.png") > 3000,
           "Export failed.");
    atomicWrite(
        out / L"passed.txt",
        "Passed: WinUI window, Direct3D 11, Northern Lighthouse (" + std::to_string(demoCount) +
            " voxels), VXL and VOX round trips, hidden layers, materials, brush, undo/redo, fill, move, "
            "clipboard codec, shapes, extrusion, picking, slice, OBJ/MTL and PNG.\n");
}
} // namespace forma
