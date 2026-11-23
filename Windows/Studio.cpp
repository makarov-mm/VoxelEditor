#include "Studio.h"
#include <microsoft.ui.xaml.window.h>
#include <commdlg.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <format>
#include <shellapi.h>
namespace forma
{
using namespace winrt;
using namespace X;
using namespace C;
namespace
{
auto label(std::wstring_view t, double sz = 14, bool bold = false)
{
    TextBlock b;
    b.Text(hstring(t));
    b.FontSize(sz);
    if (bold)
        b.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
    b.VerticalAlignment(VerticalAlignment::Center);
    return b;
}
auto row(double spacing = 6)
{
    StackPanel p;
    p.Orientation(Orientation::Horizontal);
    p.Spacing(spacing);
    return p;
}
auto button(std::wstring_view t, std::function<void()> f)
{
    Button b;
    b.Content(box_value(hstring(t)));
    b.Padding({10, 5, 10, 5});
    b.Click([f = std::move(f)](auto &&, auto &&) { f(); });
    return b;
}
void addRow(Grid const &g, double v, GridUnitType unit)
{
    RowDefinition d;
    d.Height({v, unit});
    g.RowDefinitions().Append(d);
}
void addCol(Grid const &g, double v, GridUnitType unit)
{
    ColumnDefinition d;
    d.Width({v, unit});
    g.ColumnDefinitions().Append(d);
}
void at(Grid const &g, FrameworkElement const &e, int r, int c, int span = 1)
{
    Grid::SetRow(e, r);
    Grid::SetColumn(e, c);
    Grid::SetColumnSpan(e, span);
    g.Children().Append(e);
}
auto brush(unsigned r, unsigned g, unsigned b, unsigned a = 255)
{
    return Media::SolidColorBrush(
        winrt::Windows::UI::Color{(uint8_t)a, (uint8_t)r, (uint8_t)g, (uint8_t)b});
}
void tooltip(DependencyObject const &e, std::wstring_view s)
{
    ToolTipService::SetToolTip(e, box_value(hstring(s)));
}
constexpr std::array<const wchar_t *, 10> names{L"Add",     L"Paint", L"Erase",     L"Eyedropper",
                                                L"Select",  L"Line",  L"Rectangle", L"Box",
                                                L"Extrude", L"Fill"};
constexpr std::array<wchar_t, 10> shortcuts{L'V', L'B', L'E', L'I', L'S', L'L', L'R', L'O', L'X', L'K'};
auto pathDialog(HWND hwnd, bool save, const wchar_t *filter, const wchar_t *ext,
                std::wstring const &suggested = {})
{
    std::vector<wchar_t> name(32768);
    if (suggested.size() < name.size())
        std::copy(suggested.begin(), suggested.end(), name.begin());
    OPENFILENAMEW dlg{sizeof(dlg)};
    dlg.hwndOwner = hwnd;
    dlg.lpstrFilter = filter;
    dlg.lpstrFile = name.data();
    dlg.nMaxFile = DWORD(name.size());
    dlg.lpstrDefExt = ext;
    dlg.Flags = OFN_EXPLORER | OFN_NOCHANGEDIR | OFN_PATHMUSTEXIST |
                (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    return (save ? GetSaveFileNameW(&dlg) : GetOpenFileNameW(&dlg)) ? std::filesystem::path(name.data())
                                                                    : std::filesystem::path{};
}
std::wstring ext(std::filesystem::path const &p)
{
    auto s = p.extension().wstring();
    std::ranges::transform(s, s.begin(), [](wchar_t c) { return wchar_t(towlower(c)); });
    return s;
}
} // namespace
Studio::Studio(Window const &host) : window(host)
{
    check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));
    editor.reset(lighthouse());
}
void Studio::message(std::wstring_view t)
{
    MessageBoxW(hwnd, std::wstring(t).c_str(), L"Forma", MB_OK | MB_ICONINFORMATION);
}
void Studio::guarded(std::function<void()> const &f)
{
    try
    {
        f();
    }
    catch (hresult_error const &e)
    {
        message(e.message());
    }
    catch (std::exception const &e)
    {
        message(to_hstring(e.what()));
    }
}
void Studio::build()
{
    constexpr auto autoSize = GridUnitType::Auto, star = GridUnitType::Star, pixel = GridUnitType::Pixel;
    addRow(root, 1, autoSize);
    addRow(root, 1, star);
    addRow(root, 1, autoSize);
    addCol(root, 114, pixel);
    addCol(root, 1, star);
    addCol(root, 257, pixel);
    root.Padding({0, 0, 0, 0});
    root.IsTabStop(true);
    Grid bar;
    bar.Padding({14, 8, 14, 8});
    addCol(bar, 1, star);
    addCol(bar, 1, autoSize);
    auto brand = row(12);
    auto mark = label(L"◆", 21, true);
    mark.Foreground(brush(99, 136, 108));
    brand.Children().Append(mark);
    brand.Children().Append(label(L"Forma", 23, true));
    at(bar, brand, 0, 0);
    auto commands = row();
    undoButton = button(L"Undo", [this] {
        editor.undo();
        refresh(true);
    });
    redoButton = button(L"Redo", [this] {
        editor.redo();
        refresh(true);
    });
    commands.Children().Append(undoButton);
    commands.Children().Append(redoButton);
    Button fileMenu;
    fileMenu.Content(box_value(L"File"));
    MenuFlyout menu;
    auto item = [&](std::wstring_view name, auto f) {
        MenuFlyoutItem m;
        m.Text(hstring(name));
        m.Click([this, f](auto &&, auto &&) { guarded(f); });
        menu.Items().Append(m);
    };
    item(L"New    Ctrl+N", [this] {
        if (mayClose())
            project(Scene{});
    });
    item(L"Open…    Ctrl+O", [this] { open(); });
    item(L"Open Northern Lighthouse", [this] {
        if (mayClose())
            project(lighthouse());
    });
    item(L"Save as…    Ctrl+Shift+S", [this] { save(true); });
    menu.Items().Append(MenuFlyoutSeparator{});
    item(L"Export MagicaVoxel…", [this] { exportFile(0); });
    item(L"Export scene PNG…", [this] { exportFile(1); });
    item(L"Export Wavefront OBJ…", [this] { exportFile(2); });
    fileMenu.Flyout(menu);
    commands.Children().Append(fileMenu);
    commands.Children().Append(button(L"Save", [this] { guarded([this] { save(); }); }));
    at(bar, commands, 0, 1);
    at(root, bar, 0, 0, 3);
    rail.Padding({7, 10, 7, 8});
    rail.Spacing(4);
    for (int i = 0; i < 10; i++)
    {
        tools[i] = button(names[i], [this, i] { tool(Tool(i)); });
        tools[i].HorizontalAlignment(HorizontalAlignment::Stretch);
        tools[i].HorizontalContentAlignment(HorizontalAlignment::Left);
        tooltip(tools[i], std::format(L"{} ({})", names[i], shortcuts[i]));
        rail.Children().Append(tools[i]);
    }
    ScrollViewer toolScroll;
    toolScroll.Content(rail);
    at(root, toolScroll, 1, 0);
    Grid center;
    Grid inputSurface;
    inputSurface.Background(brush(0, 0, 0, 0));
    canvas.Children().Append(inputSurface);
    at(center, canvas, 0, 0);
    viewport.attach(canvas);
    title = label(L"", 20, true);
    title.Margin({17, 12, 0, 0});
    title.HorizontalAlignment(HorizontalAlignment::Left);
    title.VerticalAlignment(VerticalAlignment::Top);
    title.IsHitTestVisible(false);
    at(center, title, 0, 0);
    selectionBox.BorderThickness({1, 1, 1, 1});
    selectionBox.BorderBrush(brush(57, 133, 152));
    selectionBox.Background(brush(66, 144, 169, 38));
    selectionBox.HorizontalAlignment(HorizontalAlignment::Left);
    selectionBox.VerticalAlignment(VerticalAlignment::Top);
    selectionBox.IsHitTestVisible(false);
    selectionBox.Visibility(Visibility::Collapsed);
    at(center, selectionBox, 0, 0);
    auto nav = row(4);
    nav.HorizontalAlignment(HorizontalAlignment::Right);
    nav.VerticalAlignment(VerticalAlignment::Bottom);
    nav.Margin({0, 0, 12, 12});
    for (auto [name, mode] : std::array<std::pair<const wchar_t *, int>, 4>{
             {{L"Iso", 0}, {L"Front", 1}, {L"Top", 2}, {L"Right", 3}}})
        nav.Children().Append(button(name, [this, mode] { orient(mode); }));
    nav.Children().Append(button(L"Fit", [this] {
        viewport.camera.fit(visible);
        redraw();
    }));
    at(center, nav, 0, 0);
    at(root, center, 1, 1);
    inspector.Padding({14, 9, 14, 18});
    inspector.Spacing(8);
    inspectorScroll.Content(inspector);
    inspectorScroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
    at(root, inspectorScroll, 1, 2);
    status = label(L"", 12);
    status.Margin({14, 5, 10, 6});
    at(root, status, 2, 0, 3);
    root.ActualThemeChanged([this](auto &&, auto &&) {
        viewport.dark = root.ActualTheme() == ElementTheme::Dark;
        redraw();
    });
    canvas.SizeChanged([this](auto &&, auto &&) { guarded([&] { resize(); }); });
    canvas.CompositionScaleChanged([this](auto &&, auto &&) { guarded([&] { resize(); }); });
    canvas.PointerPressed([this](auto &&, auto &a) { guarded([&] { pointerDown(a); }); });
    canvas.PointerMoved([this](auto &&, auto &a) { guarded([&] { pointerMove(a); }); });
    canvas.PointerReleased([this](auto &&, auto &a) { guarded([&] { pointerUp(a); }); });
    canvas.PointerCaptureLost([this](auto &&, auto &&) {
        if (drag != Drag::None)
        {
            clearInteraction(true);
            refresh();
        }
    });
    canvas.PointerExited([this](auto &&, auto &&) {
        if (drag == Drag::None && fragment.empty())
        {
            preview.clear();
            viewport.overlay({});
            redraw();
        }
    });
    canvas.PointerWheelChanged([this](auto &&, auto &a) {
        auto p = a.GetCurrentPoint(canvas);
        viewport.camera.span = std::clamp(
            viewport.camera.span * powf(.84f, p.Properties().MouseWheelDelta() / 120.f), .4f, 1600.f);
        redraw();
        a.Handled(true);
    });
    root.KeyDown([this](auto &&, auto &e) { guarded([&] { key(e); }); });
    window.AppWindow().Closing([this](auto &&, auto &e) {
        try
        {
            if (!mayClose())
                e.Cancel(true);
        }
        catch (...)
        {
            e.Cancel(true);
        }
    });
    window.Content(root);
    ready = true;
    sidebar();
    refresh();
    window.Activate();
    resize();
    root.Focus(FocusState::Programmatic);
}
void Studio::sidebar()
{
    syncing = true;
    auto list = inspector.Children();
    list.Clear();
    auto heading = [&](std::wstring_view t) {
        auto l = label(t, 15, true);
        l.Margin({0, 6, 0, 0});
        list.Append(l);
    };
    auto toggle = [&](std::wstring_view t, bool on, auto change) {
        CheckBox c;
        c.Content(box_value(hstring(t)));
        c.IsChecked(on);
        c.MinHeight(24);
        c.Click([this, change](auto const &sender, auto &&) {
            if (!syncing)
                guarded([&] { change(sender.template as<CheckBox>().IsChecked().Value()); });
        });
        list.Append(c);
    };
    auto slider = [&](std::wstring_view t, int low, int high, int value, auto change) {
        auto h = label(std::format(L"{}   {}", t, value));
        list.Append(h);
        Slider s;
        s.Minimum(low);
        s.Maximum(high);
        s.StepFrequency(1);
        s.Value(value);
        s.ValueChanged([this, h, t = std::wstring(t), change](auto &&, auto &a) {
            if (!syncing)
            {
                int v = int(lround(a.NewValue()));
                h.Text(std::format(L"{}   {}", t, v));
                change(v);
            }
        });
        list.Append(s);
    };
    heading(L"Inspector");
    heading(L"Palette");
    Grid palette;
    for (int i = 0; i < 8; i++)
        addCol(palette, 1, GridUnitType::Star);
    // Long imported palettes stay inside their own scrolling area.
    auto &s = editor.scene();
    for (int i = 0; i < int(s.palette.size()); i++)
    {
        if (!(i % 8))
            addRow(palette, 28, GridUnitType::Pixel);
        auto ink = s.palette[i];
        Button b;
        b.Width(23);
        b.Height(23);
        b.MinWidth(0);
        b.MinHeight(0);
        b.Padding({});
        b.CornerRadius({5, 5, 5, 5});
        b.Background(brush(lround(ink.r * 255), lround(ink.g * 255), lround(ink.b * 255)));
        if (ink == editor.ink)
        {
            b.BorderThickness({2, 2, 2, 2});
            b.BorderBrush(brush(40, 104, 71));
        }
        auto hex = std::format(L"#{:02X}{:02X}{:02X}", int(lround(255 * ink.r)),
                               int(lround(255 * ink.g)), int(lround(255 * ink.b)));
        tooltip(b, hex);
        Automation::AutomationProperties::SetName(b, hex);
        b.Click([this, ink](auto &&, auto &&) {
            editor.ink = ink;
            sidebar();
        });
        at(palette, b, i / 8, i % 8);
    }
    ScrollViewer sw;
    sw.MaxHeight(116);
    sw.Content(palette);
    list.Append(sw);
    list.Append(button(L"Choose color…", [this] {
        static COLORREF custom[16]{};
        CHOOSECOLORW d{sizeof d};
        d.hwndOwner = hwnd;
        d.lpCustColors = custom;
        auto i = editor.ink;
        d.rgbResult = RGB(lround(255 * i.r), lround(255 * i.g), lround(255 * i.b));
        d.Flags = CC_FULLOPEN | CC_RGBINIT;
        if (ChooseColorW(&d))
        {
            Ink color{GetRValue(d.rgbResult) / 255.f, GetGValue(d.rgbResult) / 255.f,
                      GetBValue(d.rgbResult) / 255.f};
            editor.ink = color;
            action([&] {
                auto &p = editor.scene().palette;
                if (p.size() < 256 && std::ranges::find(p, color) == p.end())
                {
                    p.push_back(color);
                    editor.touch();
                }
            });
        }
    }));
    if (editor.tool == Tool::Add || editor.tool == Tool::Paint || editor.tool == Tool::Erase)
    {
        slider(L"Brush size", 1, 8, editor.brushSize, [this](int v) { editor.brushSize = v; });
        toggle(L"Mirror X", editor.mirrorX, [this](bool v) { editor.mirrorX = v; });
        toggle(L"Mirror Z", editor.mirrorZ, [this](bool v) { editor.mirrorZ = v; });
    }
    if (editor.tool == Tool::Box)
        slider(L"Box depth", 1, 64, editor.depth, [this](int v) { editor.depth = v; });
    if (editor.tool == Tool::Select)
    {
        auto r = row();
        r.Children().Append(button(L"Copy", [this] { guarded([&] { copy(false); }); }));
        r.Children().Append(button(L"Paste", [this] { guarded([&] { paste(); }); }));
        r.Children().Append(button(L"Duplicate", [this] { action([&] { editor.duplicate(); }); }));
        list.Append(r);
        auto rot = row();
        rot.Children().Append(label(L"Rotate"));
        for (int i = 0; i < 3; i++)
            rot.Children().Append(button(std::wstring(1, wchar_t('X' + i)),
                                         [this, i] { action([&] { editor.transform({}, i); }); }));
        list.Append(rot);
    }
    heading(L"Layers");
    ComboBox layers;
    layers.HorizontalAlignment(HorizontalAlignment::Stretch);
    for (auto it = s.layers.rbegin(); it != s.layers.rend(); ++it)
        layers.Items().Append(box_value(to_hstring(it->name)));
    layers.SelectedIndex(int(s.layers.size()) - 1 - s.active);
    layers.SelectionChanged([this](auto const &sender, auto &&) {
        auto layers = sender.template as<ComboBox>();
        if (syncing || layers.SelectedIndex() < 0)
            return;
        clearInteraction(true);
        editor.scene().active = int(editor.scene().layers.size()) - 1 - layers.SelectedIndex();
        editor.state.selected.clear();
        refresh(true);
    });
    list.Append(layers);
    auto actions = row();
    actions.Children().Append(button(L"+ Layer", [this] {
        action([&] {
            auto &s = editor.scene();
            if (s.layers.size() < 128)
            {
                Layer l;
                l.name = std::format("Layer {}", s.layers.size() + 1);
                s.layers.push_back(std::move(l));
                s.active = int(s.layers.size()) - 1;
                editor.state.selected.clear();
                editor.touch();
            }
        });
    }));
    actions.Children().Append(button(L"Remove", [this] {
        action([&] {
            auto &s = editor.scene();
            if (s.layers.size() > 1)
            {
                s.layers.erase(s.layers.begin() + s.active);
                s.active = std::min(s.active, int(s.layers.size()) - 1);
                editor.state.selected.clear();
                editor.touch();
            }
        });
    }));
    list.Append(actions);
    TextBox name;
    name.Header(box_value(L"Layer name"));
    name.Text(to_hstring(s.layers[s.active].name));
    name.KeyDown([this](auto const &sender, auto &a) {
        auto name = sender.template as<TextBox>();
        if (a.Key() == winrt::Windows::System::VirtualKey::Enter)
        {
            auto value = to_string(name.Text());
            if (!value.empty())
                action([&] {
                    auto &n = editor.scene().layers[editor.scene().active].name;
                    if (n != value)
                    {
                        n = value;
                        editor.touch();
                    }
                });
            a.Handled(true);
        }
    });
    list.Append(name);
    toggle(L"Layer visible", s.layers[s.active].visible, [this](bool v) {
        action([&] {
            editor.scene().layers[editor.scene().active].visible = v;
            editor.state.selected.clear();
            editor.touch();
        });
    });
    heading(L"View");
    toggle(L"Floor grid", viewport.grid, [this](bool v) {
        viewport.grid = v;
        redraw();
    });
    toggle(L"Voxel edges", viewport.edges, [this](bool v) {
        viewport.edges = v;
        redraw();
    });
    toggle(L"Horizontal slice", sliced, [this](bool on) {
        setSlice(on, sliceLevel);
        sidebar();
    });
    if (sliced)
        slider(L"Cut height", 0, 255, sliceLevel, [this](int v) { setSlice(true, v); });
    syncing = false;
}
void Studio::action(std::function<void()> edit)
{
    editor.end();
    editor.begin();
    try
    {
        edit();
        editor.end();
    }
    catch (...)
    {
        editor.cancel();
        throw;
    }
    refresh(true);
}
void Studio::tool(Tool t)
{
    clearInteraction(true);
    editor.tool = t;
    editor.state.selected.clear();
    refresh(true);
}
void Studio::setSlice(bool on, int y)
{
    clearInteraction(true);
    sliced = on;
    sliceLevel = std::clamp(y, 0, 255);
    editor.ceiling = sliced ? sliceLevel : 255;
    std::erase_if(editor.state.selected, [&](Cell c) { return !editor.eligible(c); });
    refresh();
}
void Studio::orient(int mode)
{
    auto &c = viewport.camera;
    c.yaw = mode == 3 ? 1.5707963f : mode == 0 ? .63f : 0;
    c.pitch = mode == 2 ? 1.5707963f : mode == 0 ? .48f : 0;
    c.fit(visible);
    redraw();
}
void Studio::refresh(bool side)
{
    if (!ready)
        return;
    visible = editor.scene().visible(editor.ceiling);
    viewport.level = sliced ? sliceLevel : 0;
    viewport.model(visible, editor.state.selected);
    if (side)
        sidebar();
    for (int i = 0; i < 10; i++)
        tools[i].BorderThickness(i == int(editor.tool) ? Thickness{3, 1, 1, 1} : Thickness{1, 1, 1, 1});
    undoButton.IsEnabled(editor.canUndo());
    redoButton.IsEnabled(editor.canRedo());
    title.Text(to_hstring(editor.scene().title));
    window.Title(std::wstring(editor.dirty() ? L"● " : L"") + title.Text().c_str() + L" — Forma");
    updateStatus();
    redraw();
}
void Studio::updateStatus()
{
    auto &s = editor.scene();
    std::wstring hint;
    if (!fragment.empty())
        hint = validPaste ? L"Enter or click to paste · Esc to cancel"
                          : L"Placement blocked · Esc to cancel";
    else if (drag == Drag::Extrude)
        hint = std::format(L"Depth {}", dragDepth);
    else if (editor.tool == Tool::Select)
        hint = std::format(L"{} selected · Drag to select or move", editor.state.selected.size());
    else
        hint = L"Right-drag to orbit · Shift-drag to pan · Wheel to zoom";
    status.Text(std::format(L"{}   ·   {}   |   {} voxels   ·   {}", names[int(editor.tool)],
                            to_hstring(s.layers[s.active].name).c_str(), visible.size(), hint));
}
void Studio::resize()
{
    if (!ready)
        return;
    float w = float(canvas.ActualWidth()), h = float(canvas.ActualHeight());
    if (w <= 1 || h <= 1)
        return;
    viewport.resize(w, h, canvas.CompositionScaleX(), canvas.CompositionScaleY());
    if (!fitted)
    {
        viewport.camera.fit(visible);
        fitted = true;
    }
    redraw();
}
void Studio::redraw()
{
    if (ready)
        viewport.draw();
}
void Studio::project(Scene s, std::filesystem::path path)
{
    clearInteraction(true);
    editor.reset(std::move(s));
    file = std::move(path);
    sliced = false;
    sliceLevel = 0;
    editor.depth = 1;
    editor.mirrorX = editor.mirrorZ = false;
    refresh(true);
    orient(0);
}
bool Studio::mayClose()
{
    editor.end();
    if (!editor.dirty())
        return true;
    auto choice =
        MessageBoxW(hwnd, L"Save changes to this project?", L"Forma", MB_YESNOCANCEL | MB_ICONQUESTION);
    return choice == IDNO || (choice == IDYES && save());
}
void Studio::open()
{
    auto p = pathDialog(hwnd, false, L"Forma and MagicaVoxel\0*.vxl;*.vox\0\0", L"vxl");
    if (!p.empty())
        openPath(p);
}
void Studio::openPath(std::filesystem::path const &p)
{
    bool vox = ext(p) == L".vox";
    auto s = vox ? readVox(p) : readProject(p);
    if (mayClose())
        project(std::move(s), vox ? std::filesystem::path{} : p);
}
bool Studio::save(bool as)
{
    editor.end();
    auto p = file;
    if (as || p.empty())
        p = pathDialog(hwnd, true, L"Forma project\0*.vxl\0\0", L"vxl",
                       to_hstring(editor.scene().title).c_str());
    if (p.empty())
        return false;
    if (ext(p) != L".vxl")
    {
        message(L"Use the .vxl extension for a Forma project.");
        return false;
    }
    saveProject(editor.scene(), p);
    file = p;
    editor.scene().title = to_string(p.stem().wstring());
    editor.markSaved();
    refresh();
    return true;
}
void Studio::exportFile(int kind)
{
    const wchar_t *filter[] = {L"MagicaVoxel\0*.vox\0\0", L"Scene image\0*.png\0\0",
                               L"Wavefront mesh\0*.obj\0\0"};
    const wchar_t *types[] = {L"vox", L"png", L"obj"};
    auto p = pathDialog(hwnd, true, filter[kind], types[kind], to_hstring(editor.scene().title).c_str());
    if (p.empty())
        return;
    if (kind == 0)
        saveVox(editor.scene(), p);
    else if (kind == 2)
        saveObj(editor.scene(), p);
    else
    {
        viewport.model(visible, {});
        try
        {
            viewport.png(p);
        }
        catch (...)
        {
            refresh();
            throw;
        }
        refresh();
    }
}
} // namespace forma
