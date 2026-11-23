#include "Viewport.h"
#include <d3dcompiler.h>
#include <microsoft.ui.xaml.media.dxinterop.h>
#include <wincodec.h>
#include <cfloat>
#include <format>
#include <stdexcept>
namespace forma
{
using winrt::check_hresult;
Vec Camera::eye() const
{
    return {sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch)};
}
Vec Camera::right() const
{
    return {cosf(yaw), 0, -sinf(yaw)};
}
Vec Camera::up() const
{
    return {-sinf(yaw) * sinf(pitch), cosf(pitch), -cosf(yaw) * sinf(pitch)};
}
Vec Camera::plane(float x, float y) const
{
    return center + right() * ((x - width / 2) / unit()) + up() * ((height / 2 - y) / unit());
}
std::pair<float, float> Camera::screen(Cell c) const
{
    Vec p{c.x + .5f, c.y + .5f, c.z + .5f};
    p = p - center;
    return {width / 2 + p.dot(right()) * unit(), height / 2 - p.dot(up()) * unit()};
}
std::optional<Cell> Camera::onPlane(float x, float y, Cell a, Cell n) const
{
    auto p = plane(x, y), dir = eye();
    Vec normal{float(n.x), float(n.y), float(n.z)}, anchor{a.x + .5f, a.y + .5f, a.z + .5f};
    auto denom = dir.dot(normal);
    if (fabsf(denom) < .0001f)
        return {};
    auto hit = p + dir * ((anchor - p).dot(normal) / denom);
    Cell c{int(floorf(hit.x)), int(floorf(hit.y)), int(floorf(hit.z))};
    return c.valid() ? std::optional(c) : std::nullopt;
}
Pick Camera::pick(float x, float y, Cells const &cells, int level) const
{
    auto v = plane(x, y), e = eye(), start = v + e * (1000.f - e.dot(v));
    float pos[]{start.x, start.y, start.z}, dir[]{-e.x, -e.y, -e.z};
    constexpr int low[]{-128, 0, -128};
    float entryDistance = 0, exitDistance = 2200;
    Cell normal{};
    for (int i = 0; i < 3; i++)
    {
        if (fabsf(dir[i]) < .000001f)
        {
            if (pos[i] < low[i] || pos[i] >= low[i] + 256)
                return {};
            continue;
        }
        float a = (low[i] - pos[i]) / dir[i], b = (low[i] + 256 - pos[i]) / dir[i];
        if (std::min(a, b) > entryDistance)
        {
            entryDistance = std::min(a, b);
            normal = normals[i * 2 + (dir[i] > 0)];
        }
        exitDistance = std::min(exitDistance, std::max(a, b));
    }
    if (entryDistance >= exitDistance)
        return {};
    int grid[3], step[3];
    float next[3], delta[3];
    for (int i = 0; i < 3; i++)
    {
        grid[i] =
            std::clamp(int(floorf(pos[i] + dir[i] * (entryDistance + .0003f))), low[i], low[i] + 255);
        step[i] = dir[i] > 0 ? 1 : -1;
        next[i] = fabsf(dir[i]) < .000001f ? FLT_MAX : (grid[i] + int(step[i] > 0) - pos[i]) / dir[i];
        delta[i] = fabsf(dir[i]) < .000001f ? FLT_MAX : fabsf(1 / dir[i]);
    }
    for (int it = 0; it < 772; it++)
    {
        Cell c{grid[0], grid[1], grid[2]};
        if (cells.contains(c))
            return {c, c + normal, normal};
        int a = next[0] < next[1] ? (next[0] < next[2] ? 0 : 2) : (next[1] < next[2] ? 1 : 2);
        if (next[a] >= exitDistance - .0001f)
            break;
        grid[a] += step[a];
        next[a] += delta[a];
        normal = normals[a * 2 + (step[a] > 0)];
    }
    if (dir[1] < -.000001f)
    {
        float t = (level - pos[1]) / dir[1];
        Cell p{int(floorf(pos[0] + t * dir[0])), level, int(floorf(pos[2] + t * dir[2]))};
        if (p.valid())
            return {{}, p, {0, 1, 0}};
    }
    return {};
}
void Camera::fit(Cells const &cells)
{
    if (cells.empty())
    {
        center = {0, 0, 0};
        span = 32;
        return;
    }
    auto a = cells.begin()->first, b = a;
    for (auto &[p, _] : cells)
    {
        a = lower(a, p);
        b = upper(b, p);
    }
    center = {(a.x + b.x + 1) * .5f, (a.y + b.y + 1) * .5f, (a.z + b.z + 1) * .5f};
    float x = 0, y = 0;
    for (auto &[p, _] : cells)
    {
        Vec v{p.x + .5f, p.y + .5f, p.z + .5f};
        v = v - center;
        x = std::max(x, fabsf(v.dot(right())));
        y = std::max(y, fabsf(v.dot(up())));
    }
    span = std::max(8.f, 2.65f * std::max((x + 1) * std::min(width, height) / width,
                                          (y + 1) * std::min(width, height) / height));
}
namespace
{
const char *shader = R"(
cbuffer Camera : register(b0) { float4 right; float4 up; float4 eye; float4 center; float4 theme; };
Texture2D shadowTex:register(t0); SamplerState linearFilter:register(s0); struct Face {float3 base:POSITION;uint side:SIDE;float3 color:COLOR;uint flags:FLAGS;float4 ao:OCCLUSION;};
struct P {float4 pos:SV_Position;float3 color:COLOR;float2 uv:TEXCOORD0;nointerpolation uint flags:FLAGS;float ao:OCCLUSION;};
P vert(Face f,uint vid:SV_VertexID){
 uint corners[6]={0,1,2,0,2,3};uint c=corners[vid];float2 uv=float2(c==1||c==2,c>=2);
 float3 p=f.base;float shade=1;
 if(f.side==6){p+=float3(uv.x*256,0,uv.y*256);}
 else if(f.side<2){p+=float3(f.side==0,uv.y,uv.x);shade=f.side==0?.79:.87;}
 else if(f.side<4){p+=float3(uv.x,f.side==2,uv.y);shade=f.side==2?1.04:.65;}
 else {p+=float3(uv.x,uv.y,f.side==4);shade=f.side==4?.96:.83;}
 P o;float3 d=p-center.xyz;
 o.pos=float4(dot(d,right.xyz)*right.w,dot(d,up.xyz)*up.w,.5-dot(d,eye.xyz)/2048,1);
 if(f.side==6)o.pos.z=.99999; if((f.flags&2)!=0)o.pos.z-=.000008;
 o.color=f.color*shade;o.uv=f.side==6?p.xz:uv;o.flags=f.flags;o.ao=f.ao[c];return o;
}
float4 pixel(P p):SV_Target {
 float2 dd=max(fwidth(p.uv),float2(.0001,.0001));
 float2 d=abs(frac(p.uv+.5)-.5)/dd;float edgeCoverage=saturate(1-min(d.x,d.y));
 if((p.flags&4)!=0){float strength=theme.x*edgeCoverage*saturate(1/max(dd.x,dd.y)-.4);
    float shadow=shadowTex.Sample(linearFilter,(p.uv+192)/512).r;float3 paper=theme.y>.5?float3(.954,.951,.925):float3(.111,.137,.128);return float4(lerp(paper*(1-.16*shadow),theme.zzz,strength*.19),1);}
 float3 col=p.color*p.ao;
 if((p.flags&1)!=0)col=lerp(col,float3(.15,.62,.76),.42);
 if((p.flags&2)!=0)col=lerp(col,p.color,.5);
 if(theme.w>0 || (p.flags&3)!=0)col=lerp(col,col*.48,edgeCoverage*.65);
 return float4(col,1);
})";
}
void Viewport::initDevice()
{
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0,
                                   D3D11_SDK_VERSION, &device, nullptr, &context);
    if (FAILED(hr))
        check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, nullptr, 0,
                                        D3D11_SDK_VERSION, &device, nullptr, &context));
    Ptr<IDXGIDevice> dx;
    check_hresult(device.As(&dx));
    Ptr<IDXGIAdapter> adapter;
    check_hresult(dx->GetAdapter(&adapter));
    Ptr<IDXGIFactory2> factory;
    check_hresult(adapter->GetParent(IID_PPV_ARGS(&factory)));
    DXGI_SWAP_CHAIN_DESC1 sc{};
    sc.Width = sc.Height = 1;
    sc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sc.SampleDesc.Count = 1;
    sc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sc.BufferCount = 2;
    sc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    check_hresult(factory->CreateSwapChainForComposition(device.Get(), &sc, nullptr, &swap));
    check_hresult(panel.as<ISwapChainPanelNative>()->SetSwapChain(swap.Get()));
    auto compile = [&](const char *entry, const char *profile) {
        Ptr<ID3DBlob> code, err;
        auto hr = D3DCompile(shader, strlen(shader), "Forma", nullptr, nullptr, entry, profile,
                             D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &err);
        if (FAILED(hr))
            throw std::runtime_error(err ? static_cast<const char *>(err->GetBufferPointer())
                                         : "Shader compilation failed.");
        return code;
    };
    auto v = compile("vert", "vs_4_0"), p = compile("pixel", "ps_4_0");
    check_hresult(device->CreateVertexShader(v->GetBufferPointer(), v->GetBufferSize(), nullptr, &vs));
    check_hresult(device->CreatePixelShader(p->GetBufferPointer(), p->GetBufferSize(), nullptr, &ps));
    D3D11_INPUT_ELEMENT_DESC items[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"SIDE", 0, DXGI_FORMAT_R32_UINT, 0, 12, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"FLAGS", 0, DXGI_FORMAT_R32_UINT, 0, 28, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"OCCLUSION", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 32, D3D11_INPUT_PER_INSTANCE_DATA, 1}};
    check_hresult(
        device->CreateInputLayout(items, 5, v->GetBufferPointer(), v->GetBufferSize(), &layout));
    D3D11_BUFFER_DESC cb{};
    cb.ByteWidth = 80;
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    check_hresult(device->CreateBuffer(&cb, nullptr, &constants));
    D3D11_RASTERIZER_DESC rs{};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    check_hresult(device->CreateRasterizerState(&rs, &raster));
}
void Viewport::attach(winrt::Microsoft::UI::Xaml::Controls::SwapChainPanel const &p)
{
    panel = p;
    initDevice();
}
Viewport::Ptr<ID3D11DepthStencilView> Viewport::depthTarget(UINT w, UINT h)
{
    D3D11_TEXTURE2D_DESC d{};
    d.Width = w;
    d.Height = h;
    d.MipLevels = d.ArraySize = d.SampleDesc.Count = 1;
    d.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
    d.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    Ptr<ID3D11Texture2D> tex;
    Ptr<ID3D11DepthStencilView> view;
    check_hresult(device->CreateTexture2D(&d, nullptr, &tex));
    check_hresult(device->CreateDepthStencilView(tex.Get(), nullptr, &view));
    return view;
}
void Viewport::resize(float w, float h, float scaleX, float scaleY)
{
    if (!swap || w <= 0 || h <= 0)
        return;
    camera.width = w;
    camera.height = h;
    sx = scaleX;
    sy = scaleY;
    UINT nw = std::max(1L, lroundf(w * sx)), nh = std::max(1L, lroundf(h * sy));
    if (nw == width && nh == height)
        return;
    context->OMSetRenderTargets(0, nullptr, nullptr);
    target.Reset();
    depth.Reset();
    check_hresult(swap->ResizeBuffers(0, nw, nh, DXGI_FORMAT_UNKNOWN, 0));
    width = nw;
    height = nh;
    Ptr<IDXGISwapChain2> sc;
    check_hresult(swap.As(&sc));
    DXGI_MATRIX_3X2_F m{1 / sx, 0, 0, 1 / sy, 0, 0};
    check_hresult(sc->SetMatrixTransform(&m));
    Ptr<ID3D11Texture2D> back;
    check_hresult(swap->GetBuffer(0, IID_PPV_ARGS(&back)));
    check_hresult(device->CreateRenderTargetView(back.Get(), nullptr, &target));
    depth = depthTarget(width, height);
}
void Viewport::upload(std::vector<std::vector<Face>> const &data, std::vector<Batch> &batches)
{
    batches.clear();
    for (auto const &block : data)
    {
        if (block.empty())
            continue;
        D3D11_BUFFER_DESC d{};
        d.ByteWidth = UINT(block.size() * sizeof(Face));
        d.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        d.Usage = D3D11_USAGE_IMMUTABLE;
        D3D11_SUBRESOURCE_DATA init{block.data()};
        Batch b{{}, UINT(block.size())};
        check_hresult(device->CreateBuffer(&d, &init, &b.buffer));
        batches.push_back(std::move(b));
    }
}
void Viewport::uploadShadow()
{
    if (shadowPixels.empty())
        return;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = desc.Height = 512;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8_UNORM;
    desc.Usage = D3D11_USAGE_IMMUTABLE;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{shadowPixels.data(), 512};
    Ptr<ID3D11Texture2D> texture;
    check_hresult(device->CreateTexture2D(&desc, &data, &texture));
    shadowView.Reset();
    check_hresult(device->CreateShaderResourceView(texture.Get(), nullptr, &shadowView));
    if (!shadowSampler)
    {
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        check_hresult(device->CreateSamplerState(&sampler, &shadowSampler));
    }
}
void Viewport::model(Cells const &cells, Selection const &sel)
{
    // Project a soft contact shadow onto a world-space texture around the model.
    constexpr int side = 512;
    std::vector<unsigned char> field(side * side), horizontal(field.size()), soft(field.size());
    for (auto const &[p, ink] : cells)
    {
        float x = p.x + p.y * .31f + 192, z = p.z - p.y * .19f + 192;
        auto strength = static_cast<unsigned char>(std::max(.4f, 1 - p.y * .012f) * 255);
        for (int v = int(floor(z)); v <= int(ceil(z + 1)); v++)
            for (int u = int(floor(x)); u <= int(ceil(x + 1)); u++)
            {
                if (u >= 0 && u < side && v >= 0 && v < side)
                    field[v * side + u] = std::max(field[v * side + u], strength);
            }
    }
    for (int y = 2; y < side - 2; y++)
        for (int x = 2; x < side - 2; x++)
        {
            auto n = y * side + x;
            horizontal[n] =
                (field[n - 2] + 4 * field[n - 1] + 6 * field[n] + 4 * field[n + 1] + field[n + 2]) / 16;
        }
    for (int y = 2; y < side - 2; y++)
        for (int x = 2; x < side - 2; x++)
        {
            auto n = y * side + x;
            soft[n] = (horizontal[n - 2 * side] + 4 * horizontal[n - side] + 6 * horizontal[n] +
                       4 * horizontal[n + side] + horizontal[n + 2 * side]) /
                      16;
        }
    shadowPixels = std::move(soft);
    uploadShadow();

    sceneData.clear();
    sceneData.emplace_back();
    sceneData.back().push_back({-128, level - .002f, -128, 6, 1, 1, 1, 4, {1, 1, 1, 1}});
    for (auto &[c, i] : cells)
        for (uint32_t f = 0; f < 6; f++)
        {
            auto base = c + normals[f];
            if (cells.contains(base))
                continue;
            Face face{float(c.x), float(c.y), float(c.z), f, i.r, i.g, i.b, sel.contains(c) ? 1u : 0u};
            Cell u = f < 2 ? Cell{0, 0, 1} : Cell{1, 0, 0},
                 v = (f == 2 || f == 3) ? Cell{0, 0, 1} : Cell{0, 1, 0};
            for (int k = 0; k < 4; k++)
            {
                auto a = u * ((k == 1 || k == 2) ? 1 : -1), b = v * (k >= 2 ? 1 : -1);
                int x = cells.contains(base + a), y = cells.contains(base + b);
                face.ao[k] = 1 - .045f * (x && y ? 3 : x + y + cells.contains(base + a + b));
            }
            if (sceneData.back().size() >= 65536)
                sceneData.emplace_back();
            sceneData.back().push_back(face);
        }
    upload(sceneData, sceneBatches);
}
void Viewport::overlay(Cells const &cells, bool invalid)
{
    overlayData.clear();
    overlayData.emplace_back();
    for (auto &[p, i] : cells)
        for (uint32_t f = 0; f < 6; f++)
            if (!cells.contains(p + normals[f]))
            {
                if (overlayData.back().size() >= 65536)
                    overlayData.emplace_back();
                overlayData.back().push_back({float(p.x),
                                              float(p.y),
                                              float(p.z),
                                              f,
                                              invalid ? .98f : .3f,
                                              invalid ? .24f : .75f,
                                              invalid ? .22f : .57f,
                                              2,
                                              {1, 1, 1, 1}});
            }
    upload(overlayData, overlayBatches);
}
void Viewport::drawTo(ID3D11RenderTargetView *rt, ID3D11DepthStencilView *ds, UINT w, UINT h,
                      bool editing)
{
    float bg = dark ? .14f : .95f;
    float clr[]{bg, bg, bg, 1};
    context->ClearRenderTargetView(rt, clr);
    context->ClearDepthStencilView(ds, D3D11_CLEAR_DEPTH, 1, 0);
    context->OMSetRenderTargets(1, &rt, ds);
    auto r = camera.right(), u = camera.up(), e = camera.eye(), c = camera.center;
    float params[]{r.x,
                   r.y,
                   r.z,
                   2 * camera.unit() / camera.width,
                   u.x,
                   u.y,
                   u.z,
                   2 * camera.unit() / camera.height,
                   e.x,
                   e.y,
                   e.z,
                   0,
                   c.x,
                   c.y,
                   c.z,
                   0,
                   grid ? 1.f : 0.f,
                   bg,
                   dark ? .38f : .65f,
                   edges ? 1.f : 0.f};
    context->UpdateSubresource(constants.Get(), 0, nullptr, params, 0, 0);
    context->VSSetConstantBuffers(0, 1, constants.GetAddressOf());
    context->PSSetConstantBuffers(0, 1, constants.GetAddressOf());
    D3D11_VIEWPORT vp{0, 0, float(w), float(h), 0, 1};
    context->RSSetViewports(1, &vp);
    context->RSSetState(raster.Get());
    context->IASetInputLayout(layout.Get());
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    context->VSSetShader(vs.Get(), nullptr, 0);
    context->PSSetShader(ps.Get(), nullptr, 0);
    auto draw = [&](auto const &batches) {
        for (auto const &batch : batches)
        {
            UINT stride = sizeof(Face), offset = 0;
            context->IASetVertexBuffers(0, 1, batch.buffer.GetAddressOf(), &stride, &offset);
            context->DrawInstanced(6, batch.count, 0, 0);
        }
    };
    context->PSSetShaderResources(0, 1, shadowView.GetAddressOf());
    context->PSSetSamplers(0, 1, shadowSampler.GetAddressOf());
    draw(sceneBatches);
    if (editing)
        draw(overlayBatches);
}
void Viewport::draw()
{
    if (!target)
        return;
    drawTo(target.Get(), depth.Get(), width, height, true);
    auto hr = swap->Present(1, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET)
    {
        auto w = camera.width, h = camera.height;
        panel.as<ISwapChainPanelNative>()->SetSwapChain(nullptr);
        target.Reset();
        depth.Reset();
        swap.Reset();
        context.Reset();
        device.Reset();
        vs.Reset();
        ps.Reset();
        layout.Reset();
        constants.Reset();
        raster.Reset();
        width = height = 0;
        shadowSampler.Reset();
        initDevice();
        uploadShadow();
        resize(w, h, sx, sy);
        upload(sceneData, sceneBatches);
        upload(overlayData, overlayBatches);
        drawTo(target.Get(), depth.Get(), width, height, true);
        check_hresult(swap->Present(1, 0));
    }
    else
        check_hresult(hr);
}
void Viewport::png(std::filesystem::path const &path)
{
    float mul = std::min(2.f, 4096.f / std::max(camera.width, camera.height));
    UINT w = std::max(1L, lroundf(camera.width * mul)), h = std::max(1L, lroundf(camera.height * mul));
    D3D11_TEXTURE2D_DESC d{};
    d.Width = w;
    d.Height = h;
    d.MipLevels = d.ArraySize = d.SampleDesc.Count = 1;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.BindFlags = D3D11_BIND_RENDER_TARGET;
    Ptr<ID3D11Texture2D> tex, staging;
    Ptr<ID3D11RenderTargetView> rt;
    check_hresult(device->CreateTexture2D(&d, nullptr, &tex));
    check_hresult(device->CreateRenderTargetView(tex.Get(), nullptr, &rt));
    auto ds = depthTarget(w, h);
    drawTo(rt.Get(), ds.Get(), w, h, false);
    context->OMSetRenderTargets(0, nullptr, nullptr);
    d.Usage = D3D11_USAGE_STAGING;
    d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    d.BindFlags = 0;
    check_hresult(device->CreateTexture2D(&d, nullptr, &staging));
    context->CopyResource(staging.Get(), tex.Get());
    D3D11_MAPPED_SUBRESOURCE map{};
    std::vector<BYTE> pixels(size_t(w) * h * 4);
    check_hresult(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &map));
    for (UINT y = 0; y < h; y++)
        memcpy(pixels.data() + size_t(y) * w * 4,
               static_cast<BYTE *>(map.pData) + size_t(y) * map.RowPitch, w * 4);
    context->Unmap(staging.Get(), 0);
    Ptr<IWICImagingFactory> factory;
    check_hresult(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&factory)));
    Ptr<IStream> stream;
    check_hresult(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
    Ptr<IWICBitmapEncoder> enc;
    check_hresult(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc));
    check_hresult(enc->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    Ptr<IWICBitmapFrameEncode> frame;
    check_hresult(enc->CreateNewFrame(&frame, nullptr));
    check_hresult(frame->Initialize(nullptr));
    check_hresult(frame->SetSize(w, h));
    auto format = GUID_WICPixelFormat32bppBGRA;
    check_hresult(frame->SetPixelFormat(&format));
    check_hresult(frame->WritePixels(h, w * 4, UINT(pixels.size()), pixels.data()));
    check_hresult(frame->Commit());
    check_hresult(enc->Commit());
    STATSTG info{};
    check_hresult(stream->Stat(&info, STATFLAG_NONAME));
    check_hresult(stream->Seek({}, STREAM_SEEK_SET, nullptr));
    std::string bytes(info.cbSize.LowPart, '\0');
    ULONG read;
    check_hresult(stream->Read(bytes.data(), DWORD(bytes.size()), &read));
    if (read != bytes.size())
        throw std::runtime_error("Incomplete PNG.");
    atomicWrite(path, bytes);
    draw();
}
} // namespace forma
