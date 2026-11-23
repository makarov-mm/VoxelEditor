#pragma once
#include "Scene.h"
#include <d3d11.h>
#include <dxgi1_3.h>
#include <wrl/client.h>
#undef GetCurrentTime
#include <winrt/Microsoft.UI.Xaml.Controls.h>
namespace forma
{
struct Vec
{
    float x{}, y{}, z{};
    Vec operator+(Vec v) const
    {
        return {x + v.x, y + v.y, z + v.z};
    }
    Vec operator-(Vec v) const
    {
        return {x - v.x, y - v.y, z - v.z};
    }
    Vec operator*(float s) const
    {
        return {x * s, y * s, z * s};
    }
    float dot(Vec v) const
    {
        return x * v.x + y * v.y + z * v.z;
    }
};
struct Camera
{
    float yaw{.63f}, pitch{.48f}, span{36}, width{1}, height{1};
    Vec center{};
    Vec eye() const;
    Vec right() const;
    Vec up() const;
    float unit() const
    {
        return std::min(width, height) / span;
    }
    Vec plane(float x, float y) const;
    std::pair<float, float> screen(Cell p) const;
    std::optional<Cell> onPlane(float x, float y, Cell anchor, Cell normal) const;
    Pick pick(float x, float y, Cells const &, int planeY) const;
    void fit(Cells const &);
};
class Viewport
{
    template <class T> using Ptr = Microsoft::WRL::ComPtr<T>;
    struct Face
    {
        float x, y, z;
        uint32_t side;
        float r, g, b;
        uint32_t flags;
        float ao[4];
    };
    struct Batch
    {
        Ptr<ID3D11Buffer> buffer;
        UINT count;
    };
    winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel panel{nullptr};
    Ptr<ID3D11Device> device;
    Ptr<ID3D11DeviceContext> context;
    Ptr<IDXGISwapChain1> swap;
    Ptr<ID3D11RenderTargetView> target;
    Ptr<ID3D11DepthStencilView> depth;
    Ptr<ID3D11VertexShader> vs;
    Ptr<ID3D11PixelShader> ps;
    Ptr<ID3D11InputLayout> layout;
    Ptr<ID3D11Buffer> constants;
    Ptr<ID3D11RasterizerState> raster;
    std::vector<Batch> sceneBatches, overlayBatches;
    std::vector<std::vector<Face>> sceneData, overlayData;
    UINT width{}, height{};
    float sx{1}, sy{1};
    Ptr<ID3D11ShaderResourceView> shadowView;
    Ptr<ID3D11SamplerState> shadowSampler;
    std::vector<unsigned char> shadowPixels;
    void uploadShadow();
    void initDevice();
    void upload(std::vector<std::vector<Face>> const &, std::vector<Batch> &);
    Ptr<ID3D11DepthStencilView> depthTarget(UINT w, UINT h);
    void drawTo(ID3D11RenderTargetView *, ID3D11DepthStencilView *, UINT, UINT, bool);

  public:
    Camera camera;
    bool grid{true}, edges{}, dark{};
    int level{};
    void attach(winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel const &);
    void resize(float w, float h, float scaleX, float scaleY);
    void model(Cells const &, Selection const &);
    void overlay(Cells const &, bool invalid = false);
    void draw();
    void png(std::filesystem::path const &);
};
} // namespace forma
