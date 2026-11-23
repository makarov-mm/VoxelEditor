#include "Scene.h"
#include <windows.h>
#include <objbase.h>
#include <cstdio>
#include <stdexcept>
namespace forma
{
std::string newID()
{
    GUID g{};
    if (FAILED(CoCreateGuid(&g)))
        throw std::runtime_error("Cannot create a layer ID.");
    char b[37];
    std::snprintf(b, sizeof b, "%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X", g.Data1, g.Data2,
                  g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5],
                  g.Data4[6], g.Data4[7]);
    return b;
}
const Ink *Volume::get(Cell p) const
{
    if (!p.valid())
        return nullptr;
    auto c = chunks.find(chunk(p));
    if (c == chunks.end())
        return nullptr;
    auto i = c->second->find(p);
    return i == c->second->end() ? nullptr : &i->second;
}
bool Volume::put(Cell p, std::optional<Ink> v)
{
    if (!p.valid())
        return false;
    auto old = get(p);
    if ((!v && !old) || (old && v && *old == *v))
        return false;
    auto key = chunk(p);
    auto &block = chunks[key];
    if (!block)
        block = std::make_shared<Cells>();
    else if (block.use_count() != 1)
        block = std::make_shared<Cells>(*block);
    if (v)
        block->insert_or_assign(p, *v);
    else
    {
        block->erase(p);
        if (block->empty())
            chunks.erase(key);
    }
    return true;
}
Scene::Scene()
{
    for (unsigned h : {0xE96555, 0xBF5045, 0xF5BD62, 0xF4E6CA, 0xD8BB84, 0xCCBDA1, 0x926D50, 0x314552,
                       0xA4AE76, 0xC1C797, 0x6E916F, 0x4F7467, 0x538F8D, 0x82BCBA, 0xD4EBDA, 0x697B82})
        palette.push_back(Ink::rgb(h));
}
Cells Scene::visible(int limit) const
{
    Cells out;
    for (auto const &layer : layers)
        if (layer.visible)
            layer.cells.each([&](Cell p, Ink const &ink) {
                if (p.y <= limit)
                    out.insert_or_assign(p, ink);
            });
    return out;
}
int Scene::owner(Cell p) const
{
    for (int i = int(layers.size()) - 1; i >= 0; --i)
        if (layers[i].visible && layers[i].cells.get(p))
            return i;
    return -1;
}
void Editor::reset(Scene s)
{
    state = {std::move(s), {}, 0};
    past.clear();
    future.clear();
    before.reset();
    changed = false;
    saved = 0;
    ceiling = 255;
    ink = state.scene.palette.front();
}
void Editor::begin()
{
    if (!before)
    {
        before = state;
        changed = false;
    }
}
void Editor::end()
{
    if (before && changed)
    {
        past.push_back(std::move(*before));
        if (past.size() > 100)
            past.pop_front();
        future.clear();
        state.id = ++serial;
    }
    before.reset();
    changed = false;
}
void Editor::cancel()
{
    if (before)
        state = std::move(*before);
    before.reset();
    changed = false;
}
void Editor::undo()
{
    end();
    if (past.empty())
        return;
    future.push_back(std::move(state));
    state = std::move(past.back());
    past.pop_back();
}
void Editor::redo()
{
    end();
    if (future.empty())
        return;
    past.push_back(std::move(state));
    state = std::move(future.back());
    future.pop_back();
}
bool Editor::write(Cell p, std::optional<Ink> value)
{
    auto &l = scene().layers.at(scene().active);
    if (!l.visible || p.y > ceiling || !l.cells.put(p, value))
        return false;
    touch();
    return true;
}
bool Editor::eligible(Cell p) const
{
    return p.valid() && p.y <= ceiling && state.scene.owner(p) == state.scene.active;
}
void Editor::brush(Pick const &pick)
{
    if (tool == Tool::Pick)
    {
        if (pick.hit)
        {
            auto i = scene().owner(*pick.hit);
            if (i >= 0)
                ink = *scene().layers[i].cells.get(*pick.hit);
        }
        return;
    }
    auto target = tool == Tool::Add ? pick.adjacent : pick.hit;
    if (!target || !target->valid() || target->y > ceiling)
        return;
    const int n = std::clamp(brushSize, 1, 8);
    auto start = [&](int p, int d) {
        if (tool == Tool::Add && d != 0)
            return d > 0 ? p : p - n + 1;
        return p - (n - 1) / 2;
    };
    Cell lo{start(target->x, pick.normal.x), start(target->y, pick.normal.y),
            start(target->z, pick.normal.z)};
    for (int x = 0; x < n; x++)
        for (int y = 0; y < n; y++)
            for (int z = 0; z < n; z++)
            {
                Cell p = lo + Cell{x, y, z};
                if (!p.valid() || p.y > ceiling)
                    continue;
                for (int a = 0; a <= int(mirrorX); a++)
                    for (int b = 0; b <= int(mirrorZ); b++)
                    {
                        Cell q{a ? -1 - p.x : p.x, p.y, b ? -1 - p.z : p.z};
                        if (tool == Tool::Add)
                        {
                            if (scene().owner(q) < 0)
                                write(q, ink);
                        }
                        else if (eligible(q))
                            write(q, tool == Tool::Erase ? std::nullopt : std::optional(ink));
                    }
            }
}
void Editor::fill(Cell p)
{
    if (!eligible(p))
        return;
    auto &vol = scene().layers[scene().active].cells;
    Ink original = *vol.get(p);
    if (original == ink)
        return;
    std::vector<Cell> pending{p};
    write(p, ink);
    while (!pending.empty())
    {
        auto c = pending.back();
        pending.pop_back();
        for (auto d : normals)
        {
            auto q = c + d;
            auto v = vol.get(q);
            if (v && *v == original && eligible(q))
            {
                write(q, ink);
                pending.push_back(q);
            }
        }
    }
}
Cells Editor::shape(Cell a, Cell b, Cell normal) const
{
    Cells out;
    if (tool == Tool::Box)
        b = b + normal * (depth - 1);
    if (!a.valid() || !b.valid() || std::max(a.y, b.y) > ceiling)
        return out;
    auto lo = lower(a, b), hi = upper(a, b), s = hi - lo;
    auto add = [&](Cell p) {
        if (state.scene.owner(p) < 0)
            out.emplace(p, ink);
    };
    if (tool == Tool::Line)
    {
        int n = std::max({s.x, s.y, s.z, 1});
        for (int i = 0; i <= n; i++)
        {
            auto lerp = [&](int v, int w) {
                return int(std::floor((v * (n - i) + w * i) / double(n) + .5));
            };
            add({lerp(a.x, b.x), lerp(a.y, b.y), lerp(a.z, b.z)});
        }
    }
    else if ((s.x + 1) * (s.y + 1) * (s.z + 1) <= 262144)
    {
        for (int x = lo.x; x <= hi.x; x++)
            for (int y = lo.y; y <= hi.y; y++)
                for (int z = lo.z; z <= hi.z; z++)
                    add({x, y, z});
    }
    return out;
}
Cells Editor::extrusion(Cell seed, Cell normal, int distance) const
{
    Cells out;
    if (!eligible(seed) || distance < 1 || distance > 255)
        return out;
    Selection face{seed};
    std::vector<Cell> todo{seed};
    while (!todo.empty())
    {
        auto p = todo.back();
        todo.pop_back();
        for (auto d : normals)
        {
            if (d.x * normal.x + d.y * normal.y + d.z * normal.z)
                continue;
            auto q = p + d, ahead = q + normal;
            if (!face.contains(q) && eligible(q) && (ahead.y > ceiling || state.scene.owner(ahead) < 0))
            {
                face.insert(q);
                todo.push_back(q);
            }
        }
        if (face.size() > 262144u / unsigned(distance))
            return {};
    }
    auto &vol = state.scene.layers[state.scene.active].cells;
    for (auto p : face)
        for (int i = 1; i <= distance; i++)
        {
            auto q = p + normal * i;
            if (!q.valid() || q.y > ceiling || state.scene.owner(q) >= 0)
                return {};
            out.emplace(q, *vol.get(p));
        }
    return out;
}
void Editor::apply(Cells const &edits)
{
    for (auto const &[p, v] : edits)
        write(p, v);
}
void Editor::selectAll()
{
    state.selected.clear();
    scene().layers[scene().active].cells.each([&](Cell p, auto &) {
        if (eligible(p))
            state.selected.insert(p);
    });
}
void Editor::eraseSelection()
{
    for (auto p : state.selected)
        if (eligible(p))
            write(p, {});
    state.selected.clear();
}
bool Editor::transform(Cell delta, int axis, bool copy, bool checkOnly)
{
    if (state.selected.empty())
        return false;
    Cell lo = *state.selected.begin(), hi = lo;
    for (auto p : state.selected)
    {
        lo = lower(lo, p);
        hi = upper(hi, p);
    }
    auto s = hi - lo;
    Cell half{s.x / 2, s.y / 2, s.z / 2};
    auto mid = lo + half;
    Cells dest;
    for (auto p : state.selected)
    {
        if (!eligible(p))
            return false;
        auto local = p - lo;
        auto q = p + delta;
        if (axis == 0)
            q = mid + Cell{local.x - half.x, s.z - local.z - half.z, local.y - half.y};
        if (axis == 1)
            q = mid + Cell{local.z - half.z, local.y - half.y, s.x - local.x - half.x};
        if (axis == 2)
            q = mid + Cell{s.y - local.y - half.y, local.x - half.x, local.z - half.z};
        if (!q.valid() || q.y > ceiling)
            return false;
        for (int i = 0; i < int(scene().layers.size()); i++)
        {
            auto const &l = scene().layers[i];
            if (l.visible && l.cells.get(q) &&
                (copy || !state.selected.contains(q) || (i != scene().active && q != p)))
                return false;
        }
        dest.emplace(q, *scene().layers[scene().active].cells.get(p));
    }
    if (checkOnly)
        return true;
    if (!copy)
        eraseSelection();
    else
        state.selected.clear();
    apply(dest);
    for (auto const &[p, v] : dest)
        state.selected.insert(p);
    return true;
}
void Editor::duplicate()
{
    if (state.selected.empty())
        return;
    auto lo = *state.selected.begin(), hi = lo;
    for (auto p : state.selected)
    {
        lo = lower(lo, p);
        hi = upper(hi, p);
    }
    auto s = hi - lo + Cell{1, 1, 1};
    for (Cell d : std::array<Cell, 6>{
             {{s.x, 0, 0}, {-s.x, 0, 0}, {0, 0, s.z}, {0, 0, -s.z}, {0, s.y, 0}, {0, -s.y, 0}}})
        if (transform(d, -1, true))
            break;
}
} // namespace forma
