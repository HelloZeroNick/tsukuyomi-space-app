#include "include/tsukuyomi_live2d/tsukuyomi_live2d_plugin_c_api.h"
#include "../src/gpu_api.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <atomic>
#include <deque>
#include <future>
#include <map>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace {
using Microsoft::WRL::ComPtr;
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using L = flutter::EncodableList;
void check(HRESULT hr, const char* message) { if (FAILED(hr)) throw std::runtime_error(message); }
void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
const V& at(const M& m, const char* key) {
  auto it = m.find(V(key));
  if (it == m.end()) throw std::runtime_error("Missing GPU argument");
  return it->second;
}
int64_t number(const V& v) {
  if (auto i = std::get_if<int32_t>(&v)) return *i;
  return std::get<int64_t>(v);
}
double micros(std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
}
// Cubism caches device state globally. All engines share this worker/device.
class Worker {
 public:
  Worker() : thread_([this] {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    for (;;) {
      std::function<void()> job;
      { std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&] { return stopped_ || !jobs_.empty(); });
        if (stopped_ && jobs_.empty()) break;
        job = std::move(jobs_.front()); jobs_.pop_front(); }
      job();
    }
    context.Reset(); device.Reset();
    CoUninitialize();
  }) {}
  ~Worker() { { std::lock_guard<std::mutex> lock(mutex_); stopped_ = true; } cv_.notify_one(); thread_.join(); }
  void post(std::function<void()> job) {
    { std::lock_guard<std::mutex> lock(mutex_); jobs_.push_back(std::move(job)); } cv_.notify_one();
  }
  void drain() { auto done = std::make_shared<std::promise<void>>(); auto future = done->get_future();
    post([done] { done->set_value(); }); future.wait(); }
  void initialize() {
    if (device) return;
    // Explicit CI-only opt-in; normal runs never silently select software D3D.
    const char* qa = std::getenv("TSUKUYOMI_GPU_QA_WARP");
    auto driver = qa && std::string(qa) == "1" ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE;
    check(D3D11CreateDevice(nullptr, driver, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context), "D3D11 device unavailable");
  }
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
 private:
  std::mutex mutex_; std::condition_variable cv_;
  std::deque<std::function<void()>> jobs_; bool stopped_ = false; std::thread thread_;
};
Worker& worker() { static Worker w; return w; }
struct Surface {
  ComPtr<ID3D11Texture2D> texture;
  ComPtr<ID3D11RenderTargetView> target;
  HANDLE shared = nullptr;
  int width = 0, height = 0;
};
struct Scene {
  const TsGpuApi* api = nullptr;
  void* model = nullptr;
  int64_t id = -1;
  std::atomic<bool> registered{false};
  std::mutex mutex;
  std::shared_ptr<Surface> front;
  std::shared_ptr<Surface> consumer;
  std::shared_ptr<Surface> render_target;
  FlutterDesktopGpuSurfaceDescriptor descriptor{};
  std::vector<ComPtr<ID3D11ShaderResourceView>> atlases;
  std::unique_ptr<flutter::TextureVariant> texture;
  void close() {
    if (model) { api->destroy(model); model = nullptr; }
    atlases.clear();
    std::lock_guard<std::mutex> lock(mutex); front.reset(); render_target.reset();
  }
  const FlutterDesktopGpuSurfaceDescriptor* copy() {
    std::lock_guard<std::mutex> lock(mutex);
    if (!front) return nullptr;
    consumer = front;
    auto& d = descriptor;
    d.struct_size = sizeof(d); d.handle = front->shared;
    d.width = d.visible_width = front->width;
    d.height = d.visible_height = front->height;
    d.format = kFlutterDesktopPixelFormatBGRA8888;
    d.release_context = new std::shared_ptr<Surface>(front);
    // Flutter invokes this after importing the handle, then still reads the
    // descriptor. Keep metadata alive and never reuse a published GPU image.
    d.release_callback = [](void* p) { delete static_cast<std::shared_ptr<Surface>*>(p); };
    return &d;
  }
  std::shared_ptr<Surface> acquire(int width, int height) {
    std::lock_guard<std::mutex> lock(mutex);
    if (render_target && render_target->width == width && render_target->height == height) return render_target;
    auto slot = std::make_shared<Surface>();
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    check(worker().device->CreateTexture2D(&desc, nullptr, &slot->texture), "Cannot allocate D3D target");
    check(worker().device->CreateRenderTargetView(slot->texture.Get(), nullptr, &slot->target), "Cannot create D3D target view");
    slot->width = width; slot->height = height; render_target = slot;
    return slot;
  }
  std::shared_ptr<Surface> copy_for_flutter(const std::shared_ptr<Surface>& rendered) {
    auto slot = std::make_shared<Surface>();
    D3D11_TEXTURE2D_DESC desc{}; rendered->texture->GetDesc(&desc);
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    check(worker().device->CreateTexture2D(&desc, nullptr, &slot->texture), "Cannot allocate presentation texture");
    ComPtr<IDXGIResource> resource;
    check(slot->texture.As(&resource), "Cannot share D3D target");
    check(resource->GetSharedHandle(&slot->shared), "Cannot obtain DXGI handle");
    slot->width = rendered->width; slot->height = rendered->height;
    worker().context->CopyResource(slot->texture.Get(), rendered->texture.Get());
    return slot;
  }
};

class Plugin final : public flutter::Plugin {
 public:
  explicit Plugin(flutter::PluginRegistrarWindows* registrar) : registry_(registrar->texture_registrar()) {
    channel_ = std::make_unique<flutter::MethodChannel<V>>(registrar->messenger(),
        "space.tsukuyomi/live2d_gpu", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { handle(call, std::move(result)); });
  }
  ~Plugin() override {
    channel_->SetMethodCallHandler(nullptr);
    worker().drain();
    for (auto& entry : scenes_) retire(entry.second);
    worker().drain();
  }
 private:
  void retire(std::shared_ptr<Scene> s) {
    // The callback retains the TextureVariant until Flutter stops invoking it.
    if (s->registered.exchange(false)) registry_->UnregisterTexture(s->id, [s] {});
    worker().post([s] { s->close(); });
  }
  void handle(const flutter::MethodCall<V>& call, std::unique_ptr<flutter::MethodResult<V>> result) {
    auto reply = std::shared_ptr<flutter::MethodResult<V>>(std::move(result));
    try {
      M args = std::get<M>(*call.arguments());
      const std::string method = call.method_name();
      if (method == "create") {
        auto s = std::make_shared<Scene>();
        s->api = reinterpret_cast<const TsGpuApi*>(number(at(args, "nativeApi")));
        require(s->api && s->api->version == 1, "Native GPU ABI unavailable");
        s->texture = std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
            [weak = std::weak_ptr<Scene>(s)](size_t, size_t) {
              auto scene = weak.lock(); return scene ? scene->copy() : nullptr;
            }));
        s->id = registry_->RegisterTexture(s->texture.get());
        require(s->id >= 0, "Cannot register GPU texture");
        s->registered = true;
        { std::lock_guard<std::mutex> lock(scenes_mutex_); scenes_[s->id] = s; }
        worker().post([this, s, args, reply, registry = registry_] {
          try {
            auto start = std::chrono::steady_clock::now();
            worker().initialize();
            const auto& moc = std::get<std::vector<uint8_t>>(at(args, "moc"));
            const auto& physics = std::get<std::vector<uint8_t>>(at(args, "physics"));
            TsGpuInfo info{};
            s->model = s->api->create(moc.data(), static_cast<int32_t>(moc.size()),
                physics.data(), static_cast<int32_t>(physics.size()), worker().device.Get(), &info);
            require(s->model != nullptr, s->api->error());
            double init = micros(start);
            int limit = static_cast<int>(std::clamp<int64_t>(number(at(args, "maxTextureSize")), 1, 4096));
            int64_t atlas_bytes = 0;
            for (const auto& value : std::get<L>(at(args, "atlases"))) {
              const auto& atlas_data = std::get<M>(value);
              int width = static_cast<int>(number(at(atlas_data, "width")));
              int height = static_cast<int>(number(at(atlas_data, "height")));
              const auto& pixels = std::get<std::vector<uint8_t>>(at(atlas_data, "rgba"));
              require(width > 0 && height > 0 && width <= limit && height <= limit &&
                  pixels.size() == size_t(width) * height * 4, "Invalid decoded atlas");
              UINT w = static_cast<UINT>(width), h = static_cast<UINT>(height);
              D3D11_TEXTURE2D_DESC desc{};
              desc.Width = w; desc.Height = h; desc.ArraySize = 1; desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
              desc.SampleDesc.Count = 1; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
              desc.MiscFlags = D3D11_RESOURCE_MISC_GENERATE_MIPS;
              ComPtr<ID3D11Texture2D> texture; check(worker().device->CreateTexture2D(&desc, nullptr, &texture), "Cannot allocate atlas");
              worker().context->UpdateSubresource(texture.Get(), 0, nullptr, pixels.data(), w * 4, 0);
              ComPtr<ID3D11ShaderResourceView> view;
              check(worker().device->CreateShaderResourceView(texture.Get(), nullptr, &view), "Cannot create atlas view");
              worker().context->GenerateMips(view.Get());
              require(s->api->bind(s->model, static_cast<int32_t>(s->atlases.size()), view.Get()), s->api->error());
              s->atlases.push_back(view);
              for (;;) { atlas_bytes += int64_t(w) * h * 4; if (w == 1 && h == 1) break;
                w = std::max(1u, w / 2); h = std::max(1u, h / 2); }
            }
            reply->Success(V(M{{V("textureId"), V(s->id)}, {V("meshCount"), V(info.mesh_count)},
              {V("bounds"), V(L{V(info.bounds[0]), V(info.bounds[1]), V(info.bounds[2]), V(info.bounds[3])})},
              {V("maxSize"), V(4096)}, {V("atlasBytes"), V(atlas_bytes)}, {V("backend"), V("D3D11")},
              {V("loadMetrics"), V(M{{V("native_init_ms"), V(init / 1000)},
                {V("atlas_decode_upload_ms"), V((micros(start) - init) / 1000)}})}}));
          } catch (const std::exception& e) {
            s->close();
            if (s->registered.exchange(false)) registry->UnregisterTexture(s->id, [s] {});
            { std::lock_guard<std::mutex> lock(scenes_mutex_); scenes_.erase(s->id); }
            reply->Error("gpu", e.what());
          }
        });
        return;
      }
      std::unique_lock<std::mutex> lock(scenes_mutex_);
      auto found = scenes_.find(number(at(args, "id")));
      require(found != scenes_.end(), "Unknown renderer");
      auto s = found->second;
      if (method == "dispose") { scenes_.erase(found); retire(s); reply->Success(); return; }
      lock.unlock();
      if (method != "frame" && method != "snapshot") { reply->NotImplemented(); return; }
      worker().post([s, args, method, reply, registry = registry_] {
        try {
          require(s->model != nullptr, "Renderer disposed");
          if (method == "snapshot") {
            std::shared_ptr<Surface> front;
            { std::lock_guard<std::mutex> lock(s->mutex); front = s->front; }
            require(front != nullptr, "No completed GPU frame");
            D3D11_TEXTURE2D_DESC desc{}; front->texture->GetDesc(&desc);
            desc.BindFlags = desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            ComPtr<ID3D11Texture2D> staging;
            check(worker().device->CreateTexture2D(&desc, nullptr, &staging), "Cannot create QA target");
            worker().context->CopyResource(staging.Get(), front->texture.Get());
            D3D11_MAPPED_SUBRESOURCE map{};
            check(worker().context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &map), "Cannot read QA frame");
            std::vector<uint8_t> out(size_t(desc.Width) * desc.Height * 4);
            for (UINT y = 0; y < desc.Height; ++y) for (UINT x = 0; x < desc.Width; ++x) {
              auto* p = static_cast<const uint8_t*>(map.pData) + (desc.Height - 1 - y) * map.RowPitch + x * 4;
              auto* q = out.data() + (size_t(y) * desc.Width + x) * 4;
              q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = p[3];
            }
            worker().context->Unmap(staging.Get(), 0); reply->Success(V(out)); return;
          }
          int w = static_cast<int>(number(at(args, "width"))), h = static_cast<int>(number(at(args, "height")));
          require(w > 0 && h > 0 && w <= 4096 && h <= 4096 && int64_t(w) * h <= 8000000, "Invalid output size");
          auto surface = s->acquire(w, h);
          if (!surface) { reply->Success(V(M{{V("paused"), V(true)}})); return; }
          const auto& ids = std::get<L>(at(args, "ids"));
          const auto& values = std::get<std::vector<double>>(at(args, "values"));
          const auto& blends = std::get<std::vector<int32_t>>(at(args, "blends"));
          require(ids.size() <= 1024 && ids.size() == values.size() && ids.size() == blends.size(), "Invalid parameter batch");
          std::vector<const char*> names;
          for (const auto& id : ids) names.push_back(std::get<std::string>(id).c_str());
          TsGpuFrame frame{names.data(), values.data(), blends.data(), static_cast<int32_t>(ids.size()),
              w, h, std::get<double>(at(args, "delta")), worker().context.Get(), surface->target.Get()};
          double timing[2]{};
          require(s->api->draw(s->model, &frame, timing), s->api->error());
          auto submitted = std::chrono::steady_clock::now();
          // The public registrar exposes no consumer GPU fence. Keep published
          // images immutable; reuse only our private Cubism render target.
          auto published = s->copy_for_flutter(surface);
          D3D11_QUERY_DESC query_desc{D3D11_QUERY_EVENT, 0};
          ComPtr<ID3D11Query> fence;
          check(worker().device->CreateQuery(&query_desc, &fence), "Cannot create completion query");
          worker().context->End(fence.Get()); worker().context->Flush();
          HRESULT status;
          while ((status = worker().context->GetData(fence.Get(), nullptr, 0, 0)) == S_FALSE) {
            require(micros(submitted) < 2000000, "D3D GPU completion timed out");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
          }
          check(status, "D3D device lost");
          { std::lock_guard<std::mutex> lock(s->mutex); s->front = published; }
          registry->MarkTextureFrameAvailable(s->id);
          reply->Success(V(M{{V("width"), V(w)}, {V("height"), V(h)},
            {V("updateMicros"), V(timing[0])}, {V("submitMicros"), V(timing[1])},
            {V("presentMicros"), V(micros(submitted))}}));
        } catch (const std::exception& e) { reply->Error("gpu", e.what()); }
      });
    } catch (const std::exception& e) { reply->Error("gpu", e.what()); }
  }
  flutter::TextureRegistrar* registry_;
  std::unique_ptr<flutter::MethodChannel<V>> channel_;
  std::map<int64_t, std::shared_ptr<Scene>> scenes_;
  std::mutex scenes_mutex_;
};
}
void TsukuyomiLive2dPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<Plugin>(windows));
}
