// Android-only part of bridge.cpp. All entry points run on one render worker.
// EGL presents directly to Flutter's SurfaceProducer; no per-frame readback.
#include <jni.h>
#include <EGL/egl.h>
#include <android/native_window_jni.h>
#include <android/bitmap.h>
#include <chrono>
#include <stdexcept>
#include <vector>
#include <limits>
#include "Rendering/OpenGL/CubismRenderer_OpenGLES2.hpp"
using Rendering::CubismRenderer;
using Rendering::CubismRenderer_OpenGLES2;

namespace {
struct GpuDevice {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface parking = EGL_NO_SURFACE;
  EGLConfig config = nullptr;
  int users = 0;
  void current(EGLSurface surface) {
    if (!eglMakeCurrent(display, surface, surface, context))
      throw std::runtime_error("EGL context lost or surface unavailable");
  }
  void close() {
    if (display != EGL_NO_DISPLAY) {
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (parking != EGL_NO_SURFACE) eglDestroySurface(display, parking);
      if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
      // Flutter/plugins may use the same default display. Retain our one
      // process-lifetime initialization; release only our context/surfaces.
    }
    context = EGL_NO_CONTEXT; parking = EGL_NO_SURFACE;
  }
  void acquire() {
    if (users) { current(parking); ++users; return; }
    try {
      if (display == EGL_NO_DISPLAY) {
        EGLDisplay candidate = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (candidate == EGL_NO_DISPLAY || !eglInitialize(candidate, nullptr, nullptr))
          throw std::runtime_error("Cannot initialize EGL");
        display = candidate;
      }
      const EGLint attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE};
      EGLint count = 0;
      if (!eglChooseConfig(display, attrs, &config, 1, &count) || count != 1)
        throw std::runtime_error("No transparent EGL config");
      const EGLint version[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
      context = eglCreateContext(display, config, EGL_NO_CONTEXT, version);
      const EGLint tiny[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      parking = eglCreatePbufferSurface(display, config, tiny);
      if (context == EGL_NO_CONTEXT || parking == EGL_NO_SURFACE)
        throw std::runtime_error("Cannot create GLES2 context");
      current(parking);
      users = 1;
    } catch (...) { close(); throw; }
  }
  void release() {
    if (--users == 0) {
      // SDK shader programs are global, shared by all scenes on this context.
      CubismRenderer::StaticRelease();
      close();
    }
  }
} gpu_device;

struct GpuScene {
  Scene* scene = nullptr;
  CubismRenderer_OpenGLES2* renderer = nullptr;
  std::vector<GLuint> textures;
  ANativeWindow* window = nullptr;
  EGLSurface surface = EGL_NO_SURFACE;
  float left = 0, top = 0, right = 0, bottom = 0;
  bool acquired = false;
  int width = 1, height = 1;
  void detach() {
    if (surface != EGL_NO_SURFACE) {
      gpu_device.current(gpu_device.parking);
      eglDestroySurface(gpu_device.display, surface);
      surface = EGL_NO_SURFACE;
    }
    if (window) { ANativeWindow_release(window); window = nullptr; }
  }
  ~GpuScene() {
    // The caller keeps a valid current context even after the output surface
    // has been released in the background. Context loss triggers Dart fallback.
    if (acquired) {
      eglMakeCurrent(gpu_device.display, gpu_device.parking,
                     gpu_device.parking, gpu_device.context);
      if (renderer) CubismRenderer::Delete(renderer);
      if (!textures.empty()) glDeleteTextures(textures.size(), textures.data());
      if (surface != EGL_NO_SURFACE) eglDestroySurface(gpu_device.display, surface);
      if (window) ANativeWindow_release(window);
      // ts_destroy may release Framework statics, so do it while GL is current.
      ts_destroy(scene);
      gpu_device.release();
    }
  }
  void draw() {
    if (surface == EGL_NO_SURFACE) throw std::runtime_error("No output surface");
    gpu_device.current(surface);
    if (!eglQuerySurface(gpu_device.display, surface, EGL_WIDTH, &width) ||
        !eglQuerySurface(gpu_device.display, surface, EGL_HEIGHT, &height) ||
        width <= 0 || height <= 0) throw std::runtime_error("Invalid output size");
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, width, height);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    const float scale = .94f * std::min(width / (right - left), height / (bottom - top));
    float matrix[16] = {};
    matrix[0] = 2 * scale / width;
    matrix[5] = 2 * scale / height;
    matrix[10] = matrix[15] = 1;
    matrix[12] = -(left + right) * scale / width;
    matrix[13] = (top + bottom) * scale / height;
    CubismMatrix44 mvp;
    mvp.SetMatrix(matrix);
    renderer->SetMvpMatrix(&mvp);
    renderer->SetRenderTargetSize(width, height);
    renderer->DrawModel();
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Cubism GLES draw failed");
  }
};
void gpu_error(JNIEnv* env, const std::exception& e) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), e.what());
}
std::vector<uint8_t> java_bytes(JNIEnv* env, jbyteArray data) {
  if (!data) return {};
  std::vector<uint8_t> bytes(env->GetArrayLength(data));
  env->GetByteArrayRegion(data, 0, bytes.size(), reinterpret_cast<jbyte*>(bytes.data()));
  return bytes;
}
using Clock = std::chrono::steady_clock;
double micros(Clock::time_point start, Clock::time_point end) {
  return std::chrono::duration<double, std::micro>(end - start).count();
}
}
#define JNI_GPU(name) extern "C" JNIEXPORT name JNICALL
#define GPU_METHOD(name) Java_space_tsukuyomi_live2d_Live2DGpu_##name

JNI_GPU(jlong) GPU_METHOD(nativeCreate)(JNIEnv* env, jobject, jbyteArray moc, jbyteArray physics) {
  TS_LOCK;
  auto* value = new GpuScene;
  try {
    gpu_device.acquire(); value->acquired = true;
    const auto m = java_bytes(env, moc), p = java_bytes(env, physics);
    value->scene = static_cast<Scene*>(ts_create(m.data(), m.size(), p.data(), p.size()));
    if (!value->scene) throw std::runtime_error("Unsupported Cubism model");
    ts_begin(value->scene);
    ts_parameter(value->scene, "ParamAngleY", 2, 0);
    ts_parameter(value->scene, "ParamBreath", .5f, 0);
    ts_parameter(value->scene, "ParamEyeLOpen", 1, 0);
    ts_parameter(value->scene, "ParamEyeROpen", 1, 0);
    ts_parameter(value->scene, "ParamMouthOpenY", 0, 0);
    ts_update(value->scene, 1.f / 60);
    auto* model = value->scene->model;
    value->left = value->top = std::numeric_limits<float>::infinity();
    value->right = value->bottom = -std::numeric_limits<float>::infinity();
    for (int i = 0; i < model->GetDrawableCount(); ++i) {
      if (!model->GetDrawableDynamicFlagIsVisible(i) || model->GetDrawableOpacity(i) <= .01f) continue;
      const auto* v = model->GetDrawableVertices(i);
      for (int j = 0; j < model->GetDrawableVertexCount(i) * 2; j += 2) {
        value->left = std::min(value->left, v[j]); value->right = std::max(value->right, v[j]);
        value->top = std::min(value->top, -v[j + 1]); value->bottom = std::max(value->bottom, -v[j + 1]);
      }
    }
    if (!(value->right > value->left && value->bottom > value->top))
      throw std::runtime_error("Model has no visible bounds");
    value->renderer = static_cast<CubismRenderer_OpenGLES2*>(CubismRenderer::Create(1, 1));
    value->renderer->Initialize(model);
    value->renderer->IsPremultipliedAlpha(true);
    value->renderer->UseHighPrecisionMask(false);
    value->renderer->SetDrawableClippingMaskBufferSize(512, 512);
    return reinterpret_cast<jlong>(value);
  } catch (const std::exception& e) { delete value; gpu_error(env, e); return 0; }
}
JNI_GPU(jdoubleArray) GPU_METHOD(nativeInfo)(JNIEnv* env, jobject, jlong handle) {
  TS_LOCK;
  auto* s = reinterpret_cast<GpuScene*>(handle);
  GLint limit = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &limit);
  const double data[] = {s->left, s->top, s->right, s->bottom,
    static_cast<double>(s->scene->model->GetDrawableCount()), static_cast<double>(limit)};
  auto result = env->NewDoubleArray(6); env->SetDoubleArrayRegion(result, 0, 6, data); return result;
}
JNI_GPU(void) GPU_METHOD(nativeTexture)(JNIEnv* env, jobject, jlong handle, jint index, jobject bitmap) {
  TS_LOCK;
  auto* s = reinterpret_cast<GpuScene*>(handle);
  try {
    gpu_device.current(gpu_device.parking);
    AndroidBitmapInfo info{};
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.stride != info.width * 4 ||
        index != static_cast<int>(s->textures.size())) throw std::runtime_error("Invalid atlas bitmap");
    void* pixels = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS)
      throw std::runtime_error("Cannot read atlas bitmap");
    GLuint texture = 0; glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, info.width, info.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    AndroidBitmap_unlockPixels(env, bitmap);
    if (glGetError() != GL_NO_ERROR) { glDeleteTextures(1, &texture); throw std::runtime_error("Cannot upload atlas"); }
    s->textures.push_back(texture); s->renderer->BindTexture(index, texture);
  } catch (const std::exception& e) { gpu_error(env, e); }
}
JNI_GPU(void) GPU_METHOD(nativeSurface)(JNIEnv* env, jobject, jlong handle, jobject surface) {
  TS_LOCK;
  auto* s = reinterpret_cast<GpuScene*>(handle);
  try {
    s->detach();
    if (!surface) return;
    s->window = ANativeWindow_fromSurface(env, surface);
    if (!s->window) throw std::runtime_error("Invalid Android surface");
    s->surface = eglCreateWindowSurface(gpu_device.display, gpu_device.config, s->window, nullptr);
    if (s->surface == EGL_NO_SURFACE) throw std::runtime_error("Cannot bind Flutter surface");
    gpu_device.current(s->surface);
    eglSwapInterval(gpu_device.display, 0);
  } catch (const std::exception& e) { gpu_error(env, e); }
}
JNI_GPU(jdoubleArray) GPU_METHOD(nativeFrame)(JNIEnv* env, jobject, jlong handle,
    jobjectArray ids, jdoubleArray values, jintArray blends, jdouble delta) {
  TS_LOCK;
  auto* s = reinterpret_cast<GpuScene*>(handle);
  try {
    auto start = Clock::now();
    const int count = env->GetArrayLength(ids);
    if (env->GetArrayLength(values) != count || env->GetArrayLength(blends) != count || count > 1024)
      throw std::runtime_error("Invalid parameter batch");
    std::vector<double> v(count); std::vector<jint> b(count);
    env->GetDoubleArrayRegion(values, 0, count, v.data());
    env->GetIntArrayRegion(blends, 0, count, b.data());
    ts_begin(s->scene);
    for (int i = 0; i < count; ++i) {
      auto id = static_cast<jstring>(env->GetObjectArrayElement(ids, i));
      const char* text = env->GetStringUTFChars(id, nullptr);
      ts_parameter(s->scene, text, v[i], b[i]);
      env->ReleaseStringUTFChars(id, text); env->DeleteLocalRef(id);
    }
    ts_update(s->scene, delta);
    auto updated = Clock::now();
    s->draw(); auto submitted = Clock::now();
    if (!eglSwapBuffers(gpu_device.display, s->surface)) throw std::runtime_error("EGL presentation failed");
    const double data[] = {micros(start, updated), micros(updated, submitted),
      micros(submitted, Clock::now()), static_cast<double>(s->width), static_cast<double>(s->height)};
    auto result = env->NewDoubleArray(5); env->SetDoubleArrayRegion(result, 0, 5, data); return result;
  } catch (const std::exception& e) { gpu_error(env, e); return nullptr; }
}
// Explicit QA readback only; the production animation loop never calls this.
JNI_GPU(jbyteArray) GPU_METHOD(nativeSnapshot)(JNIEnv* env, jobject, jlong handle) {
  TS_LOCK;
  try {
    auto* s = reinterpret_cast<GpuScene*>(handle); s->draw();
    std::vector<uint8_t> pixels(static_cast<size_t>(s->width) * s->height * 4);
    glReadPixels(0, 0, s->width, s->height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("QA readback failed");
    auto result = env->NewByteArray(pixels.size());
    env->SetByteArrayRegion(result, 0, pixels.size(), reinterpret_cast<jbyte*>(pixels.data()));
    return result;
  } catch (const std::exception& e) { gpu_error(env, e); return nullptr; }
}
JNI_GPU(void) GPU_METHOD(nativeDestroy)(JNIEnv*, jobject, jlong handle) {
  TS_LOCK; delete reinterpret_cast<GpuScene*>(handle);
}
