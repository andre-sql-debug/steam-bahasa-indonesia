// RE4 Minecraft overlay: an REFramework plugin that draws Minecraft's live UI over RE4.
// It also reads the raw mouse (movement and buttons) and writes it to
// reframework\data\minecraft_mouse.json every frame, so the Lua scripts can do Minecraft-style
// mouse look without RE4's own camera behavior. While Minecraft is in control, RE4 itself doesn't
// get the mouse (no aiming, no camera turning) or Minecraft's movement keys (Space would ready Leon's
// knife, Shift run, E crouch...). During RE4's turn (cutscenes, menus, F7 in minecraft_control.lua) the
// Minecraft mod marks its picture inactive, and RE4 gets everything again.
//
// The RE4 Bridge Minecraft mod renders only its hand, held item and HUD on a see-through
// background and writes every frame into reframework\data\minecraft_overlay.bin. This plugin
// maps that file, uploads the newest frame to a texture and draws it over the whole screen
// right before RE4 presents the frame. D3D12 only (RE4 Remake uses D3D12).
//
// Shared file layout (little endian):
//   0  u32 magic 'R4MC'     4  u32 version (1)
//   8  u32 width           12  u32 height
//  16  u32 latest slot (0/1, written last)   20  u32 active (1 while Minecraft streams)
//  24  u64 frame counter   32  u32 input to RE4: 0 = none of Minecraft's (mouse + movement keys stay
//      with Minecraft), 1 = movement keys (RE4 moves Leon: ladders, the boat), 2 = everything (a cutscene
//      where your Minecraft character plays Leon)   36  u32 a Minecraft screen is open (inventory,
//      creative menu, chat...): Minecraft gets all keys and the mouse   40..63 reserved
//  64  slot 0, then slot 1: width*height RGBA8 pixels each, bottom row first (OpenGL order),
//      each slot sized for the maximum 1920x1080
//
// Build: see build.sh (MinGW-w64 cross compiler, no Visual Studio needed).

#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "reframework/API.h"

namespace {

constexpr uint32_t MAGIC = 0x434D3452;   // 'R4MC'
constexpr uint32_t MAX_WIDTH = 1920;
constexpr uint32_t MAX_HEIGHT = 1080;
constexpr size_t HEADER_SIZE = 64;
constexpr size_t SLOT_SIZE = size_t(MAX_WIDTH) * MAX_HEIGHT * 4;
constexpr size_t FILE_SIZE = HEADER_SIZE + 2 * SLOT_SIZE;
constexpr uint32_t MAX_BACKBUFFERS = 8;
constexpr DWORD STALE_MS = 1000;           // stop drawing if Minecraft sends nothing for this long
constexpr UINT FRAMES_IN_FLIGHT = 3;       // ring of allocators/upload buffers, so we never wait on RE4's frames

const REFrameworkPluginInitializeParam* g_param = nullptr;

template <typename T> void release(T*& p) {
    if (p != nullptr) {
        p->Release();
        p = nullptr;
    }
}

void log_info(const char* text) {
    if (g_param != nullptr) g_param->functions->log_info("[MinecraftOverlay] %s", text);
}

void log_error(const char* text) {
    if (g_param != nullptr) g_param->functions->log_error("[MinecraftOverlay] %s", text);
}

std::wstring data_folder() {
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring path = exe;
    path = path.substr(0, path.find_last_of(L"\\/"));
    return path + L"\\reframework\\data\\";
}

// ---------------------------------------------------------------------------------------------
// Shared file from Minecraft
// ---------------------------------------------------------------------------------------------

struct SharedFrame {
    HANDLE file = INVALID_HANDLE_VALUE;
    HANDLE mapping = nullptr;
    const uint8_t* view = nullptr;
    DWORD next_try = 0;

    bool open() {
        if (view != nullptr) return true;
        DWORD now = GetTickCount();
        if (now < next_try) return false;
        next_try = now + 2000;

        std::wstring path = data_folder() + L"minecraft_overlay.bin";
        file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        LARGE_INTEGER size{};
        if (!GetFileSizeEx(file, &size) || size.QuadPart < (LONGLONG)FILE_SIZE) {
            close();
            return false;
        }
        mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
        if (mapping == nullptr) {
            close();
            return false;
        }
        view = (const uint8_t*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, FILE_SIZE);
        if (view == nullptr) {
            close();
            return false;
        }
        log_info("connected to minecraft_overlay.bin");
        return true;
    }

    void close() {
        if (view != nullptr) UnmapViewOfFile(view);
        if (mapping != nullptr) CloseHandle(mapping);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        view = nullptr;
        mapping = nullptr;
        file = INVALID_HANDLE_VALUE;
    }

    uint32_t u32(size_t offset) const { return *(volatile const uint32_t*)(view + offset); }
    uint64_t u64(size_t offset) const { return *(volatile const uint64_t*)(view + offset); }
};

SharedFrame g_shared;

// True while Minecraft streams its picture (RE4 is in control of Minecraft); set by the renderer
volatile LONG g_minecraft_active = 0;
// Which input RE4 gets while Minecraft is drawn: see "input to RE4" in the file layout above
volatile LONG g_input_to_re4 = 0;
// True while a Minecraft screen (inventory, chat...) is open: all input goes to Minecraft
volatile LONG g_minecraft_screen = 0;

// ---------------------------------------------------------------------------------------------
// D3D12 drawing
// ---------------------------------------------------------------------------------------------

const char* SHADER = R"(
Texture2D tex : register(t0);
SamplerState samp : register(s0);
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };
VSOut vs_main(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}
float4 ps_main(VSOut i) : SV_TARGET { return tex.Sample(samp, i.uv); }
)";

using D3DCompileFn = HRESULT(WINAPI*)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO*, ID3DInclude*, LPCSTR, LPCSTR,
                                      UINT, UINT, ID3DBlob**, ID3DBlob**);
using SerializeRootSignatureFn = HRESULT(WINAPI*)(const D3D12_ROOT_SIGNATURE_DESC*, D3D_ROOT_SIGNATURE_VERSION,
                                                   ID3DBlob**, ID3DBlob**);

struct Renderer {
    bool ready = false;
    bool failed = false;
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    IDXGISwapChain3* swapchain = nullptr;

    ID3D12CommandAllocator* allocators[FRAMES_IN_FLIGHT]{};
    ID3D12GraphicsCommandList* list = nullptr;
    ID3D12Fence* fence = nullptr;
    HANDLE fence_event = nullptr;
    uint64_t fence_value = 0;
    uint64_t ctx_fence[FRAMES_IN_FLIGHT]{};   // fence value of each ring slot's last submission
    UINT ctx = 0;

    ID3D12DescriptorHeap* rtv_heap = nullptr;
    ID3D12DescriptorHeap* srv_heap = nullptr;
    UINT rtv_size = 0;
    ID3D12Resource* backbuffers[MAX_BACKBUFFERS]{};
    UINT backbuffer_count = 0;
    UINT bb_width = 0, bb_height = 0;
    DXGI_FORMAT bb_format = DXGI_FORMAT_UNKNOWN;

    ID3D12RootSignature* root_signature = nullptr;
    ID3D12PipelineState* pipeline = nullptr;

    ID3D12Resource* texture = nullptr;
    ID3D12Resource* uploads[FRAMES_IN_FLIGHT]{};
    uint8_t* upload_ptrs[FRAMES_IN_FLIGHT]{};
    UINT tex_width = 0, tex_height = 0, upload_pitch = 0;
    bool texture_has_frame = false;

    uint64_t last_frame = 0;
    DWORD last_frame_time = 0;

    void wait_for(uint64_t value) {
        if (fence == nullptr || value == 0 || fence->GetCompletedValue() >= value) return;
        fence->SetEventOnCompletion(value, fence_event);
        WaitForSingleObject(fence_event, 2000);
    }

    // Waits for all of our own submitted work (only on shutdown/resize/texture size changes)
    void wait_gpu() {
        if (fence == nullptr || queue == nullptr) return;
        ++fence_value;
        if (SUCCEEDED(queue->Signal(fence, fence_value))) wait_for(fence_value);
    }

    void release_uploads() {
        for (UINT i = 0; i < FRAMES_IN_FLIGHT; ++i) {
            if (uploads[i] != nullptr && upload_ptrs[i] != nullptr) uploads[i]->Unmap(0, nullptr);
            upload_ptrs[i] = nullptr;
            release(uploads[i]);
        }
    }

    void release_backbuffers() {
        for (auto& bb : backbuffers) release(bb);
        backbuffer_count = 0;
    }

    void shutdown() {
        wait_gpu();
        release_backbuffers();
        release_uploads();
        release(texture);
        release(pipeline);
        release(root_signature);
        release(rtv_heap);
        release(srv_heap);
        release(list);
        for (auto& a : allocators) release(a);
        release(fence);
        for (auto& v : ctx_fence) v = 0;
        if (fence_event != nullptr) CloseHandle(fence_event);
        fence_event = nullptr;
        tex_width = tex_height = 0;
        texture_has_frame = false;
        ready = false;
    }

    bool create_backbuffer_views() {
        DXGI_SWAP_CHAIN_DESC desc{};
        if (FAILED(swapchain->GetDesc(&desc))) return false;
        backbuffer_count = desc.BufferCount < MAX_BACKBUFFERS ? desc.BufferCount : MAX_BACKBUFFERS;
        D3D12_CPU_DESCRIPTOR_HANDLE handle = rtv_heap->GetCPUDescriptorHandleForHeapStart();
        for (UINT i = 0; i < backbuffer_count; ++i) {
            if (FAILED(swapchain->GetBuffer(i, __uuidof(ID3D12Resource), (void**)&backbuffers[i]))) return false;
            D3D12_RENDER_TARGET_VIEW_DESC rtv{};
            rtv.Format = bb_format;
            rtv.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D;
            device->CreateRenderTargetView(backbuffers[i], &rtv, handle);
            handle.ptr += rtv_size;
        }
        D3D12_RESOURCE_DESC bb = backbuffers[0]->GetDesc();
        bb_width = (UINT)bb.Width;
        bb_height = bb.Height;
        return true;
    }

    static DXGI_FORMAT view_format(DXGI_FORMAT f) {
        switch (f) {
        case DXGI_FORMAT_R8G8B8A8_TYPELESS: return DXGI_FORMAT_R8G8B8A8_UNORM;
        case DXGI_FORMAT_B8G8R8A8_TYPELESS: return DXGI_FORMAT_B8G8R8A8_UNORM;
        case DXGI_FORMAT_R10G10B10A2_TYPELESS: return DXGI_FORMAT_R10G10B10A2_UNORM;
        case DXGI_FORMAT_R16G16B16A16_TYPELESS: return DXGI_FORMAT_R16G16B16A16_FLOAT;
        default: return f;
        }
    }

    bool create_pipeline() {
        HMODULE compiler = LoadLibraryW(L"d3dcompiler_47.dll");
        HMODULE d3d12 = GetModuleHandleW(L"d3d12.dll");
        if (compiler == nullptr || d3d12 == nullptr) {
            log_error("d3dcompiler_47.dll or d3d12.dll not available");
            return false;
        }
        auto compile = (D3DCompileFn)GetProcAddress(compiler, "D3DCompile");
        auto serialize = (SerializeRootSignatureFn)GetProcAddress(d3d12, "D3D12SerializeRootSignature");
        if (compile == nullptr || serialize == nullptr) return false;

        D3D12_DESCRIPTOR_RANGE range{};
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
        range.NumDescriptors = 1;
        range.BaseShaderRegister = 0;
        range.OffsetInDescriptorsFromTableStart = 0;

        D3D12_ROOT_PARAMETER param{};
        param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        param.DescriptorTable.NumDescriptorRanges = 1;
        param.DescriptorTable.pDescriptorRanges = &range;
        param.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        // Point sampling keeps Minecraft's pixels sharp when scaled up
        D3D12_STATIC_SAMPLER_DESC sampler{};
        sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_POINT;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.MaxLOD = D3D12_FLOAT32_MAX;
        sampler.ShaderRegister = 0;
        sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

        D3D12_ROOT_SIGNATURE_DESC rs{};
        rs.NumParameters = 1;
        rs.pParameters = &param;
        rs.NumStaticSamplers = 1;
        rs.pStaticSamplers = &sampler;

        ID3DBlob* blob = nullptr;
        ID3DBlob* errors = nullptr;
        if (FAILED(serialize(&rs, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors))) {
            release(errors);
            return false;
        }
        HRESULT hr = device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                                 __uuidof(ID3D12RootSignature), (void**)&root_signature);
        release(blob);
        if (FAILED(hr)) return false;

        ID3DBlob* vs = nullptr;
        ID3DBlob* ps = nullptr;
        if (FAILED(compile(SHADER, strlen(SHADER), "overlay", nullptr, nullptr, "vs_main", "vs_5_0", 0, 0, &vs, &errors)) ||
            FAILED(compile(SHADER, strlen(SHADER), "overlay", nullptr, nullptr, "ps_main", "ps_5_0", 0, 0, &ps, &errors))) {
            if (errors != nullptr) log_error((const char*)errors->GetBufferPointer());
            release(errors);
            release(vs);
            release(ps);
            return false;
        }

        D3D12_GRAPHICS_PIPELINE_STATE_DESC pso{};
        pso.pRootSignature = root_signature;
        pso.VS = { vs->GetBufferPointer(), vs->GetBufferSize() };
        pso.PS = { ps->GetBufferPointer(), ps->GetBufferSize() };
        auto& blend = pso.BlendState.RenderTarget[0];
        blend.BlendEnable = TRUE;
        blend.SrcBlend = D3D12_BLEND_SRC_ALPHA;
        blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
        blend.BlendOp = D3D12_BLEND_OP_ADD;
        blend.SrcBlendAlpha = D3D12_BLEND_ONE;
        blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
        blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
        blend.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
        pso.SampleMask = UINT_MAX;
        pso.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
        pso.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
        pso.RasterizerState.DepthClipEnable = TRUE;
        pso.DepthStencilState.DepthEnable = FALSE;
        pso.DepthStencilState.StencilEnable = FALSE;
        pso.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pso.NumRenderTargets = 1;
        pso.RTVFormats[0] = bb_format;
        pso.SampleDesc.Count = 1;
        hr = device->CreateGraphicsPipelineState(&pso, __uuidof(ID3D12PipelineState), (void**)&pipeline);
        release(vs);
        release(ps);
        return SUCCEEDED(hr);
    }

    bool initialize() {
        const REFrameworkRendererData* data = g_param->renderer_data;
        if (data == nullptr || data->renderer_type != REFRAMEWORK_RENDERER_D3D12 || data->device == nullptr ||
            data->swapchain == nullptr || data->command_queue == nullptr) {
            return false;
        }
        device = (ID3D12Device*)data->device;
        queue = (ID3D12CommandQueue*)data->command_queue;
        swapchain = (IDXGISwapChain3*)data->swapchain;

        for (auto& a : allocators) {
            if (FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator), (void**)&a))) {
                log_error("could not create command allocators");
                return false;
            }
        }
        if (FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocators[0], nullptr, __uuidof(ID3D12GraphicsCommandList), (void**)&list)) ||
            FAILED(list->Close()) ||
            FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), (void**)&fence))) {
            log_error("could not create command objects");
            return false;
        }
        fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);

        D3D12_DESCRIPTOR_HEAP_DESC rtv{};
        rtv.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        rtv.NumDescriptors = MAX_BACKBUFFERS;
        D3D12_DESCRIPTOR_HEAP_DESC srv{};
        srv.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        srv.NumDescriptors = 1;
        srv.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        if (FAILED(device->CreateDescriptorHeap(&rtv, __uuidof(ID3D12DescriptorHeap), (void**)&rtv_heap)) ||
            FAILED(device->CreateDescriptorHeap(&srv, __uuidof(ID3D12DescriptorHeap), (void**)&srv_heap))) {
            log_error("could not create descriptor heaps");
            return false;
        }
        rtv_size = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

        ID3D12Resource* first = nullptr;
        if (FAILED(swapchain->GetBuffer(0, __uuidof(ID3D12Resource), (void**)&first))) return false;
        bb_format = view_format(first->GetDesc().Format);
        release(first);

        if (!create_backbuffer_views()) {
            log_error("could not get the back buffers");
            return false;
        }
        if (!create_pipeline()) {
            log_error("could not create the drawing pipeline");
            return false;
        }

        char msg[128];
        snprintf(msg, sizeof(msg), "ready, screen %ux%u, format %d", bb_width, bb_height, (int)bb_format);
        log_info(msg);
        ready = true;
        return true;
    }

    bool ensure_texture(UINT w, UINT h) {
        if (texture != nullptr && tex_width == w && tex_height == h) return true;
        wait_gpu();
        release_uploads();
        release(texture);
        texture_has_frame = false;

        D3D12_HEAP_PROPERTIES heap{};
        heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC desc{};
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = w;
        desc.Height = h;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
                                                   nullptr, __uuidof(ID3D12Resource), (void**)&texture))) {
            return false;
        }

        upload_pitch = (w * 4 + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) & ~(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1);
        D3D12_HEAP_PROPERTIES upload_heap{};
        upload_heap.Type = D3D12_HEAP_TYPE_UPLOAD;
        D3D12_RESOURCE_DESC buffer{};
        buffer.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        buffer.Width = UINT64(upload_pitch) * h;
        buffer.Height = 1;
        buffer.DepthOrArraySize = 1;
        buffer.MipLevels = 1;
        buffer.SampleDesc.Count = 1;
        buffer.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        for (UINT i = 0; i < FRAMES_IN_FLIGHT; ++i) {
            if (FAILED(device->CreateCommittedResource(&upload_heap, D3D12_HEAP_FLAG_NONE, &buffer, D3D12_RESOURCE_STATE_GENERIC_READ,
                                                       nullptr, __uuidof(ID3D12Resource), (void**)&uploads[i]))) {
                return false;
            }
            D3D12_RANGE none{ 0, 0 };
            if (FAILED(uploads[i]->Map(0, &none, (void**)&upload_ptrs[i]))) return false;
        }

        D3D12_SHADER_RESOURCE_VIEW_DESC srv{};
        srv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        srv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        srv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        srv.Texture2D.MipLevels = 1;
        device->CreateShaderResourceView(texture, &srv, srv_heap->GetCPUDescriptorHandleForHeapStart());

        tex_width = w;
        tex_height = h;
        return true;
    }

    static void transition(ID3D12GraphicsCommandList* list, ID3D12Resource* res, D3D12_RESOURCE_STATES from, D3D12_RESOURCE_STATES to) {
        D3D12_RESOURCE_BARRIER b{};
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition.pResource = res;
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = from;
        b.Transition.StateAfter = to;
        list->ResourceBarrier(1, &b);
    }

    void frame() {
        if (failed) return;
        if (!ready && !initialize()) {
            failed = true;
            shutdown();
            log_error("disabled (could not initialize)");
            return;
        }
        if (!g_shared.open()) return;

        const SharedFrame& s = g_shared;
        if (s.u32(0) != MAGIC || s.u32(20) == 0) {   // Minecraft isn't streaming
            InterlockedExchange(&g_minecraft_active, 0);
            return;
        }
        uint64_t counter = s.u64(24);
        DWORD now = GetTickCount();
        bool new_frame = counter != last_frame;
        if (new_frame) {
            last_frame = counter;
            last_frame_time = now;
        } else if (now - last_frame_time > STALE_MS) {
            InterlockedExchange(&g_minecraft_active, 0);
            return;   // Minecraft stopped (closed or frozen): show nothing
        }
        InterlockedExchange(&g_minecraft_active, 1);
        InterlockedExchange(&g_input_to_re4, (LONG)s.u32(32));
        InterlockedExchange(&g_minecraft_screen, s.u32(36) != 0 ? 1 : 0);

        UINT w = s.u32(8), h = s.u32(12);
        if (w == 0 || h == 0 || w > MAX_WIDTH || h > MAX_HEIGHT) return;
        if (!ensure_texture(w, h)) {
            log_error("could not create the overlay texture");
            failed = true;
            return;
        }
        if (!new_frame && !texture_has_frame) return;

        // This ring slot's previous commands must be done before we reuse its allocator and upload buffer
        ctx = (ctx + 1) % FRAMES_IN_FLIGHT;
        wait_for(ctx_fence[ctx]);
        allocators[ctx]->Reset();
        list->Reset(allocators[ctx], nullptr);
        uint8_t* upload_ptr = upload_ptrs[ctx];

        if (new_frame) {
            UINT slot = s.u32(16) & 1;
            const uint8_t* pixels = s.view + HEADER_SIZE + slot * SLOT_SIZE;
            // OpenGL stores the bottom row first; flip while copying
            for (UINT y = 0; y < h; ++y) {
                memcpy(upload_ptr + size_t(y) * upload_pitch, pixels + size_t(h - 1 - y) * w * 4, size_t(w) * 4);
            }
            transition(list, texture, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
            D3D12_TEXTURE_COPY_LOCATION dst{};
            dst.pResource = texture;
            dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            dst.SubresourceIndex = 0;
            D3D12_TEXTURE_COPY_LOCATION src{};
            src.pResource = uploads[ctx];
            src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            src.PlacedFootprint.Offset = 0;
            src.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            src.PlacedFootprint.Footprint.Width = w;
            src.PlacedFootprint.Footprint.Height = h;
            src.PlacedFootprint.Footprint.Depth = 1;
            src.PlacedFootprint.Footprint.RowPitch = upload_pitch;
            list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
            transition(list, texture, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            texture_has_frame = true;
        }

        UINT index = swapchain->GetCurrentBackBufferIndex();
        if (index >= backbuffer_count || backbuffers[index] == nullptr) {
            list->Close();
            ID3D12CommandList* copy_only[] = { list };
            queue->ExecuteCommandLists(1, copy_only);
            queue->Signal(fence, ++fence_value);
            ctx_fence[ctx] = fence_value;
            return;
        }
        ID3D12Resource* bb = backbuffers[index];
        transition(list, bb, D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);

        D3D12_CPU_DESCRIPTOR_HANDLE rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
        rtv.ptr += SIZE_T(index) * rtv_size;
        list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
        D3D12_VIEWPORT vp{ 0.0f, 0.0f, float(bb_width), float(bb_height), 0.0f, 1.0f };
        D3D12_RECT scissor{ 0, 0, LONG(bb_width), LONG(bb_height) };
        list->RSSetViewports(1, &vp);
        list->RSSetScissorRects(1, &scissor);
        list->SetPipelineState(pipeline);
        list->SetGraphicsRootSignature(root_signature);
        list->SetDescriptorHeaps(1, &srv_heap);
        list->SetGraphicsRootDescriptorTable(0, srv_heap->GetGPUDescriptorHandleForHeapStart());
        list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        list->DrawInstanced(3, 1, 0, 0);

        transition(list, bb, D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        list->Close();
        ID3D12CommandList* lists[] = { list };
        queue->ExecuteCommandLists(1, lists);
        queue->Signal(fence, ++fence_value);
        ctx_fence[ctx] = fence_value;
    }
};

Renderer g_renderer;

// ---------------------------------------------------------------------------------------------
// Status file for the Lua scripts (they hide their own HUD while this plugin draws Minecraft's)
// ---------------------------------------------------------------------------------------------

uint64_t g_present_count = 0;

// Raw mouse input, totals since start (the Lua script uses the difference between reads)
volatile LONG64 g_mouse_x = 0;
volatile LONG64 g_mouse_y = 0;
volatile LONG64 g_left_presses = 0;
volatile LONG64 g_right_presses = 0;
volatile LONG64 g_left_releases = 0;
volatile LONG64 g_right_releases = 0;
volatile LONG64 g_middle_presses = 0;
volatile LONG64 g_middle_releases = 0;
volatile LONG64 g_wheel = 0;   // in WHEEL_DELTA units (120 per notch)
volatile LONG g_left_down = 0;
volatile LONG g_right_down = 0;

// Keyboard events for Minecraft (its screens: inventory, creative search, chat; and its hotkeys), kept
// in a small numbered log so Minecraft can pick up every event it hasn't seen yet. kind: 0 = key up,
// 1 = key down, 2 = typed character, 3 = key repeat. code: the virtual key, or the character.
struct KeyEvent {
    uint64_t seq;
    int kind;
    unsigned code;
};
constexpr int KEY_LOG = 128;
KeyEvent g_key_log[KEY_LOG];
uint64_t g_key_seq = 0;
SRWLOCK g_key_lock = SRWLOCK_INIT;
bool g_raw_keyboard = false;   // RE4 gets raw keyboard input: use that, not the legacy key messages
bool g_keys_down[256] = {};

void push_key_event(int kind, unsigned code) {
    AcquireSRWLockExclusive(&g_key_lock);
    KeyEvent& e = g_key_log[g_key_seq % KEY_LOG];
    e.seq = ++g_key_seq;
    e.kind = kind;
    e.code = code;
    ReleaseSRWLockExclusive(&g_key_lock);
}

// One key going down or up (from raw input or key messages): the key event, and for a key going down the
// characters it types with the current Shift/Caps state
void on_key(UINT vk, UINT scan, bool down) {
    if (vk == 0 || vk >= 256) return;
    if (!down) {
        g_keys_down[vk] = false;
        push_key_event(0, vk);
        return;
    }
    push_key_event(g_keys_down[vk] ? 3 : 1, vk);
    g_keys_down[vk] = true;
    BYTE state[256] = {};
    bool shift = g_keys_down[VK_SHIFT] || g_keys_down[VK_LSHIFT] || g_keys_down[VK_RSHIFT];
    bool ctrl = g_keys_down[VK_CONTROL] || g_keys_down[VK_LCONTROL] || g_keys_down[VK_RCONTROL];
    if (shift) state[VK_SHIFT] = 0x80;
    if (ctrl) state[VK_CONTROL] = 0x80;
    if (GetKeyState(VK_CAPITAL) & 1) state[VK_CAPITAL] = 0x01;
    WCHAR chars[4] = {};
    // flag 4: don't change the keyboard's dead-key state (Windows 10 1607+)
    int n = ToUnicode(vk, scan, state, chars, 4, 4);
    for (int i = 0; i < n; ++i) {
        if (chars[i] >= 0x20 && chars[i] != 0x7F) push_key_event(2, chars[i]);
    }
}

// Keys Minecraft uses for moving, its hotbar and its screens. While Minecraft has Leon, RE4 must not act on
// them too (Space readies the knife, Shift runs, Ctrl, E crouches, Q turns around, 1-9 switch weapons).
bool is_minecraft_key(UINT vk) {
    switch (vk) {
    case 'W': case 'A': case 'S': case 'D': case 'E': case 'Q':
    case 'T': case VK_OEM_2: case VK_F1: case VK_F2: case VK_F3:   // chat, commands, Minecraft's F-keys
    case VK_SPACE: case VK_SHIFT: case VK_LSHIFT: case VK_RSHIFT:
    case VK_CONTROL: case VK_LCONTROL: case VK_RCONTROL:
        return true;
    default:
        return vk >= '1' && vk <= '9';
    }
}

bool raw_keyboard_input(long long lparam) {
    RAWINPUTHEADER header{};
    UINT size = sizeof(header);
    return GetRawInputData((HRAWINPUT)lparam, RID_HEADER, &header, &size, sizeof(RAWINPUTHEADER)) != (UINT)-1 &&
           header.dwType == RIM_TYPEKEYBOARD;
}

bool on_message(void* hwnd, unsigned int msg, unsigned long long wparam, long long lparam) {
    // What this raw input is, for deciding below whether RE4 gets it
    bool raw_mouse = false, raw_release = false, raw_minecraft_key = false;
    if (msg == WM_INPUT) {
        RAWINPUT raw{};
        UINT size = sizeof(raw);
        bool got = GetRawInputData((HRAWINPUT)lparam, RID_INPUT, &raw, &size, sizeof(RAWINPUTHEADER)) != (UINT)-1;
        if (got && raw.header.dwType == RIM_TYPEKEYBOARD) {
            const RAWKEYBOARD& k = raw.data.keyboard;
            raw_minecraft_key = is_minecraft_key(k.VKey);
            raw_release = (k.Flags & RI_KEY_BREAK) != 0;
            if (k.VKey != 0xFF) {   // 0xFF: part of an escape sequence, not a key
                g_raw_keyboard = true;
                UINT vk = k.VKey;
                // Tell left and right Shift/Ctrl/Alt apart (Minecraft has separate keys for them)
                if (vk == VK_SHIFT) vk = MapVirtualKeyW(k.MakeCode, MAPVK_VSC_TO_VK_EX);
                else if (vk == VK_CONTROL) vk = (k.Flags & RI_KEY_E0) ? VK_RCONTROL : VK_LCONTROL;
                else if (vk == VK_MENU) vk = (k.Flags & RI_KEY_E0) ? VK_RMENU : VK_LMENU;
                on_key(vk, k.MakeCode, !raw_release);
            }
        } else if (got && raw.header.dwType == RIM_TYPEMOUSE) {
            raw_mouse = true;
            const RAWMOUSE& m = raw.data.mouse;
            const USHORT ups = RI_MOUSE_LEFT_BUTTON_UP | RI_MOUSE_RIGHT_BUTTON_UP | RI_MOUSE_MIDDLE_BUTTON_UP |
                               RI_MOUSE_BUTTON_4_UP | RI_MOUSE_BUTTON_5_UP;
            raw_release = (m.usButtonFlags & ups) != 0;
            if ((m.usFlags & MOUSE_MOVE_ABSOLUTE) == 0) {
                InterlockedAdd64(&g_mouse_x, m.lLastX);
                InterlockedAdd64(&g_mouse_y, m.lLastY);
            }
            if (m.usButtonFlags & RI_MOUSE_LEFT_BUTTON_DOWN) { InterlockedIncrement64(&g_left_presses); InterlockedExchange(&g_left_down, 1); }
            if (m.usButtonFlags & RI_MOUSE_LEFT_BUTTON_UP) { InterlockedIncrement64(&g_left_releases); InterlockedExchange(&g_left_down, 0); }
            if (m.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_DOWN) { InterlockedIncrement64(&g_right_presses); InterlockedExchange(&g_right_down, 1); }
            if (m.usButtonFlags & RI_MOUSE_RIGHT_BUTTON_UP) { InterlockedIncrement64(&g_right_releases); InterlockedExchange(&g_right_down, 0); }
            if (m.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_DOWN) InterlockedIncrement64(&g_middle_presses);
            if (m.usButtonFlags & RI_MOUSE_MIDDLE_BUTTON_UP) InterlockedIncrement64(&g_middle_releases);
            if (m.usButtonFlags & RI_MOUSE_WHEEL) InterlockedAdd64(&g_wheel, (SHORT)m.usButtonData);
        }
    }
    // Without raw keyboard input, the key messages carry the keys
    if (!g_raw_keyboard) {
        UINT scan = (UINT)((lparam >> 16) & 0xFF);
        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
            UINT vk = (UINT)wparam;
            if (vk == VK_SHIFT) vk = MapVirtualKeyW(scan, MAPVK_VSC_TO_VK_EX);
            else if (vk == VK_CONTROL) vk = (lparam & (1LL << 24)) ? VK_RCONTROL : VK_LCONTROL;
            else if (vk == VK_MENU) vk = (lparam & (1LL << 24)) ? VK_RMENU : VK_LMENU;
            on_key(vk, scan, true);
        } else if (msg == WM_KEYUP || msg == WM_SYSKEYUP) {
            UINT vk = (UINT)wparam;
            if (vk == VK_SHIFT) vk = MapVirtualKeyW(scan, MAPVK_VSC_TO_VK_EX);
            else if (vk == VK_CONTROL) vk = (lparam & (1LL << 24)) ? VK_RCONTROL : VK_LCONTROL;
            else if (vk == VK_MENU) vk = (lparam & (1LL << 24)) ? VK_RMENU : VK_LMENU;
            on_key(vk, scan, false);
        }
    }

    // While Minecraft is in control, RE4 doesn't get the mouse or Minecraft's movement keys: Minecraft does
    // the moving, looking and clicking. Releases always go through, so RE4 never keeps a key or button
    // "held" that was pressed during its own turn.
    bool menu_open = g_param != nullptr && g_param->functions->is_drawing_ui();
    // A Minecraft screen is open (inventory, chat...): Minecraft gets every key and the mouse; RE4 gets
    // none of it (Esc closes Minecraft's screen, not RE4's pause menu)
    if (g_minecraft_active && g_minecraft_screen && !menu_open) {
        switch (msg) {
        case WM_INPUT:
            if ((raw_mouse || raw_keyboard_input(lparam)) && !raw_release) {
                return false;
            }
            break;
        case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_CHAR: case WM_SYSCHAR:
        case WM_MOUSEMOVE: case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK:
        case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK:
        case WM_MBUTTONDOWN: case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL:
        case WM_XBUTTONDOWN:
            return false;
        default:
            break;
        }
        return true;
    }
    if (g_minecraft_active && g_input_to_re4 < 2 && !menu_open) {
        bool keys_to_re4 = g_input_to_re4 == 1;
        switch (msg) {
        case WM_INPUT:
            if ((raw_mouse || (raw_minecraft_key && !keys_to_re4)) && !raw_release) {
                return false;
            }
            break;
        case WM_KEYDOWN:
            if (is_minecraft_key((UINT)wparam) && !keys_to_re4) {
                return false;
            }
            break;
        case WM_MOUSEMOVE: case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK:
        case WM_RBUTTONDOWN: case WM_RBUTTONDBLCLK:
        case WM_MBUTTONDOWN: case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL:
        case WM_XBUTTONDOWN:
            return false;
        default:
            break;
        }
    }
    return true;   // the game gets every other message
}

void write_mouse() {
    static std::wstring path = data_folder() + L"minecraft_mouse.json";
    static std::wstring tmp = data_folder() + L"minecraft_mouse.json.tmp";
    FILE* f = _wfopen(tmp.c_str(), L"wb");
    if (f == nullptr) return;
    fprintf(f, "{\"frame\":%llu,\"x\":%lld,\"y\":%lld,\"left_presses\":%lld,\"right_presses\":%lld,"
               "\"left_releases\":%lld,\"right_releases\":%lld,\"middle_presses\":%lld,\"middle_releases\":%lld,"
               "\"wheel\":%lld,\"left\":%s,\"right\":%s,\"minecraft_has_mouse\":%s,",
            (unsigned long long)g_present_count, (long long)g_mouse_x, (long long)g_mouse_y,
            (long long)g_left_presses, (long long)g_right_presses,
            (long long)g_left_releases, (long long)g_right_releases,
            (long long)g_middle_presses, (long long)g_middle_releases, (long long)g_wheel,
            g_left_down ? "true" : "false", g_right_down ? "true" : "false",
            g_minecraft_active ? "true" : "false");
    // The keyboard log: newest sequence number and the last events, oldest first
    AcquireSRWLockShared(&g_key_lock);
    uint64_t newest = g_key_seq;
    fprintf(f, "\"kseq\":%llu,\"kev\":[", (unsigned long long)newest);
    uint64_t first = newest > KEY_LOG ? newest - KEY_LOG + 1 : 1;
    for (uint64_t seq = first; seq <= newest; ++seq) {
        const KeyEvent& e = g_key_log[seq % KEY_LOG];
        fprintf(f, "%s[%llu,%d,%u]", seq == first ? "" : ",", (unsigned long long)e.seq, e.kind, e.code);
    }
    ReleaseSRWLockShared(&g_key_lock);
    fprintf(f, "]}");
    fclose(f);
    MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
}

void write_status() {
    std::wstring path = data_folder() + L"minecraft_overlay_plugin.json";
    FILE* f = _wfopen(path.c_str(), L"wb");
    if (f == nullptr) return;
    fprintf(f, "{\"beat\":%llu,\"ready\":%s,\"width\":%u,\"height\":%u}", (unsigned long long)(g_present_count / 60),
            g_renderer.ready ? "true" : "false", g_renderer.bb_width, g_renderer.bb_height);
    fclose(f);
}

void on_present() {
    ++g_present_count;
    g_renderer.frame();
    write_mouse();
    if (g_present_count % 60 == 1) write_status();
}

// RE4 is resizing its swap chain: let go of the back buffers, take them again afterwards
void on_device_reset() {
    if (!g_renderer.ready) return;
    g_renderer.wait_gpu();
    g_renderer.release_backbuffers();
    g_renderer.shutdown();
}

}  // namespace

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    g_param = param;
    param->functions->on_present(on_present);
    param->functions->on_device_reset(on_device_reset);
    param->functions->on_message((REFOnMessageCb)on_message);
    log_info("loaded");
    return true;
}
