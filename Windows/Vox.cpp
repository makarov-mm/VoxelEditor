#include "Scene.h"
#include <charconv>
#include <cstring>
#include <functional>
#include <format>
#include <limits>
#include <set>
#include <sstream>
#include <stdexcept>
namespace forma
{
namespace
{
using Dict = std::map<std::string, std::string>;
using Point = std::array<int64_t, 3>;
void check(bool ok, const char *why = "Invalid VOX file.")
{
    if (!ok)
        throw std::runtime_error(why);
}
struct Reader
{
    std::string_view data;
    std::string_view take(size_t n)
    {
        check(n <= data.size());
        auto out = data.substr(0, n);
        data.remove_prefix(n);
        return out;
    }
    int word()
    {
        int32_t v;
        memcpy(&v, take(4).data(), 4);
        return v;
    }
    int count(size_t limit)
    {
        int n = word();
        check(n >= 0 && size_t(n) <= limit);
        return n;
    }
    std::string text()
    {
        return std::string(take(count(data.size())));
    }
    Dict dict()
    {
        auto n = count(data.size() / 8);
        Dict d;
        for (int i = 0; i < n; i++)
        {
            auto k = text();
            d[k] = text();
        }
        return d;
    }
};
void put(std::string &s, int32_t v)
{
    s.append(reinterpret_cast<const char *>(&v), 4);
}
void dict(std::string &s, Dict const &d)
{
    put(s, int(d.size()));
    for (auto &[k, v] : d)
    {
        put(s, int(k.size()));
        s += k;
        put(s, int(v.size()));
        s += v;
    }
}
void chunk(std::string &stream, std::string_view tag, std::string_view payload,
           std::string_view children = {})
{
    stream += tag;
    put(stream, int(payload.size()));
    put(stream, int(children.size()));
    stream += payload;
    stream += children;
}
std::string get(Dict const &d, std::string key, std::string fallback = {})
{
    auto i = d.find(key);
    return i == d.end() ? fallback : i->second;
}
int number(std::string const &s, int fallback)
{
    int v;
    auto [p, e] = std::from_chars(s.data(), s.data() + s.size(), v);
    return e == std::errc{} && p == s.data() + s.size() ? v : fallback;
}
struct Transform
{
    std::array<int, 3> rows{1, 2, 3};
    Point shift{};
    Point point(Point p) const
    {
        Point r = shift;
        for (int i = 0; i < 3; i++)
            r[i] += (rows[i] < 0 ? -1 : 1) * p[std::abs(rows[i]) - 1];
        return r;
    }
    Transform combine(Transform const &other) const
    {
        Transform r;
        r.shift = point(other.shift);
        for (int i = 0; i < 3; i++)
            r.rows[i] = (rows[i] < 0 ? -1 : 1) * other.rows[std::abs(rows[i]) - 1];
        return r;
    }
    static Transform read(Dict const &d)
    {
        Transform t;
        if (d.contains("_r"))
        {
            int r = number(d.at("_r"), -1), a = r & 3, b = (r >> 2) & 3;
            check(r >= 0 && r <= 127 && a < 3 && b < 3 && a != b);
            t.rows = {a + 1, b + 1, 4 - a - b};
            for (int i = 0; i < 3; i++)
                if (r & (16 << i))
                    t.rows[i] *= -1;
        }
        if (d.contains("_t"))
        {
            std::istringstream in(d.at("_t"));
            for (auto &v : t.shift)
            {
                check(bool(in >> v) && v >= INT32_MIN && v <= INT32_MAX);
            }
            std::string extra;
            check(!(in >> extra));
        }
        return t;
    }
};
struct Node
{
    std::string type;
    Dict attrs;
    std::vector<int> children;
    int layer{-1}, model{};
    Transform transform;
};
struct Model
{
    Cell size;
    std::string_view bytes;
};
std::vector<Ink> defaultInks()
{
    std::vector<Ink> c;
    for (int r : {255, 204, 153, 102, 51, 0})
        for (int g : {255, 204, 153, 102, 51, 0})
            for (int b : {255, 204, 153, 102, 51, 0})
                if (r + g + b)
                    c.push_back(Ink::rgb(r << 16 | g << 8 | b));
    for (int i = 0; i < 4; i++)
        for (int v : {238, 221, 187, 170, 136, 119, 85, 68, 34, 17})
            c.push_back(Ink::rgb(((i == 0 || i == 3) ? v << 16 : 0) | ((i == 1 || i == 3) ? v << 8 : 0) |
                                 ((i == 2 || i == 3) ? v : 0)));
    return c;
}
} // namespace
Scene readVox(std::filesystem::path const &path)
{
    std::string file = readFile(path, 128u << 20);
    Reader top{file};
    check(top.take(4) == "VOX ");
    int version = top.word();
    check(version == 150 || version == 200, "Unsupported VOX version.");
    check(top.take(4) == "MAIN" && top.word() == 0);
    Reader chunks{top.take(top.count(top.data.size()))};
    check(top.data.empty());
    std::vector<Model> models;
    std::optional<Cell> size;
    std::map<int, Node> nodes;
    std::map<int, Dict> layers, materials;
    auto inks = defaultInks();
    std::vector<int> order;
    while (!chunks.data.empty())
    {
        std::string tag(chunks.take(4));
        int bytes = chunks.count(chunks.data.size()), kids = chunks.count(chunks.data.size());
        Reader c{chunks.take(bytes)};
        chunks.take(kids);
        if (tag == "SIZE")
        {
            check(!size);
            Cell s{c.word(), c.word(), c.word()};
            check(s.x > 0 && s.y > 0 && s.z > 0 && s.x <= 256 && s.y <= 256 && s.z <= 256);
            size = s;
        }
        else if (tag == "XYZI")
        {
            check(size.has_value() && models.size() < 65536);
            int n = c.count(std::min(2000000, size->x * size->y * size->z));
            models.push_back({*size, c.take(size_t(n) * 4)});
            size.reset();
        }
        else if (tag == "RGBA")
        {
            auto v = (const unsigned char *)c.take(1024).data();
            for (int i = 0; i < 255; i++)
            {
                auto b = v + i * 4;
                inks[i] = {b[0] / 255.f, b[1] / 255.f, b[2] / 255.f};
                if (b[3] != 255)
                    inks[i].surface = std::make_shared<Material>(b[3], Dict{});
            }
        }
        else if (tag == "IMAP")
        {
            auto map = c.take(256);
            std::set<unsigned char> seen(map.begin(), map.end());
            if (seen.size() == 256)
            {
                order.clear();
                for (unsigned char k : map)
                    if (k)
                        order.push_back(k);
            }
        }
        else if (tag == "MATL" || tag == "LAYR")
        {
            int id = c.word();
            (tag == "MATL" ? materials : layers)[id] = c.dict();
            if (tag == "LAYR")
                c.word();
        }
        else if (tag == "nTRN" || tag == "nGRP" || tag == "nSHP")
        {
            int id = c.word();
            check(id >= 0 && !nodes.contains(id) && nodes.size() < 262144);
            Node node;
            node.type = tag;
            node.attrs = c.dict();
            if (tag == "nGRP")
            {
                int n = c.count(c.data.size() / 4);
                for (int i = 0; i < n; i++)
                    node.children.push_back(c.word());
            }
            else
            {
                if (tag == "nTRN")
                {
                    node.children.push_back(c.word());
                    c.word();
                    node.layer = c.word();
                }
                int n = c.count(c.data.size() / 4);
                check(n > 0);
                int earliest = INT_MAX;
                for (int i = 0; i < n; i++)
                {
                    int model = tag == "nSHP" ? c.word() : 0;
                    auto d = c.dict();
                    int f = number(get(d, "_f"), i);
                    if (i == 0 || f < earliest)
                    {
                        earliest = f;
                        node.model = model;
                        if (tag == "nTRN")
                            node.transform = Transform::read(d);
                    }
                }
            }
            nodes.emplace(id, std::move(node));
        }
        else
            continue;
        check(c.data.empty());
    }
    check(!size && !models.empty());
    for (auto &[id, d] : materials)
        if (id >= 1 && id <= 255 && !d.empty())
        {
            auto &i = inks[id - 1];
            i.surface = std::make_shared<Material>(i.surface ? i.surface->alpha : 255, d);
        }
    Scene scene;
    scene.layers.clear();
    scene.palette.clear();
    auto title = path.stem().u8string();
    scene.title.assign(title.begin(), title.end());
    if (order.empty())
        for (int i = 1; i <= 255; i++)
            order.push_back(i);
    for (int id : order)
        if (std::ranges::find(scene.palette, inks[id - 1]) == scene.palette.end())
            scene.palette.push_back(inks[id - 1]);
    struct Instance
    {
        int model;
        Transform t;
    };
    std::vector<Instance> instances;
    size_t count = 0;
    auto instance = [&](int m, Transform t, std::string name, bool hidden) {
        check(m >= 0 && size_t(m) < models.size() && instances.size() < 128,
              "Invalid model reference or too many layers.");
        count += models[m].bytes.size() / 4;
        check(count <= 2000000, "VOX exceeds two million voxels.");
        Layer l;
        l.name = name.empty() ? std::format("Model {}", m + 1) : name;
        l.visible = !hidden;
        scene.layers.push_back(std::move(l));
        instances.push_back({m, t});
    };
    if (nodes.empty())
    {
        for (int i = 0; i < int(models.size()); i++)
            instance(i, {}, {}, i != 0);
    }
    else
    {
        std::set<int> children, seen, pathSet;
        int visits = 0;
        for (auto &[_, n] : nodes)
            children.insert(n.children.begin(), n.children.end());
        std::function<void(int, Transform, std::string, bool)> visit =
            [&](int id, Transform t, std::string name, bool hidden) {
                check(nodes.contains(id) && pathSet.insert(id).second && pathSet.size() <= 256 &&
                          ++visits <= 500000,
                      "Invalid VOX scene graph.");
                seen.insert(id);
                auto &n = nodes.at(id);
                if (n.type == "nTRN" && layers.contains(n.layer))
                {
                    auto &d = layers.at(n.layer);
                    name = get(d, "_name", name);
                    hidden |= get(d, "_hidden") == "1";
                }
                name = get(n.attrs, "_name", name);
                hidden |= get(n.attrs, "_hidden") == "1";
                if (n.type == "nSHP")
                    instance(n.model, t, name, hidden);
                else
                    for (int c : n.children)
                        visit(c, t.combine(n.transform), name, hidden);
                pathSet.erase(id);
            };
        for (auto &[id, n] : nodes)
            if (!children.contains(id))
                visit(id, {}, {}, false);
        check(seen.size() == nodes.size() && !instances.empty());
    }
    auto forCells = [&](auto fn) {
        for (size_t k = 0; k < instances.size(); k++)
        {
            auto &[m, t] = instances[k];
            auto &[s, v] = models[m];
            for (size_t j = 0; j < v.size(); j += 4)
            {
                auto b = (const unsigned char *)v.data() + j;
                check(b[0] < s.x && b[1] < s.y && b[2] < s.z && b[3] != 0);
                auto p = t.point({b[0] - s.x / 2, b[1] - s.y / 2, b[2] - s.z / 2});
                for (int a = 0; a < 3; a++)
                    if (t.rows[a] < 0)
                        p[a]--;
                fn(k, Point{p[0], p[2], -1 - p[1]}, inks[b[3] - 1]);
            }
        }
    };
    Point lo{INT64_MAX, INT64_MAX, INT64_MAX}, hi{INT64_MIN, INT64_MIN, INT64_MIN}, origin{};
    forCells([&](size_t, Point p, auto &) {
        for (int a = 0; a < 3; a++)
        {
            lo[a] = std::min(lo[a], p[a]);
            hi[a] = std::max(hi[a], p[a]);
        }
    });
    if (count)
        for (int a = 0; a < 3; a++)
        {
            int floor = a == 1 ? 0 : -128;
            check(hi[a] - lo[a] < 256, "VOX exceeds the 256-cell grid.");
            origin[a] = std::min<int64_t>(0, lo[a] - floor) + std::max<int64_t>(0, hi[a] - floor - 255);
            check(std::abs(origin[a]) <= 2147483904ll);
        }
    if (origin != Point{})
        scene.origin = origin;
    forCells([&](size_t k, Point p, Ink const &i) {
        scene.layers[k].cells.put({int(p[0] - origin[0]), int(p[1] - origin[1]), int(p[2] - origin[2])},
                                  i);
    });
    return scene;
}
void saveVox(Scene const &scene, std::filesystem::path const &path)
{
    std::vector<Ink> used, colors;
    auto add = [](auto &v, Ink const &c) {
        if (std::ranges::find(v, c) == v.end())
            v.push_back(c);
    };
    size_t total = 0;
    for (auto &l : scene.layers)
        l.cells.each([&](Cell, Ink const &i) {
            check(++total <= 2000000, "VOX exceeds two million voxels.");
            add(used, i);
            check(used.size() <= 255, "VOX supports up to 255 occupied colors and materials.");
        });
    auto all = used;
    for (auto &i : scene.palette)
        add(all, i);
    for (auto &i : scene.palette)
        if (all.size() <= 255 || std::ranges::find(used, i) != used.end())
            add(colors, i);
    for (auto &i : used)
        add(colors, i);
    for (auto &i : scene.palette)
        if (colors.size() < 255)
            add(colors, i);
    std::string chunks, group;
    std::vector<Point> pivots;
    auto origin = scene.origin.value_or(Point{});
    auto vox = [](Cell p) { return Cell{p.x, -p.z - 1, p.y}; };
    for (auto &l : scene.layers)
    {
        Cell lo{}, hi{};
        int n = 0;
        l.cells.each([&](Cell p, auto &) {
            auto v = vox(p);
            if (n++ == 0)
                lo = hi = v;
            else
            {
                lo = lower(lo, v);
                hi = upper(hi, v);
            }
        });
        auto sz = hi - lo + Cell{1, 1, 1};
        std::string dims;
        for (auto x : {sz.x, sz.y, sz.z})
            put(dims, x);
        chunk(chunks, "SIZE", dims);
        std::string data;
        put(data, n);
        l.cells.each([&](Cell p, Ink const &i) {
            auto d = vox(p) - lo;
            data += char(d.x);
            data += char(d.y);
            data += char(d.z);
            data += char(1 + (std::ranges::find(colors, i) - colors.begin()));
        });
        chunk(chunks, "XYZI", data);
        pivots.push_back(
            {origin[0] + lo.x + sz.x / 2, -origin[2] + lo.y + sz.y / 2, origin[1] + lo.z + sz.z / 2});
    }
    auto transform = [&](int id, int child, int layer, Dict attrs, Point p) {
        for (auto x : p)
            check(x >= INT32_MIN && x <= INT32_MAX, "World pivot exceeds VOX range.");
        std::string b;
        put(b, id);
        dict(b, attrs);
        put(b, child);
        put(b, -1);
        put(b, layer);
        put(b, 1);
        dict(b, {{"_t", std::format("{} {} {}", p[0], p[1], p[2])}});
        chunk(chunks, "nTRN", b);
    };
    transform(0, 1, -1, {}, {});
    put(group, 1);
    dict(group, {});
    put(group, int(scene.layers.size()));
    for (int i = 0; i < int(scene.layers.size()); i++)
        put(group, 2 + i * 2);
    chunk(chunks, "nGRP", group);
    for (int i = 0; i < int(scene.layers.size()); i++)
    {
        auto &l = scene.layers[i];
        int id = 2 + i * 2;
        Dict names{{"_name", l.name}};
        transform(id, id + 1, i, names, pivots[i]);
        std::string sh;
        put(sh, id + 1);
        dict(sh, {});
        put(sh, 1);
        put(sh, i);
        dict(sh, {});
        chunk(chunks, "nSHP", sh);
        if (!l.visible)
            names["_hidden"] = "1";
        std::string la;
        put(la, i);
        dict(la, names);
        put(la, -1);
        chunk(chunks, "LAYR", la);
    }
    std::string rgba;
    for (auto &i : colors)
    {
        for (float f : {i.r, i.g, i.b})
            rgba += char(std::lround(255 * f));
        rgba += char(i.surface ? i.surface->alpha : 255);
    }
    rgba.resize(1024, 0);
    chunk(chunks, "RGBA", rgba);
    for (int n = 0; n < int(colors.size()); n++)
        if (auto m = colors[n].surface; m && !m->properties.empty())
        {
            std::string mat;
            put(mat, n + 1);
            dict(mat, m->properties);
            chunk(chunks, "MATL", mat);
        }
    std::string out = "VOX ";
    put(out, 150);
    chunk(out, "MAIN", {}, chunks);
    atomicWrite(path, out);
}
} // namespace forma
