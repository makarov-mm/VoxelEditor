#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace forma
{
struct Cell
{
    int x{}, y{}, z{};
    auto operator<=>(Cell const &) const = default;
    Cell operator+(Cell b) const
    {
        return {x + b.x, y + b.y, z + b.z};
    }
    Cell operator-(Cell b) const
    {
        return {x - b.x, y - b.y, z - b.z};
    }
    Cell operator*(int n) const
    {
        return {x * n, y * n, z * n};
    }
    bool valid() const
    {
        return x >= -128 && x < 128 && y >= 0 && y < 256 && z >= -128 && z < 128;
    }
};
struct CellHash
{
    size_t operator()(Cell c) const noexcept
    {
        return (uint32_t(c.x) * 73856093u) ^ (uint32_t(c.y) * 19349663u) ^ (uint32_t(c.z) * 83492791u);
    }
};
inline constexpr std::array<Cell, 6> normals{
    {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}};
inline Cell lower(Cell a, Cell b)
{
    return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)};
}
inline Cell upper(Cell a, Cell b)
{
    return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
}
struct Material
{
    unsigned alpha{255};
    std::map<std::string, std::string> properties;
    bool operator==(Material const &) const = default;
};
struct Ink
{
    float r{}, g{}, b{};
    std::shared_ptr<const Material> surface;
    static Ink rgb(unsigned hex)
    {
        return {((hex >> 16) & 255) / 255.f, ((hex >> 8) & 255) / 255.f, (hex & 255) / 255.f};
    }
    bool operator==(Ink const &v) const
    {
        return r == v.r && g == v.g && b == v.b &&
               (surface == v.surface || (surface && v.surface && *surface == *v.surface));
    }
};
using Cells = std::unordered_map<Cell, Ink, CellHash>;
using Selection = std::unordered_set<Cell, CellHash>;
// History shares untouched 16-cubed regions between revisions.
class Volume
{
    std::unordered_map<int, std::shared_ptr<Cells>> chunks;
    static int chunk(Cell p)
    {
        return ((p.x + 128) / 16) + 16 * (p.y / 16) + 256 * ((p.z + 128) / 16);
    }

  public:
    const Ink *get(Cell p) const;
    bool put(Cell p, std::optional<Ink> value);
    template <class F> void each(F &&f) const
    {
        for (auto const &[_, block] : chunks)
            for (auto const &[p, ink] : *block)
                f(p, ink);
    }
};
std::string newID();
struct Layer
{
    std::string name{"Layer 1"}, id{newID()};
    bool visible{true};
    Volume cells;
};
struct Scene
{
    std::string title{"Untitled"};
    std::vector<Layer> layers{Layer{}};
    std::vector<Ink> palette;
    int active{};
    std::optional<std::array<int64_t, 3>> origin;
    Scene();
    Cells visible(int ceiling = 255) const;
    int owner(Cell p) const;
};
enum class Tool
{
    Add,
    Paint,
    Erase,
    Pick,
    Select,
    Line,
    Rectangle,
    Box,
    Extrude,
    Fill
};
struct Pick
{
    std::optional<Cell> hit, adjacent;
    Cell normal{0, 1, 0};
};
struct ProjectState
{
    Scene scene;
    Selection selected;
    uint64_t id{};
};
class Editor
{
    std::deque<ProjectState> past, future;
    std::optional<ProjectState> before;
    bool changed{};
    uint64_t serial{}, saved{};

  public:
    ProjectState state;
    Tool tool{Tool::Add};
    Ink ink{Ink::rgb(0xe96555)};
    int brushSize{1}, depth{1}, ceiling{255};
    bool mirrorX{}, mirrorZ{};
    Scene &scene()
    {
        return state.scene;
    }
    bool dirty() const
    {
        return changed || state.id != saved;
    }
    bool canUndo() const
    {
        return changed || !past.empty();
    }
    bool canRedo() const
    {
        return !changed && !future.empty();
    }
    void markSaved()
    {
        saved = state.id;
    }
    void reset(Scene s);
    void begin();
    void end();
    void cancel();
    void undo();
    void redo();
    void touch()
    {
        changed = true;
    }
    bool write(Cell p, std::optional<Ink> value);
    bool eligible(Cell p) const;
    void brush(Pick const &);
    void fill(Cell);
    Cells shape(Cell a, Cell b, Cell normal) const;
    Cells extrusion(Cell seed, Cell normal, int distance) const;
    void apply(Cells const &);
    void selectAll();
    void eraseSelection();
    bool transform(Cell delta, int axis = -1, bool copy = false, bool checkOnly = false);
    void duplicate();
};
Scene readProject(std::filesystem::path const &);
void saveProject(Scene const &, std::filesystem::path const &);
Scene readVox(std::filesystem::path const &);
void saveVox(Scene const &, std::filesystem::path const &);
void saveObj(Scene const &, std::filesystem::path const &);
void atomicWrite(std::filesystem::path const &, std::string_view);
std::string readFile(std::filesystem::path const &, size_t limit);
std::string fragmentBytes(Cells const &);
Cells parseFragment(std::string_view);
} // namespace forma
