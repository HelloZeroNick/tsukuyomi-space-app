#pragma once
#include <cstdint>

// Versioned, process-local ABI between the native asset and texture plugins.
// The native asset owns Cubism exactly once, including Canvas fallback models.
// All calls must run with the platform's device/context alive. No exceptions
// cross this boundary. Textures/targets remain owned by the platform plugin.
struct TsGpuInfo {
  double bounds[4];
  int32_t mesh_count;
};
struct TsGpuFrame {
  const char* const* ids;
  const double* values;
  const int32_t* blends;
  int32_t count, width, height;
  double delta;
  void* command;  // Metal command buffer / D3D immediate context / unused GL
  void* target;   // Metal render pass / D3D RTV / GLuint FBO cast to uintptr_t
};
struct TsGpuApi {
  uint32_t version;
  void* (*create)(const uint8_t*, int32_t, const uint8_t*, int32_t,
                  void* device, TsGpuInfo*);
  int32_t (*bind)(void*, int32_t index, void* texture);
  int32_t (*draw)(void*, const TsGpuFrame*, double* update_submit_micros);
  void (*destroy)(void*);
  const char* (*error)();
};
