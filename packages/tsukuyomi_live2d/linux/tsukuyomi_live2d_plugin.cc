#include "include/tsukuyomi_live2d/tsukuyomi_live2d_plugin.h"
#include "../src/gpu_api.h"
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <algorithm>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

namespace {
std::mutex share_mutex;
EGLContext shader_share = EGL_NO_CONTEXT;
int shared_scenes = 0;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
FlValue* at(FlValue* args, const char* key) {
  auto* value = fl_value_lookup_string(args, key);
  require(value != nullptr, "Missing GPU argument"); return value;
}
void put(FlValue* map, const char* key, FlValue* value) { fl_value_set_string_take(map, key, value); }
// Flutter 3.47 renders in EGL, while GTK on X11 can still use GLX. Save the
// actual EGL context, not GDK's unrelated thread-local paint context.
struct Current {
  EGLenum previous_api = eglQueryAPI();
  EGLDisplay display, previous_display = eglGetCurrentDisplay();
  EGLContext previous = eglGetCurrentContext();
  EGLSurface draw = eglGetCurrentSurface(EGL_DRAW), read = eglGetCurrentSurface(EGL_READ);
  GLXContext glx = glXGetCurrentContext();
  Display* glx_display = glXGetCurrentDisplay();
  GLXDrawable glx_draw = glXGetCurrentDrawable(), glx_read = glXGetCurrentReadDrawable();
  explicit Current(EGLDisplay d, EGLContext context) : display(d) {
    // GTK's platform thread can own a GLX context and a different bound EGL
    // API. Release that binding during diagnostics/teardown, then restore it.
    if (glx) require(glXMakeContextCurrent(glx_display, None, None, nullptr),
        "Cannot release GTK GLX context");
    eglBindAPI(EGL_OPENGL_ES_API);
    if (!eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
      auto code = eglGetError();
      restore();
      throw std::runtime_error("Cannot acquire shared EGL context: " + std::to_string(code));
    }
  }
  void restore() {
    // Explicitly unbind our ES context before restoring another client API;
    // otherwise it can remain current to this thread and reject the next one.
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglBindAPI(previous_api);
    if (previous != EGL_NO_CONTEXT && !eglMakeCurrent(previous_display, draw, read, previous))
      g_warning("Live2D could not restore Flutter EGL context: %d", eglGetError());
    if (glx) glXMakeContextCurrent(glx_display, glx_draw, glx_read, glx);
  }
  ~Current() { restore(); }
};
struct Reply { FlMethodCall* call; FlValue* value; std::string error; };
void respond(FlMethodCall* call, FlValue* value, const std::string& error = {}) {
  auto* reply = new Reply{FL_METHOD_CALL(g_object_ref(call)), value, error};
  g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer data) -> gboolean {
    auto* r = static_cast<Reply*>(data);
    if (r->error.empty()) fl_method_call_respond_success(r->call, r->value, nullptr);
    else fl_method_call_respond_error(r->call, "gpu", r->error.c_str(), nullptr, nullptr);
    return G_SOURCE_REMOVE;
  }, reply, [](gpointer data) {
    auto* r = static_cast<Reply*>(data);
    g_object_unref(r->call); if (r->value) fl_value_unref(r->value); delete r;
  });
}
struct State {
  std::mutex mutex;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  FlValue* pending_atlases = nullptr;
  const TsGpuApi* api = nullptr;
  void* model = nullptr;
  GLuint target = 0, color = 0;
  int width = 0, height = 0;
  std::vector<GLuint> atlases;
  FlMethodCall* pending = nullptr;
  bool closed = false;
  void finish(FlValue* value, const std::string& error = {}) {
    if (pending) { respond(pending, value, error); g_object_unref(pending); pending = nullptr; }
    else if (value) fl_value_unref(value);
  }
  void close() {
    closed = true; finish(nullptr, "Renderer disposed");
    if (context != EGL_NO_CONTEXT) {
      // Registrar destruction happens before the engine's EGL display teardown.
      Current current(display, context);
      if (model) { api->destroy(model); model = nullptr; }
      if (target) glDeleteFramebuffers(1, &target);
      if (color) glDeleteTextures(1, &color);
      if (!atlases.empty()) glDeleteTextures(static_cast<GLsizei>(atlases.size()), atlases.data());
    } else if (model) {
      api->destroy(model); model = nullptr; // No GPU resources before first populate.
    }
    if (context != EGL_NO_CONTEXT) {
      eglDestroyContext(display, context); context = EGL_NO_CONTEXT;
      std::lock_guard<std::mutex> shared_lock(share_mutex);
      if (--shared_scenes == 0) shader_share = EGL_NO_CONTEXT;
    }
    target = color = 0; atlases.clear();
    if (pending_atlases) { fl_value_unref(pending_atlases); pending_atlases = nullptr; }
  }
  ~State() {
    std::lock_guard<std::mutex> lock(mutex);
    // close() normally runs before unregistering, while the EGL display lives.
    try { close(); } catch (const std::exception& e) { g_warning("Live2D teardown: %s", e.what()); }
  }
};
}
typedef struct _TsTexture { FlTextureGL parent; State* state; } TsTexture;
typedef struct _TsTextureClass { FlTextureGLClass parent; } TsTextureClass;
G_DEFINE_TYPE(TsTexture, ts_texture, fl_texture_gl_get_type())
static gboolean populate(FlTextureGL* texture, uint32_t* target, uint32_t* name,
                         uint32_t* width, uint32_t* height, GError** error) {
  auto* s = reinterpret_cast<TsTexture*>(texture)->state;
  std::lock_guard<std::mutex> lock(s->mutex);
  // The pinned Linux embedder dereferences GError whenever populate returns
  // FALSE. The widget can be painted before Dart's post-frame size callback.
  if (s->closed || !s->model) {
    g_set_error_literal(error, g_quark_from_static_string("ts-live2d"), 1,
        "Live2D is waiting for its first frame or has been disposed");
    return FALSE;
  }
  if (!s->pending && s->color) {
    *target = GL_TEXTURE_2D; *name = s->color; *width = s->width; *height = s->height;
    return TRUE;
  }
  try {
    if (s->context == EGL_NO_CONTEXT) {
      s->display = eglGetCurrentDisplay();
      EGLContext shared = eglGetCurrentContext();
      require(s->display != EGL_NO_DISPLAY && shared != EGL_NO_CONTEXT, "Flutter EGL context unavailable");
      std::lock_guard<std::mutex> shared_lock(share_mutex);
      // The SDK's shader singleton may only be reused within one share group.
      require(shader_share == EGL_NO_CONTEXT || shader_share == shared,
          "Another Flutter engine owns Cubism EGL resources");
      EGLint config_id = 0, count = 0;
      require(eglQueryContext(s->display, shared, EGL_CONFIG_ID, &config_id), "Cannot query Flutter EGL config");
      EGLint attributes[] = {EGL_CONFIG_ID, config_id, EGL_NONE};
      EGLConfig config = nullptr;
      require(eglChooseConfig(s->display, attributes, &config, 1, &count) && count == 1, "Cannot share Flutter EGL config");
      const EGLint options[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
      s->context = eglCreateContext(s->display, config, shared, options);
      require(s->context != EGL_NO_CONTEXT, "Cannot create shared EGL context");
      shader_share = shared; ++shared_scenes;
    }
    // The embedder exposes no consumer fence. Finish previous Flutter reads
    // before overwriting its shared image, then restore its context on return.
    glFinish();
    Current current(s->display, s->context);
    if (s->pending_atlases) {
      GLint max_size = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_size);
      for (size_t i = 0; i < fl_value_get_length(s->pending_atlases); ++i) {
        auto* atlas_data = fl_value_get_list_value(s->pending_atlases, i);
        int w = static_cast<int>(fl_value_get_int(at(atlas_data, "width")));
        int h = static_cast<int>(fl_value_get_int(at(atlas_data, "height")));
        require(w <= max_size && h <= max_size, "Atlas exceeds GPU texture limit");
        auto* rgba = at(atlas_data, "rgba");
        GLuint atlas = 0; glGenTextures(1, &atlas); s->atlases.push_back(atlas);
        glBindTexture(GL_TEXTURE_2D, atlas);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, fl_value_get_uint8_list(rgba));
        glGenerateMipmap(GL_TEXTURE_2D);
        require(glGetError() == GL_NO_ERROR, "Cannot upload atlas");
        if (!s->api->bind(s->model, static_cast<int32_t>(i), reinterpret_cast<void*>(uintptr_t(atlas)))) throw std::runtime_error(s->api->error());
      }
      fl_value_unref(s->pending_atlases); s->pending_atlases = nullptr;
    }
    if (!s->pending && !s->color) {
      // Publish a valid transparent image before Dart knows the layout. A
      // failed first import can leave Flutter's retained tree without an image
      // for subsequent texture-only frames to repaint.
      glGenTextures(1, &s->color);
      glBindTexture(GL_TEXTURE_2D, s->color);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      const uint8_t transparent[4] = {};
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA,
          GL_UNSIGNED_BYTE, transparent);
      s->width = s->height = 1;
      glFinish();
    }
    if (s->pending) {
      FlValue* args = fl_method_call_get_args(s->pending);
      int w = static_cast<int>(fl_value_get_int(at(args, "width")));
      int h = static_cast<int>(fl_value_get_int(at(args, "height")));
      require(w > 0 && h > 0 && w <= 4096 && h <= 4096 && int64_t(w) * h <= 8000000, "Invalid output size");
      if (w != s->width || h != s->height) {
        if (!s->color) glGenTextures(1, &s->color);
        glBindTexture(GL_TEXTURE_2D, s->color);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        if (!s->target) glGenFramebuffers(1, &s->target);
        glBindFramebuffer(GL_FRAMEBUFFER, s->target);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s->color, 0);
        require(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "Incomplete output framebuffer");
        s->width = w; s->height = h;
      }
      auto* ids = at(args, "ids"); auto* values = at(args, "values"); auto* blends = at(args, "blends");
      size_t count = fl_value_get_length(ids);
      require(count <= 1024 && count == fl_value_get_length(values) && count == fl_value_get_length(blends), "Invalid parameter batch");
      std::vector<const char*> names;
      for (size_t i = 0; i < count; ++i) names.push_back(fl_value_get_string(fl_value_get_list_value(ids, i)));
      TsGpuFrame frame{names.data(), fl_value_get_float_list(values), fl_value_get_int32_list(blends),
        static_cast<int32_t>(count), w, h, fl_value_get_float(at(args, "delta")),
        nullptr, reinterpret_cast<void*>(uintptr_t(s->target))};
      double timing[2]{};
      if (!s->api->draw(s->model, &frame, timing)) throw std::runtime_error(s->api->error());
      // The next Flutter sample occurs on this same raster thread. Complete
      // producer commands before returning a shared texture from our context.
      auto start = std::chrono::steady_clock::now();
      glFinish();
      double present = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
      FlValue* result = fl_value_new_map();
      put(result, "width", fl_value_new_int(w)); put(result, "height", fl_value_new_int(h));
      put(result, "updateMicros", fl_value_new_float(timing[0]));
      put(result, "submitMicros", fl_value_new_float(timing[1]));
      put(result, "presentMicros", fl_value_new_float(present));
      s->finish(result);
    }
    require(s->color != 0, "No completed Live2D frame");
    *target = GL_TEXTURE_2D; *name = s->color; *width = s->width; *height = s->height;
    return TRUE;
  } catch (const std::exception& e) {
    s->finish(nullptr, e.what());
    g_set_error_literal(error, g_quark_from_static_string("ts-live2d"), 1, e.what());
    return FALSE;
  }
}
static void ts_texture_finalize(GObject* object) {
  delete reinterpret_cast<TsTexture*>(object)->state;
  G_OBJECT_CLASS(ts_texture_parent_class)->finalize(object);
}
static void ts_texture_class_init(TsTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = populate;
  G_OBJECT_CLASS(klass)->finalize = ts_texture_finalize;
}
static void ts_texture_init(TsTexture* self) { self->state = new State; }

namespace {
struct Plugin {
  FlTextureRegistrar* registry;
  std::map<int64_t, TsTexture*> scenes;
  bool closed = false;
  void close() {
    if (closed) return;
    closed = true;
    for (auto& entry : scenes) {
      { std::lock_guard<std::mutex> lock(entry.second->state->mutex);
        try { entry.second->state->close(); }
        catch (const std::exception& e) { g_warning("Live2D teardown: %s", e.what()); } }
      fl_texture_registrar_unregister_texture(registry, FL_TEXTURE(entry.second));
      g_object_unref(entry.second);
    }
    scenes.clear();
  }
  ~Plugin() {
    close();
    g_object_unref(registry);
  }
};
struct CreateWork {
  FlMethodCall* call;
  std::shared_ptr<Plugin> plugin;
  ~CreateWork() { g_object_unref(call); }
};
void handle(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto plugin = *static_cast<std::shared_ptr<Plugin>*>(user_data);
  try {
    require(!plugin->closed, "Renderer closed");
    std::string method = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    if (method == "create") {
      auto* texture = reinterpret_cast<TsTexture*>(g_object_new(ts_texture_get_type(), nullptr));
      auto* s = texture->state;
      try {
        s->api = reinterpret_cast<const TsGpuApi*>(fl_value_get_int(at(args, "nativeApi")));
        require(s->api && s->api->version == 1, "Native GPU ABI unavailable");
        require(fl_texture_registrar_register_texture(plugin->registry, FL_TEXTURE(texture)), "Cannot register GL texture");
      } catch (...) { g_object_unref(texture); throw; }
      int64_t id = fl_texture_get_id(FL_TEXTURE(texture));
      plugin->scenes[id] = texture;
      // Evaluate model bounds on the worker pool. EGL resources are created only
      // when Flutter first consumes this texture on its raster thread.
      auto* task = g_task_new(texture, nullptr, nullptr, nullptr);
      g_task_set_task_data(task, new CreateWork{FL_METHOD_CALL(g_object_ref(call)), plugin},
          [](gpointer p) { delete static_cast<CreateWork*>(p); });
      g_task_run_in_thread(task, [](GTask* task, gpointer object, gpointer data, GCancellable*) {
        auto* t = reinterpret_cast<TsTexture*>(object);
        auto* work = static_cast<CreateWork*>(data);
        auto* state = t->state; auto* request = work->call;
        std::lock_guard<std::mutex> lock(state->mutex);
        try {
          require(!state->closed, "Renderer closed");
          auto* a = fl_method_call_get_args(request);
          auto* moc = at(a, "moc"); auto* physics = at(a, "physics");
          TsGpuInfo info{};
          state->model = state->api->create(fl_value_get_uint8_list(moc), static_cast<int32_t>(fl_value_get_length(moc)),
              fl_value_get_uint8_list(physics), static_cast<int32_t>(fl_value_get_length(physics)), nullptr, &info);
          require(state->model != nullptr, state->api->error());
          int limit = static_cast<int>(std::clamp<int64_t>(fl_value_get_int(at(a, "maxTextureSize")), 1, 4096));
          int64_t atlas_bytes = 0;
          auto* textures = at(a, "atlases");
          for (size_t i = 0; i < fl_value_get_length(textures); ++i) {
            auto* atlas_data = fl_value_get_list_value(textures, i);
            int w = static_cast<int>(fl_value_get_int(at(atlas_data, "width")));
            int h = static_cast<int>(fl_value_get_int(at(atlas_data, "height")));
            auto* rgba = at(atlas_data, "rgba");
            require(w > 0 && h > 0 && w <= limit && h <= limit &&
                fl_value_get_length(rgba) == size_t(w) * h * 4, "Invalid decoded atlas");
            for (;;) { atlas_bytes += int64_t(w) * h * 4; if (w == 1 && h == 1) break;
              w = std::max(1, w / 2); h = std::max(1, h / 2); }
          }
          state->pending_atlases = fl_value_ref(textures);
          FlValue* value = fl_value_new_map();
          put(value, "textureId", fl_value_new_int(fl_texture_get_id(FL_TEXTURE(t))));
          put(value, "meshCount", fl_value_new_int(info.mesh_count));
          FlValue* bounds = fl_value_new_list();
          for (double bound : info.bounds) fl_value_append_take(bounds, fl_value_new_float(bound));
          put(value, "bounds", bounds); put(value, "maxSize", fl_value_new_int(4096));
          put(value, "atlasBytes", fl_value_new_int(atlas_bytes)); put(value, "backend", fl_value_new_string("OpenGL ES / EGL"));
          respond(request, value);
        } catch (const std::exception& e) {
          respond(request, nullptr, e.what());
          auto* cleanup = new std::pair<std::shared_ptr<Plugin>, int64_t>(
              work->plugin, fl_texture_get_id(FL_TEXTURE(t)));
          g_idle_add_full(G_PRIORITY_DEFAULT, [](gpointer p) -> gboolean {
            auto* job = static_cast<std::pair<std::shared_ptr<Plugin>, int64_t>*>(p);
            auto it = job->first->scenes.find(job->second);
            if (it != job->first->scenes.end()) {
              fl_texture_registrar_unregister_texture(job->first->registry, FL_TEXTURE(it->second));
              g_object_unref(it->second); job->first->scenes.erase(it);
            }
            return G_SOURCE_REMOVE;
          }, cleanup, [](gpointer p) { delete static_cast<std::pair<std::shared_ptr<Plugin>, int64_t>*>(p); });
        }
        g_task_return_boolean(task, TRUE);
      });
      g_object_unref(task);
      return;
    }
    auto found = plugin->scenes.find(fl_value_get_int(at(args, "id")));
    require(found != plugin->scenes.end(), "Unknown renderer");
    auto* texture = found->second; auto* s = texture->state;
    if (method == "dispose") {
      { std::lock_guard<std::mutex> lock(s->mutex); s->close(); }
      fl_texture_registrar_unregister_texture(plugin->registry, FL_TEXTURE(texture));
      plugin->scenes.erase(found); g_object_unref(texture); respond(call, nullptr); return;
    }
    std::lock_guard<std::mutex> lock(s->mutex);
    require(s->model && !s->closed, "Renderer unavailable");
    if (method == "frame") {
      require(s->pending == nullptr, "Frame already pending");
      s->pending = FL_METHOD_CALL(g_object_ref(call));
      if (!fl_texture_registrar_mark_texture_frame_available(plugin->registry, FL_TEXTURE(texture))) {
        s->finish(nullptr, "Flutter rejected the texture frame notification");
        return;
      }
      // A hidden window may never populate a texture. Release Dart backpressure
      // without rendering or advancing physics until the scene is visible.
      auto* pending = new std::pair<TsTexture*, FlMethodCall*>(
          reinterpret_cast<TsTexture*>(g_object_ref(texture)), FL_METHOD_CALL(g_object_ref(call)));
      g_timeout_add_full(G_PRIORITY_DEFAULT, 500, [](gpointer data) -> gboolean {
        auto* pending = static_cast<std::pair<TsTexture*, FlMethodCall*>*>(data);
        auto* state = pending->first->state; std::lock_guard<std::mutex> lock(state->mutex);
        if (state->pending == pending->second) {
          auto* value = fl_value_new_map(); put(value, "paused", fl_value_new_bool(true)); state->finish(value);
        }
        return G_SOURCE_REMOVE;
      }, pending, [](gpointer data) {
        auto* pending = static_cast<std::pair<TsTexture*, FlMethodCall*>*>(data);
        g_object_unref(pending->first); g_object_unref(pending->second); delete pending;
      });
    } else if (method == "snapshot") {
      require(s->color != 0, "No completed frame");
      Current current(s->display, s->context);
      glBindFramebuffer(GL_FRAMEBUFFER, s->target);
      std::vector<uint8_t> pixels(size_t(s->width) * s->height * 4), bottom_up(pixels.size());
      glReadPixels(0, 0, s->width, s->height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
      require(glGetError() == GL_NO_ERROR, "QA readback failed");
      for (int y = 0; y < s->height; ++y) std::copy_n(pixels.data() + size_t(y) * s->width * 4,
          s->width * 4, bottom_up.data() + size_t(s->height - 1 - y) * s->width * 4);
      respond(call, fl_value_new_uint8_list(bottom_up.data(), bottom_up.size()));
    } else { fl_method_call_respond_not_implemented(call, nullptr); }
  } catch (const std::exception& e) { respond(call, nullptr, e.what()); }
}
}
void tsukuyomi_live2d_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  auto plugin = std::shared_ptr<Plugin>(new Plugin{
    FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar))), {}});
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
      "space.tsukuyomi/live2d_gpu", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handle, new std::shared_ptr<Plugin>(plugin),
      [](gpointer p) {
        auto* owner = static_cast<std::shared_ptr<Plugin>*>(p);
        (*owner)->close();  // Before FlEngine terminates its EGL display.
        delete owner;
      });
}
