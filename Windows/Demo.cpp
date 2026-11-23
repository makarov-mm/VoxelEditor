#include "Scene.h"
namespace forma
{
// Northern Lighthouse, from the original macOS DemoScene.
Scene lighthouse()
{
    Scene scene;
    scene.title = "Northern Lighthouse";
    scene.layers.clear();
    for (auto name : {"Sea", "Island", "Vegetation", "Keeper’s Cottage", "Lighthouse"})
    {
        Layer l;
        l.name = name;
        scene.layers.push_back(std::move(l));
    }
    auto put = [&](int l, int x, int y, int z, unsigned rgb) {
        scene.layers[l].cells.put({x, y, z}, Ink::rgb(rgb));
    };
    auto fill = [&](int l, int x0, int x1, int y0, int y1, int z0, int z1, unsigned c) {
        for (int x = x0; x <= x1; x++)
            for (int y = y0; y <= y1; y++)
                for (int z = z0; z <= z1; z++)
                    put(l, x, y, z, c);
    };
    constexpr unsigned water = 0x82BCBA, surf = 0xD4EBDA, deep = 0x68A8AB, slate = 0x697B82,
                       stone = 0xAD9F8B, ochre = 0xD8BB84, wood = 0x926D50, limestone = 0xCCBDA1,
                       iron = 0x314552, ivory = 0xF4E6CA, tile = 0x538F8D, brick = 0xBF5045,
                       red = 0xE96555, leaf = 0x6E916F;
    for (int x = -14; x <= 14; x++)
        for (int z = -11; z <= 11; z++)
            if (abs(x) + abs(z) <= 21)
                put(0, x, 0, z, water);
    for (auto [x, z, n] : std::array<Cell, 8>{{{-11, 0, 3},
                                               {-9, 5, 3},
                                               {-5, 8, 4},
                                               {1, 8, 3},
                                               {8, 6, 2},
                                               {10, -4, 2},
                                               {-10, -6, 2},
                                               {1, -9, 3}}})
        fill(0, x, x + n - 1, 0, 0, z, z, surf);
    for (auto [x, z, n] : std::array<Cell, 4>{{{-11, 7, 2}, {4, 10, 3}, {11, 4, 2}, {7, -9, 2}}})
        fill(0, x, x + n - 1, 0, 0, z, z, deep);
    auto height = [](int x, int z) {
        double u = (x + .4) / 11.1, v = (z + .2) / 8.2, a = atan2(v, u),
               r = hypot(u, v) + .060 * cos(3 * a + .8) + .035 * sin(5 * a);
        return r > 1 ? 0 : r > .94 ? 2 : r > .85 ? 3 : r > .75 ? 4 : 5;
    };
    for (int x = -12; x <= 12; x++)
        for (int z = -10; z <= 10; z++)
        {
            int h = height(x, z);
            for (int y = 1; y <= h; y++)
                put(1, x, y, z,
                    y == h                                     ? (h >= 4   ? 0xA4AE76
                                                                  : h == 3 ? limestone
                                                                           : stone)
                    : y == 1                                   ? slate
                    : ((x >= 5 && z > 1) || (x < -6 && z < 0)) ? stone
                                                               : limestone);
        }
    for (auto [x, z] : std::array<std::pair<int, int>, 21>{
             {{-5, 6}, {-4, 6}, {-3, 6}, {-2, 6}, {-2, 5}, {-1, 5}, {0, 5},
              {0, 4},  {1, 4},  {2, 4},  {2, 3},  {3, 3},  {4, 3},  {5, 3},
              {5, 4},  {6, 4},  {7, 4},  {8, 4},  {8, 3},  {9, 3},  {10, 3}}})
        if (int y = height(x, z))
            put(1, x, y, z, ochre);
    fill(1, 10, 13, 2, 2, 2, 4, wood);
    for (int x : {10, 13})
        for (int z : {2, 4})
        {
            put(1, x, 1, z, wood);
            put(1, x, 3, z, ochre);
        }
    fill(1, -11, -10, 1, 1, 2, 3, slate);
    put(1, -10, 2, 2, stone);
    fill(1, 2, 4, 1, 1, 8, 8, slate);
    put(1, 3, 2, 8, stone);
    for (auto [x, z, h] : std::array<Cell, 2>{{{-9, 4, 8}, {8, -4, 6}}})
    {
        int base = height(x, z);
        fill(2, x, x, base + 1, base + h, z, z, wood);
        for (int y = 2; y <= h; y++)
        {
            int tip = h - y, r = tip == 0 ? 0 : tip <= 4 ? 1 : 2;
            for (int a = -r; a <= r; a++)
                for (int b = -r; b <= r; b++)
                    if (abs(a) + abs(b) <= r + (tip == 2 || tip == 5))
                        put(2, x + a, base + y, z + b, tip >= 4 ? 0x4F7467 : leaf);
        }
    }
    for (auto [x, z] : std::array<std::pair<int, int>, 7>{
             {{8, -3}, {8, -2}, {7, -3}, {-8, 4}, {-7, 5}, {0, 6}, {1, 6}}})
        if (height(x, z) >= 3)
            put(2, x, height(x, z) + 1, z, leaf);
    for (auto [x, z] :
         std::array<std::pair<int, int>, 6>{{{-8, 0}, {-7, 0}, {-2, -5}, {-1, -5}, {6, 3}, {6, 2}}})
        put(2, x, height(x, z), z, 0xC1C797);
    fill(3, -7, -2, 4, 5, 0, 5, stone);
    fill(3, -7, -2, 6, 8, 0, 5, ivory);
    fill(3, -6, -6, 6, 7, 5, 5, wood);
    put(3, -3, 7, 5, iron);
    put(3, -2, 7, 1, tile);
    put(3, -2, 7, 2, iron);
    put(3, -2, 7, 3, tile);
    for (int x = -8; x <= -1; x++)
    {
        int rise = std::min(x + 8, -1 - x);
        fill(3, x, x, 9, 8 + rise, 0, 5, ivory);
        fill(3, x, x, 9 + rise, 9 + rise, -1, 6, tile);
    }
    fill(3, -4, -4, 11, 13, 1, 1, brick);
    put(3, -4, 14, 1, stone);
    auto disk = [&](int y, double r, unsigned c) {
        int n = int(ceil(r));
        for (int x = -n; x <= n; x++)
            for (int z = -n; z <= n; z++)
                if (x * x + z * z <= r * r)
                    put(4, 3 + x, y, -3 + z, c);
    };
    disk(5, 4.6, slate);
    disk(6, 4.5, limestone);
    for (int y = 7; y <= 21; y++)
        disk(y, 4.45 - (y - 7) * .115, (y >= 11 && y <= 13) || (y >= 17 && y <= 19) ? red : ivory);
    for (int y = 7; y <= 9; y++)
        for (int x = 0; x <= 1; x++)
        {
            auto r = 4.45 - (y - 7) * .115;
            put(4, 3 + x, y, -3 + int(sqrt(r * r - x * x)), wood);
        }
    fill(4, 3, 4, 6, 6, 2, 2, limestone);
    put(4, 6, 14, -3, iron);
    put(4, 6, 15, -3, iron);
    put(4, 3, 20, -1, iron);
    disk(22, 4.2, iron);
    for (int y = 23; y <= 25; y++)
        for (int x = -2; x <= 2; x++)
            for (int z = -2; z <= 2; z++)
                put(4, 3 + x, y, z - 3,
                    abs(x) == 2 && abs(z) == 2                                ? iron
                    : y == 25 && ((x == 2 && z == -1) || (z == 2 && x == -1)) ? ivory
                    : x == 2 || z == -2                                       ? 0xF5BD62
                                                                              : 0xFFE4A2);
    for (auto [x, z] : std::array<std::pair<int, int>, 8>{
             {{-3, -2}, {-2, -3}, {2, -3}, {3, -2}, {3, 2}, {2, 3}, {-2, 3}, {-3, 2}}})
        put(4, 3 + x, 23, z - 3, slate);
    disk(26, 3.8, brick);
    disk(27, 3, red);
    disk(28, 2, red);
    disk(29, 1, brick);
    put(4, 3, 30, -3, iron);
    scene.active = 4;
    return scene;
}
} // namespace forma
