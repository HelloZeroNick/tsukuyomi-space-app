// Included by bridge.cpp. Platform plugins own GPU devices and external
// textures; this adapter owns the official renderer and serialized Cubism state.
#include "gpu_api.h"
#include <chrono>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <map>

#if defined(TS_GPU_METAL)
#include "Rendering/Metal/CubismRenderer_Metal.hpp"
using PlatformRenderer = Rendering::CubismRenderer_Metal;
#elif defined(TS_GPU_D3D11)
#include "Rendering/D3D11/CubismRenderer_D3D11.hpp"
using PlatformRenderer = Rendering::CubismRenderer_D3D11;
#else
#include "Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp"
using PlatformRenderer = Rendering::CubismRenderer_OpenGLES2;
#endif

namespace {
thread_local std::string gpu_last_error;
int gpu_instances = 0;
struct NativeGpuScene {
  Scene* model = nullptr;
  PlatformRenderer* renderer = nullptr;
  TsGpuInfo info{};
#if defined(CSM_TARGET_LINUX_GL)
  GLuint vao = 0, indices = 0;
  std::map<GLuint, GLuint> vertices;
#endif
  ~NativeGpuScene() {
    if (renderer) {
      Rendering::CubismRenderer::Delete(renderer);
      if (--gpu_instances == 0) {
#if defined(TS_GPU_METAL)
        Rendering::CubismDeviceInfo_Metal::ReleaseAllDeviceInfo();
#else
        Rendering::CubismRenderer::StaticRelease();
#endif
      }
    }
#if defined(CSM_TARGET_LINUX_GL)
    for (auto v : vertices) glDeleteBuffers(1, &v.second);
    if (indices) glDeleteBuffers(1, &indices);
    if (vao) glDeleteVertexArrays(1, &vao);
#endif
    // Final Framework cleanup must happen while its GPU context is current.
    ts_destroy(model);
  }
};
#if defined(CSM_TARGET_LINUX_GL)
thread_local NativeGpuScene* drawing_scene = nullptr;
#endif
void* gpu_create(const uint8_t* moc, int32_t size, const uint8_t* physics,
                 int32_t physics_size, void* device, TsGpuInfo* info) {
  TS_LOCK;
  try {
    auto s = std::make_unique<NativeGpuScene>();
    s->model = static_cast<Scene*>(ts_create(moc, size, physics, physics_size));
    if (!s->model) throw std::runtime_error("Unsupported Cubism model");
    ts_begin(s->model);
    ts_parameter(s->model, "ParamAngleY", 2, 0);
    ts_parameter(s->model, "ParamBreath", .5f, 0);
    ts_parameter(s->model, "ParamEyeLOpen", 1, 0);
    ts_parameter(s->model, "ParamEyeROpen", 1, 0);
    ts_parameter(s->model, "ParamMouthOpenY", 0, 0);
    ts_update(s->model, 1.f / 60);
    auto* model = s->model->model;
    double* b = s->info.bounds;
    b[0] = b[1] = std::numeric_limits<double>::infinity();
    b[2] = b[3] = -std::numeric_limits<double>::infinity();
    for (int i = 0; i < model->GetDrawableCount(); ++i) {
      if (!model->GetDrawableDynamicFlagIsVisible(i) ||
          model->GetDrawableOpacity(i) <= .01f) continue;
      const float* v = model->GetDrawableVertices(i);
      for (int j = 0; j < model->GetDrawableVertexCount(i) * 2; j += 2) {
        b[0] = std::min(b[0], double(v[j]));
        b[2] = std::max(b[2], double(v[j]));
        b[1] = std::min(b[1], double(-v[j + 1]));
        b[3] = std::max(b[3], double(-v[j + 1]));
      }
    }
    if (!(b[2] > b[0] && b[3] > b[1]))
      throw std::runtime_error("Model has no visible bounds");
#if defined(TS_GPU_METAL)
    PlatformRenderer::SetConstantSettings((id<MTLDevice>)device, 1);
#elif defined(TS_GPU_D3D11)
    PlatformRenderer::SetConstantSettings(1, static_cast<ID3D11Device*>(device));
#else
    (void)device;
#endif
    s->renderer = static_cast<PlatformRenderer*>(Rendering::CubismRenderer::Create(1, 1));
    ++gpu_instances;
    s->renderer->Initialize(model);
    s->renderer->IsPremultipliedAlpha(true);
    s->renderer->UseHighPrecisionMask(false);
#if defined(TS_GPU_METAL)
    s->renderer->SetDrawbleClippingMaskBufferSize(512, 512);
#else
    s->renderer->SetDrawableClippingMaskBufferSize(512, 512);
#endif
    s->info.mesh_count = model->GetDrawableCount();
    *info = s->info;
    return s.release();
  } catch (const std::exception& e) { gpu_last_error = e.what(); return nullptr; }
}
int32_t gpu_bind(void* handle, int32_t index, void* texture) {
  TS_LOCK;
  if (!handle || !texture || index < 0) { gpu_last_error = "Invalid atlas"; return 0; }
  auto* s = static_cast<NativeGpuScene*>(handle);
#if defined(TS_GPU_METAL)
  s->renderer->BindTexture(index, (id<MTLTexture>)texture);
#elif defined(TS_GPU_D3D11)
  s->renderer->BindTexture(index, static_cast<ID3D11ShaderResourceView*>(texture));
#else
  s->renderer->BindTexture(index, static_cast<GLuint>(reinterpret_cast<uintptr_t>(texture)));
#endif
  return 1;
}
int32_t gpu_draw(void* handle, const TsGpuFrame* f, double* metrics) {
  TS_LOCK;
  try {
    if (!handle || !f || f->count < 0 || f->count > 1024 ||
        f->width < 1 || f->height < 1 || f->width > 4096 || f->height > 4096 ||
        int64_t(f->width) * f->height > 8000000 ||
        !std::isfinite(f->delta) ||
        (f->count && (!f->ids || !f->values || !f->blends)))
      throw std::runtime_error("Invalid GPU frame");
    using Clock = std::chrono::steady_clock;
    auto start = Clock::now();
    auto* s = static_cast<NativeGpuScene*>(handle);
    ts_begin(s->model);
    for (int i = 0; i < f->count; ++i)
      ts_parameter(s->model, f->ids[i], f->values[i], f->blends[i]);
    ts_update(s->model, f->delta);
    auto updated = Clock::now();
    const double* b = s->info.bounds;
    const double scale = .94 * std::min(f->width / (b[2] - b[0]),
                                      f->height / (b[3] - b[1]));
    float matrix[16] = {};
    matrix[0] = 2 * scale / f->width;
    matrix[5] = 2 * scale / f->height;
    matrix[10] = matrix[15] = 1;
    matrix[12] = -(b[0] + b[2]) * scale / f->width;
    matrix[13] = (b[1] + b[3]) * scale / f->height;
#if defined(CSM_TARGET_LINUX_GL)
    // Flutter imports GL textures with a top-left image origin.
    matrix[5] = -matrix[5]; matrix[13] = -matrix[13];
    if (!s->vao) glGenVertexArrays(1, &s->vao);
    glBindVertexArray(s->vao);
    drawing_scene = s;
#endif
    CubismMatrix44 mvp;
    mvp.SetMatrix(matrix);
    s->renderer->SetMvpMatrix(&mvp);
    s->renderer->SetRenderTargetSize(f->width, f->height);
#if defined(TS_GPU_METAL)
    s->renderer->StartFrame((id<MTLCommandBuffer>)f->command,
                            (MTLRenderPassDescriptor*)f->target);
    s->renderer->SetRenderViewport({0, 0, double(f->width), double(f->height), 0, 1});
#elif defined(TS_GPU_D3D11)
    auto* context = static_cast<ID3D11DeviceContext*>(f->command);
    auto* target = static_cast<ID3D11RenderTargetView*>(f->target);
    context->OMSetRenderTargets(1, &target, nullptr);
    const float clear[4] = {};
    context->ClearRenderTargetView(target, clear);
    D3D11_VIEWPORT viewport{0, 0, float(f->width), float(f->height), 0, 1};
    context->RSSetViewports(1, &viewport);
    s->renderer->StartFrame(context);
#else
    glBindFramebuffer(GL_FRAMEBUFFER, static_cast<GLuint>(reinterpret_cast<uintptr_t>(f->target)));
    glViewport(0, 0, f->width, f->height);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
#endif
    s->renderer->DrawModel();
#if defined(TS_GPU_D3D11)
    s->renderer->EndFrame();
#elif !defined(TS_GPU_METAL)
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Cubism OpenGL draw failed");
#endif
    metrics[0] = std::chrono::duration<double, std::micro>(updated - start).count();
    metrics[1] = std::chrono::duration<double, std::micro>(Clock::now() - updated).count();
    return 1;
  } catch (const std::exception& e) { gpu_last_error = e.what(); return 0; }
}
void gpu_destroy(void* handle) { TS_LOCK; delete static_cast<NativeGpuScene*>(handle); }
const char* gpu_error_text() { return gpu_last_error.c_str(); }
const TsGpuApi gpu_api{1, gpu_create, gpu_bind, gpu_draw, gpu_destroy, gpu_error_text};
}
API const TsGpuApi* ts_gpu_api() { return &gpu_api; }

#if defined(CSM_TARGET_LINUX_GL)
void ts_gl_vertex(GLuint attribute, int vertices, const float* data) {
  GLuint& buffer = drawing_scene->vertices[attribute];
  if (!buffer) glGenBuffers(1, &buffer);
  glBindBuffer(GL_ARRAY_BUFFER, buffer);
  glBufferData(GL_ARRAY_BUFFER, vertices * 2 * sizeof(float), data, GL_STREAM_DRAW);
  glVertexAttribPointer(attribute, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
}
void ts_gl_indices(GLsizei count, const void* data) {
  if (!drawing_scene->indices) glGenBuffers(1, &drawing_scene->indices);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, drawing_scene->indices);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, count * sizeof(uint16_t), data, GL_STREAM_DRAW);
  glDrawElements(GL_TRIANGLES, count, GL_UNSIGNED_SHORT, nullptr);
}
#endif
