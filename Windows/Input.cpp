#include "Studio.h"
#include <format>
#include <stdexcept>
namespace forma
{
using namespace winrt;
namespace
{
bool down(int vk)
{
    return (GetKeyState(vk) & 0x8000) != 0;
}
UINT clipFormat()
{
    static UINT f = RegisterClipboardFormatW(L"studio.forma.voxel-fragment.FVX1");
    return f;
}
struct Clipboard
{
    Clipboard(HWND w)
    {
        if (!OpenClipboard(w))
            throw std::runtime_error("The clipboard is busy.");
    }
    ~Clipboard()
    {
        CloseClipboard();
    }
};
} // namespace
void Studio::copy(bool cut)
{
    Cells picked;
    for (auto p : editor.state.selected)
        if (editor.eligible(p))
            picked.emplace(p, *editor.scene().layers[editor.scene().active].cells.get(p));
    if (picked.empty())
        return;
    auto bytes = fragmentBytes(picked);
    {
        Clipboard clip(hwnd);
        auto h = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.size());
        if (!h)
            throw std::bad_alloc();
        auto ptr = GlobalLock(h);
        if (!ptr)
        {
            GlobalFree(h);
            throw std::bad_alloc();
        }
        memcpy(ptr, bytes.data(), bytes.size());
        GlobalUnlock(h);
        if (!EmptyClipboard() || !SetClipboardData(clipFormat(), h))
        {
            GlobalFree(h);
            throw std::runtime_error("Cannot copy selection.");
        }
    }
    if (cut)
        action([&] { editor.eraseSelection(); });
}
void Studio::paste()
{
    if (!IsClipboardFormatAvailable(clipFormat()))
        return;
    Cells result;
    {
        Clipboard clip(hwnd);
        auto h = GetClipboardData(clipFormat());
        if (!h)
            return;
        auto n = GlobalSize(h);
        auto ptr = static_cast<const char *>(GlobalLock(h));
        if (!ptr)
            return;
        try
        {
            result = parseFragment({ptr, n});
        }
        catch (...)
        {
            GlobalUnlock(h);
            throw;
        }
        GlobalUnlock(h);
    }
    tool(Tool::Select);
    fragment = std::move(result);
    fragmentBase = fragment.begin()->first;
    for (auto &[p, _] : fragment)
        fragmentBase = lower(fragmentBase, p);
    anchor = fragmentBase;
    updatePaste();
}
void Studio::updatePaste()
{
    validPaste = editor.scene().layers[editor.scene().active].visible;
    preview.clear();
    auto offset = anchor - fragmentBase;
    for (auto &[p, i] : fragment)
    {
        auto q = p + offset;
        if (!q.valid() || q.y > editor.ceiling || visible.contains(q))
            validPaste = false;
        preview.emplace(q, i);
    }
    viewport.overlay(preview, !validPaste);
    updateStatus();
    redraw();
}
void Studio::place()
{
    if (!validPaste || fragment.empty())
        return;
    auto writes = std::move(preview);
    fragment.clear();
    viewport.overlay({});
    action([&] {
        editor.apply(writes);
        editor.state.selected.clear();
        for (auto &[p, i] : writes)
            editor.state.selected.insert(p);
    });
}
void Studio::clearInteraction(bool rollback)
{
    if (drag == Drag::Brush)
    {
        if (rollback)
            editor.cancel();
        else
            editor.end();
    }
    drag = Drag::None;
    dragAnchor.reset();
    fragment.clear();
    preview.clear();
    strokeScene.clear();
    validPaste = false;
    selectionBox.Visibility(X::Visibility::Collapsed);
    if (ready)
    {
        canvas.ReleasePointerCaptures();
        viewport.overlay({});
    }
}
void Studio::hover(Pick const &pick)
{
    Cells overlay;
    if (editor.tool == Tool::Add || editor.tool == Tool::Paint || editor.tool == Tool::Erase ||
        editor.tool == Tool::Pick)
    {
        bool add = editor.tool == Tool::Add;
        auto center = add ? pick.adjacent : pick.hit;
        if (center && center->valid() && center->y <= editor.ceiling)
        {
            int n = editor.tool == Tool::Pick ? 1 : editor.brushSize;
            auto start = [&](int c, int normal) {
                return add && normal ? c - (normal < 0 ? n - 1 : 0) : c - (n - 1) / 2;
            };
            Cell lo{start(center->x, pick.normal.x), start(center->y, pick.normal.y),
                    start(center->z, pick.normal.z)};
            for (int x = 0; x < n; x++)
                for (int y = 0; y < n; y++)
                    for (int z = 0; z < n; z++)
                    {
                        auto p = lo + Cell{x, y, z};
                        for (int a = 0; a <= int(editor.tool != Tool::Pick && editor.mirrorX); a++)
                            for (int b = 0; b <= int(editor.tool != Tool::Pick && editor.mirrorZ); b++)
                            {
                                Cell q{a ? -1 - p.x : p.x, p.y, b ? -1 - p.z : p.z};
                                if (q.valid() && q.y <= editor.ceiling &&
                                    (add ? !visible.contains(q) : visible.contains(q)))
                                    overlay.emplace(q, editor.ink);
                            }
                    }
        }
    }
    viewport.overlay(overlay, editor.tool == Tool::Erase);
    redraw();
}
void Studio::pointerDown(Input::PointerRoutedEventArgs const &a)
{
    if (drag != Drag::None)
        return;
    auto point = a.GetCurrentPoint(canvas);
    auto prop = point.Properties();
    auto pos = point.Position();
    lastX = startX = pos.X;
    lastY = startY = pos.Y;
    root.Focus(X::FocusState::Pointer);
    if (prop.IsRightButtonPressed() || down(VK_MENU))
        drag = Drag::Orbit;
    else if (prop.IsMiddleButtonPressed() || down(VK_SHIFT))
        drag = Drag::Pan;
    else if (!prop.IsLeftButtonPressed())
        return;
    else if (!fragment.empty())
    {
        place();
        a.Handled(true);
        return;
    }
    else
    {
        auto h = viewport.camera.pick(pos.X, pos.Y, visible, sliced ? sliceLevel : 0);
        normal = h.normal;
        switch (editor.tool)
        {
        case Tool::Fill:
            if (h.hit)
                action([&] { editor.fill(*h.hit); });
            break;
        case Tool::Pick:
            editor.brush(h);
            sidebar();
            break;
        case Tool::Select:
            addSelection = down(VK_CONTROL);
            dragAnchor = h.hit;
            moveDelta = {};
            if (h.hit && editor.state.selected.contains(*h.hit) && !addSelection)
                drag = Drag::Move;
            else
                drag = Drag::Select;
            break;
        case Tool::Line:
        case Tool::Rectangle:
        case Tool::Box:
            if (h.adjacent && h.adjacent->valid())
            {
                drag = Drag::Shape;
                dragAnchor = h.adjacent;
                preview = editor.shape(*dragAnchor, *dragAnchor, normal);
                viewport.overlay(preview);
                redraw();
            }
            break;
        case Tool::Extrude:
            if (h.hit)
            {
                drag = Drag::Extrude;
                dragAnchor = h.hit;
                dragDepth = 1;
                preview = editor.extrusion(*h.hit, normal, 1);
                viewport.overlay(preview);
                redraw();
            }
            break;
        default:
            drag = Drag::Brush;
            strokeScene = visible;
            editor.begin();
            editor.brush(h);
            refresh();
            break;
        }
    }
    if (drag != Drag::None)
    {
        canvas.CapturePointer(a.Pointer());
        a.Handled(true);
    }
}
void Studio::pointerMove(Input::PointerRoutedEventArgs const &a)
{
    auto pos = a.GetCurrentPoint(canvas).Position();
    float x = pos.X, y = pos.Y, dx = x - lastX, dy = y - lastY;
    lastX = x;
    lastY = y;
    auto &c = viewport.camera;
    if (drag == Drag::Orbit)
    {
        c.yaw -= dx * .009f;
        c.pitch = std::clamp(c.pitch + dy * .008f, .035f, 1.555f);
        redraw();
        return;
    }
    if (drag == Drag::Pan)
    {
        c.center = c.center + c.right() * (-dx / c.unit()) + c.up() * (dy / c.unit());
        redraw();
        return;
    }
    auto h = c.pick(x, y, drag == Drag::Brush ? strokeScene : visible, sliced ? sliceLevel : 0);
    if (!fragment.empty())
    {
        if (h.adjacent)
        {
            anchor = *h.adjacent;
            updatePaste();
        }
        return;
    }
    switch (drag)
    {
    case Drag::Brush:
        editor.brush(h);
        refresh();
        break;
    case Drag::Shape: {
        auto cell = c.onPlane(x, y, *dragAnchor, normal);
        preview = cell ? editor.shape(*dragAnchor, *cell, normal) : Cells{};
        viewport.overlay(preview);
        redraw();
        break;
    }
    case Drag::Extrude: {
        auto [ax, ay] = c.screen(*dragAnchor);
        auto [bx, by] = c.screen(*dragAnchor + normal);
        float vx = bx - ax, vy = by - ay, len = vx * vx + vy * vy;
        float amount = len > .12f * c.unit() * c.unit() ? ((x - startX) * vx + (y - startY) * vy) / len
                                                        : (startY - y) / c.unit();
        dragDepth = std::clamp(1 + int(lround(amount)), 1, 255);
        preview = editor.extrusion(*dragAnchor, normal, dragDepth);
        viewport.overlay(preview);
        updateStatus();
        redraw();
        break;
    }
    case Drag::Select:
        selectionBox.Margin({std::min(startX, x), std::min(startY, y), 0, 0});
        selectionBox.Width(fabsf(x - startX));
        selectionBox.Height(fabsf(y - startY));
        selectionBox.Visibility(X::Visibility::Visible);
        break;
    case Drag::Move: {
        auto q = c.onPlane(x, y, *dragAnchor, normal);
        if (!q)
            break;
        moveDelta = *q - *dragAnchor;
        preview.clear();
        for (auto p : editor.state.selected)
            preview.emplace(p + moveDelta, editor.ink);
        viewport.overlay(preview, !editor.transform(moveDelta, -1, false, true));
        redraw();
        break;
    }
    default:
        hover(h);
        break;
    }
}
void Studio::pointerUp(Input::PointerRoutedEventArgs const &a)
{
    if (drag == Drag::None)
        return;
    auto p = a.GetCurrentPoint(canvas).Position();
    if (fabsf(p.X - lastX) + fabsf(p.Y - lastY) > .1f)
        pointerMove(a);
    auto mode = drag;
    drag = Drag::None;
    canvas.ReleasePointerCapture(a.Pointer());
    if (mode == Drag::Brush)
        editor.end();
    if (mode == Drag::Shape || mode == Drag::Extrude)
    {
        editor.begin();
        editor.apply(preview);
        editor.end();
    }
    if (mode == Drag::Move && moveDelta != Cell{})
    {
        editor.begin();
        editor.transform(moveDelta);
        editor.end();
    }
    if (mode == Drag::Select)
    {
        if (!addSelection)
            editor.state.selected.clear();
        if (fabsf(p.X - startX) + fabsf(p.Y - startY) < 5)
        {
            if (dragAnchor && editor.eligible(*dragAnchor))
            {
                if (addSelection && editor.state.selected.contains(*dragAnchor))
                    editor.state.selected.erase(*dragAnchor);
                else
                    editor.state.selected.insert(*dragAnchor);
            }
        }
        else
            for (auto &[q, i] : visible)
                if (editor.eligible(q))
                {
                    auto [x, y] = viewport.camera.screen(q);
                    if (x >= std::min(startX, p.X) && x <= std::max(startX, p.X) &&
                        y >= std::min(startY, p.Y) && y <= std::max(startY, p.Y))
                        editor.state.selected.insert(q);
                }
    }
    dragAnchor.reset();
    strokeScene.clear();
    preview.clear();
    viewport.overlay({});
    selectionBox.Visibility(X::Visibility::Collapsed);
    refresh();
    a.Handled(true);
}
void Studio::key(Input::KeyRoutedEventArgs const &a)
{
    if (a.OriginalSource().try_as<C::TextBox>() ||
        Input::FocusManager::GetFocusedElement(root.XamlRoot()).try_as<C::TextBox>())
        return;
    int k = int(a.Key());
    bool ctrl = down(VK_CONTROL), shift = down(VK_SHIFT);
    if (k == VK_ESCAPE)
    {
        clearInteraction(true);
        editor.state.selected.clear();
        refresh();
        a.Handled(true);
        return;
    }
    if (drag != Drag::None)
        return;
    if (ctrl)
    {
        switch (k)
        {
        case 'N':
            if (mayClose())
                project(Scene{});
            break;
        case 'O':
            open();
            break;
        case 'S':
            save(shift);
            break;
        case 'Z':
            if (shift)
                editor.redo();
            else
                editor.undo();
            refresh(true);
            break;
        case 'Y':
            editor.redo();
            refresh(true);
            break;
        case 'A':
            if (editor.tool == Tool::Select)
            {
                editor.selectAll();
                refresh();
            }
            break;
        case 'D':
            action([&] { editor.duplicate(); });
            break;
        case 'C':
            copy(false);
            break;
        case 'X':
            copy(true);
            break;
        case 'V':
            paste();
            break;
        case 'P':
            if (shift)
                exportFile(1);
            else
                return;
            break;
        default:
            return;
        }
    }
    else if (k == VK_LEFT || k == VK_RIGHT || k == VK_UP || k == VK_DOWN || k == VK_PRIOR ||
             k == VK_NEXT)
    {
        Cell d{k == VK_RIGHT  ? 1
               : k == VK_LEFT ? -1
                              : 0,
               k == VK_PRIOR  ? 1
               : k == VK_NEXT ? -1
                              : 0,
               k == VK_DOWN ? 1
               : k == VK_UP ? -1
                            : 0};
        if (!fragment.empty())
        {
            anchor = anchor + d;
            updatePaste();
        }
        else if (editor.tool == Tool::Select)
            action([&] { editor.transform(d); });
        else
            return;
    }
    else if (!fragment.empty() && k == VK_RETURN)
        place();
    else if (k == VK_DELETE)
        action([&] { editor.eraseSelection(); });
    else if (k == 'F')
    {
        viewport.camera.fit(visible);
        redraw();
    }
    else if (k == 'G' || k == 'W')
    {
        auto &value = k == 'G' ? viewport.grid : viewport.edges;
        value = !value;
        sidebar();
        redraw();
    }
    else if (k == 'Y')
    {
        setSlice(!sliced, sliceLevel);
        sidebar();
    }
    else if (k == VK_OEM_COMMA || k == VK_OEM_PERIOD)
    {
        setSlice(true, sliceLevel + (k == VK_OEM_PERIOD ? 1 : -1));
        sidebar();
    }
    else if (k == VK_OEM_4 || k == VK_OEM_6)
    {
        editor.brushSize = std::clamp(editor.brushSize + (k == VK_OEM_6 ? 1 : -1), 1, 8);
        sidebar();
    }
    else
    {
        std::string keys = "VBEISLROXK";
        auto i = keys.find(char(k));
        if (i == keys.npos)
            return;
        tool(Tool(i));
    }
    a.Handled(true);
}
} // namespace forma
