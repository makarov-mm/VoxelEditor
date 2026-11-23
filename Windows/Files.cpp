#include "Scene.h"
#include <windows.h>
#include <nlohmann/json.hpp>
#include <bit>
#include <fstream>
#include <format>
#include <sstream>
#include <set>
#include <stdexcept>
namespace forma
{
using Json = nlohmann::json;
static void require(bool ok, const char *msg = "Invalid Forma project.")
{
    if (!ok)
        throw std::runtime_error(msg);
}
std::string readFile(std::filesystem::path const &p, size_t limit)
{
    std::ifstream f(p, std::ios::binary | std::ios::ate);
    if (!f)
        throw std::runtime_error("Cannot open file.");
    auto len = f.tellg();
    require(len >= 0 && uint64_t(len) <= limit, "File exceeds the size limit.");
    std::string bytes(size_t(len), '\0');
    f.seekg(0);
    if (!f.read(bytes.data(), len))
        throw std::runtime_error("File read failed.");
    return bytes;
}
void atomicWrite(std::filesystem::path const &p, std::string_view bytes)
{
    auto temp = p.parent_path() / std::filesystem::path(newID() + ".tmp");
    try
    {
        std::ofstream f(temp, std::ios::binary);
        f.exceptions(std::ios::failbit | std::ios::badbit);
        f.write(bytes.data(), bytes.size());
        f.close();
        if (!MoveFileExW(temp.c_str(), p.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            throw std::runtime_error("Cannot replace the destination file.");
    }
    catch (...)
    {
        std::error_code ec;
        std::filesystem::remove(temp, ec);
        throw;
    }
}
static Json colorJson(Ink const &i)
{
    Json j = {{"r", i.r}, {"g", i.g}, {"b", i.b}};
    if (i.surface)
        j["surface"] = {{"alpha", i.surface->alpha}, {"properties", i.surface->properties}};
    return j;
}
static Ink readColor(Json const &j)
{
    Ink i{j.at("r").get<float>(), j.at("g").get<float>(), j.at("b").get<float>()};
    for (float f : {i.r, i.g, i.b})
        require(f >= 0 && f <= 1);
    if (j.contains("surface") && !j["surface"].is_null())
    {
        auto &s = j["surface"];
        auto a = s.at("alpha").get<int>();
        require(a >= 0 && a <= 255);
        i.surface = std::make_shared<Material>(
            unsigned(a), s.at("properties").get<std::map<std::string, std::string>>());
    }
    return i;
}
static int coord(Json const &j, const char *key)
{
    auto &n = j.at(key);
    require(n.is_number_integer());
    auto v = n.get<int64_t>();
    require(v >= -128 && v <= 255);
    return int(v);
}
static std::string id(Json const &j)
{
    auto s = j.get<std::string>();
    require(s.size() == 36);
    for (size_t i = 0; i < s.size(); i++)
    {
        if (i == 8 || i == 13 || i == 18 || i == 23)
            require(s[i] == '-');
        else
        {
            require(std::isxdigit(static_cast<unsigned char>(s[i])) != 0);
            s[i] = char(std::toupper(static_cast<unsigned char>(s[i])));
        }
    }
    return s;
}
Scene readProject(std::filesystem::path const &p)
{
    auto j = Json::parse(readFile(p, 256u << 20));
    require(j.at("version") == 1, "Unsupported project version.");
    Scene s;
    s.layers.clear();
    s.palette.clear();
    s.title = j.at("title");
    require(!s.title.empty());
    auto &layers = j.at("layers");
    auto &colors = j.at("palette");
    require(layers.is_array() && !layers.empty() && layers.size() <= 128);
    require(colors.is_array() && !colors.empty() && colors.size() <= 256);
    for (auto &c : colors)
        s.palette.push_back(readColor(c));
    std::set<std::string> ids;
    auto active = id(j.at("activeLayerID"));
    s.active = -1;
    for (auto &lj : layers)
    {
        Layer l;
        l.id = id(lj.at("id"));
        require(ids.insert(l.id).second);
        l.name = lj.at("name");
        require(!l.name.empty());
        l.visible = lj.at("isVisible");
        if (l.id == active)
            s.active = int(s.layers.size());
        auto &vox = lj.at("voxels");
        require(vox.is_array() && vox.size() <= 16777216);
        for (auto &v : vox)
        {
            auto &c = v.at("cell");
            Cell q{coord(c, "x"), coord(c, "y"), coord(c, "z")};
            require(q.valid() && !l.cells.get(q));
            l.cells.put(q, readColor(v.at("ink")));
        }
        s.layers.push_back(std::move(l));
    }
    require(s.active >= 0);
    if (j.contains("voxOrigin") && !j["voxOrigin"].is_null())
    {
        auto &o = j["voxOrigin"];
        std::array<int64_t, 3> a{o.at("x"), o.at("y"), o.at("z")};
        for (auto v : a)
            require(v >= -2147483904ll && v <= 2147483904ll);
        s.origin = a;
    }
    return s;
}
void saveProject(Scene const &s, std::filesystem::path const &p)
{
    auto name = p.stem().u8string();
    Json j = {{"version", 1},
              {"title", std::string(name.begin(), name.end())},
              {"activeLayerID", s.layers.at(s.active).id}};
    j["palette"] = Json::array();
    for (auto &i : s.palette)
        j["palette"].push_back(colorJson(i));
    if (s.origin)
    {
        auto a = *s.origin;
        j["voxOrigin"] = {{"x", a[0]}, {"y", a[1]}, {"z", a[2]}};
    }
    j["layers"] = Json::array();
    for (auto &l : s.layers)
    {
        Json v = Json::array();
        l.cells.each([&](Cell p, Ink const &i) {
            v.push_back({{"cell", {{"x", p.x}, {"y", p.y}, {"z", p.z}}}, {"ink", colorJson(i)}});
        });
        j["layers"].push_back(
            {{"id", l.id}, {"name", l.name}, {"isVisible", l.visible}, {"voxels", std::move(v)}});
    }
    auto bytes = j.dump();
    require(bytes.size() <= (256u << 20), "Project exceeds 256 MB.");
    atomicWrite(p, bytes);
}
static void put32(std::string &s, uint32_t v)
{
    for (int i = 0; i < 4; i++)
        s.push_back(char(v >> (8 * i)));
}
std::string fragmentBytes(Cells const &cells)
{
    require(!cells.empty() && cells.size() <= 2'000'000, "Invalid selection size.");
    auto base = cells.begin()->first;
    for (auto &[p, _] : cells)
        base = lower(base, p);
    std::string out = "FVX1";
    out += char(base.x + 128);
    out += char(base.y);
    out += char(base.z + 128);
    put32(out, uint32_t(cells.size()));
    std::vector<Ink> inks;
    std::map<std::string, unsigned> indices;
    for (auto &[p, i] : cells)
    {
        auto [it, fresh] = indices.emplace(colorJson(i).dump(), unsigned(inks.size()));
        if (fresh)
            inks.push_back(i);
        auto d = p - base;
        out += char(d.x);
        out += char(d.y);
        out += char(d.z);
        put32(out, it->second);
    }
    put32(out, uint32_t(inks.size()));
    for (auto &i : inks)
    {
        for (auto c : {i.r, i.g, i.b})
            put32(out, std::bit_cast<uint32_t>(c));
        auto material = i.surface ? colorJson(i)["surface"].dump() : std::string{};
        put32(out, uint32_t(material.size()));
        out += material;
    }
    require(out.size() <= (128u << 20), "Clipboard fragment exceeds 128 MB.");
    return out;
}
Cells parseFragment(std::string_view data)
{
    size_t pos = 0;
    auto take = [&](size_t n) {
        require(n <= data.size() - pos, "Invalid voxel fragment.");
        auto v = data.substr(pos, n);
        pos += n;
        return v;
    };
    auto byte = [&]() { return (unsigned char)take(1)[0]; };
    auto word = [&]() {
        uint32_t n = 0;
        for (int i = 0; i < 4; i++)
            n |= uint32_t(byte()) << (8 * i);
        return n;
    };
    require(data.size() <= (128u << 20) && take(4) == "FVX1");
    Cell base{int(byte()) - 128, byte(), int(byte()) - 128};
    auto n = word();
    require(n > 0 && n <= 2'000'000);
    auto records = take(size_t(n) * 7);
    auto m = word();
    require(m > 0 && m <= n);
    std::vector<Ink> inks;
    for (uint32_t k = 0; k < m; k++)
    {
        Json j;
        for (auto channel : {"r", "g", "b"})
            j[channel] = std::bit_cast<float>(word());
        auto len = word();
        if (len)
            j["surface"] = Json::parse(take(len));
        inks.push_back(readColor(j));
    }
    // GlobalAlloc may round a clipboard block up to its allocation boundary.
    require(data.size() - pos < 32 &&
            data.substr(pos).find_first_not_of(char(0)) == std::string_view::npos);
    Cells out;
    for (uint32_t k = 0; k < n; k++)
    {
        auto q = (const unsigned char *)records.data() + 7 * k;
        Cell p = base + Cell{q[0], q[1], q[2]};
        uint32_t ix;
        memcpy(&ix, q + 3, 4);
        require(p.valid() && ix < inks.size() && out.emplace(p, inks[ix]).second);
    }
    return out;
}
void saveObj(Scene const &s, std::filesystem::path const &p)
{
    auto cells = s.visible();
    require(!cells.empty(), "The scene has no visible voxels.");
    auto m = p;
    m.replace_extension(".mtl");
    auto name = m.filename().u8string();
    std::ostringstream obj, mtl;
    obj << "# Forma\nmtllib " << std::string(name.begin(), name.end()) << "\n";
    unsigned vertices = 0;
    std::map<std::array<float, 3>, unsigned> mats;
    for (auto &[v, i] : cells)
        for (auto n : normals)
        {
            if (cells.contains(v + n))
                continue;
            auto [it, fresh] = mats.emplace(std::array{i.r, i.g, i.b}, unsigned(mats.size() + 1));
            if (fresh)
                mtl << "newmtl ink" << it->second << "\nKd " << i.r << " " << i.g << " " << i.b
                    << "\n\n";
            Cell u = n.x ? Cell{0, 1, 0} : n.y ? Cell{0, 0, 1} : Cell{1, 0, 0};
            Cell d{n.y * u.z - n.z * u.y, n.z * u.x - n.x * u.z, n.x * u.y - n.y * u.x};
            Cell a = v + upper(n, {}) - lower(d, {});
            for (auto corner : {a, a + u, a + u + d, a + d})
                obj << "v " << corner.x << " " << corner.y << " " << corner.z << "\n";
            obj << "usemtl ink" << it->second << "\nf " << vertices + 1 << " " << vertices + 2 << " "
                << vertices + 3 << " " << vertices + 4 << "\n";
            vertices += 4;
        }
    atomicWrite(m, mtl.str());
    atomicWrite(p, obj.str());
}
} // namespace forma
